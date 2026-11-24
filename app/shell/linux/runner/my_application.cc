#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

struct FileDropState {
  FlMethodChannel* channel;
  gboolean dragging;
};

static void free_file_drop_state(gpointer data) {
  FileDropState* state = static_cast<FileDropState*>(data);
  if (state == nullptr) return;
  g_clear_object(&state->channel);
  g_free(state);
}

static gboolean drag_motion_cb(GtkWidget* /*widget*/,
                               GdkDragContext* /*context*/,
                               gint /*x*/,
                               gint /*y*/,
                               guint /*time*/,
                               gpointer user_data) {
  FileDropState* state = static_cast<FileDropState*>(user_data);
  if (!state->dragging) {
    state->dragging = TRUE;
    fl_method_channel_invoke_method(state->channel, "dragEnter", nullptr,
                                    nullptr, nullptr, nullptr);
  }
  return FALSE;
}

static void drag_leave_cb(GtkWidget* /*widget*/,
                          GdkDragContext* /*context*/,
                          guint /*time*/,
                          gpointer user_data) {
  FileDropState* state = static_cast<FileDropState*>(user_data);
  if (state->dragging) {
    state->dragging = FALSE;
    fl_method_channel_invoke_method(state->channel, "dragLeave", nullptr,
                                    nullptr, nullptr, nullptr);
  }
}

static void drag_data_received_cb(GtkWidget* /*widget*/,
                                  GdkDragContext* context,
                                  gint /*x*/,
                                  gint /*y*/,
                                  GtkSelectionData* selection_data,
                                  guint /*info*/,
                                  guint time,
                                  gpointer user_data) {
  FileDropState* state = static_cast<FileDropState*>(user_data);
  if (state->dragging) {
    state->dragging = FALSE;
    fl_method_channel_invoke_method(state->channel, "dragLeave", nullptr,
                                    nullptr, nullptr, nullptr);
  }
  g_auto(GStrv) uris = gtk_selection_data_get_uris(selection_data);
  if (uris == nullptr) {
    gtk_drag_finish(context, FALSE, FALSE, time);
    return;
  }
  g_autoptr(FlValue) paths = fl_value_new_list();
  for (int i = 0; uris[i] != nullptr; i++) {
    g_autofree gchar* path = g_filename_from_uri(uris[i], nullptr, nullptr);
    if (path != nullptr && path[0] != '\0') {
      fl_value_append_take(paths, fl_value_new_string(path));
    }
  }
  if (fl_value_get_length(paths) > 0) {
    fl_method_channel_invoke_method(state->channel, "drop", paths, nullptr,
                                    nullptr, nullptr);
    gtk_drag_finish(context, TRUE, FALSE, time);
  } else {
    gtk_drag_finish(context, FALSE, FALSE, time);
  }
}

static void register_file_drop(FlView* view) {
  static const GtkTargetEntry kDropTargets[] = {
      {const_cast<gchar*>("text/uri-list"), 0, 0},
  };
  FlEngine* engine = fl_view_get_engine(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FileDropState* state = g_new0(FileDropState, 1);
  state->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(engine), "dev.relay.app/file_drop",
      FL_METHOD_CODEC(codec));
  state->dragging = FALSE;
  g_object_set_data_full(G_OBJECT(view), "relay-file-drop-state", state,
                         free_file_drop_state);
  gtk_drag_dest_set(
      GTK_WIDGET(view),
      static_cast<GtkDestDefaults>(GTK_DEST_DEFAULT_MOTION |
                                   GTK_DEST_DEFAULT_DROP),
      kDropTargets, G_N_ELEMENTS(kDropTargets), GDK_ACTION_COPY);
  g_signal_connect(view, "drag-motion", G_CALLBACK(drag_motion_cb), state);
  g_signal_connect(view, "drag-leave", G_CALLBACK(drag_leave_cb), state);
  g_signal_connect(view, "drag-data-received",
                   G_CALLBACK(drag_data_received_cb), state);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_icon_name(window, APPLICATION_ID);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Relay");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Relay");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  register_file_drop(view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
