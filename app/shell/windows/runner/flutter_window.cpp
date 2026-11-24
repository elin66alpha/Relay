#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <ole2.h>
#include <shellapi.h>

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

class FileDropTarget final : public IDropTarget {
 public:
  explicit FileDropTarget(
      std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel)
      : channel_(std::move(channel)) {}

  ULONG STDMETHODCALLTYPE AddRef() override {
    return ::InterlockedIncrement(&ref_count_);
  }

  ULONG STDMETHODCALLTYPE Release() override {
    ULONG count = ::InterlockedDecrement(&ref_count_);
    if (count == 0) {
      delete this;
    }
    return count;
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** ppv_object) override {
    if (ppv_object == nullptr) {
      return E_POINTER;
    }
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IDropTarget)) {
      *ppv_object = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *ppv_object = nullptr;
    return E_NOINTERFACE;
  }

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data_object,
                                      DWORD /*key_state*/,
                                      POINTL /*pt*/,
                                      DWORD* effect) override {
    has_files_ = HasHDrop(data_object);
    if (effect != nullptr) {
      *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    }
    if (has_files_ && channel_) {
      channel_->InvokeMethod("dragEnter", nullptr);
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragOver(DWORD /*key_state*/,
                                     POINTL /*pt*/,
                                     DWORD* effect) override {
    if (effect != nullptr) {
      *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (has_files_ && channel_) {
      channel_->InvokeMethod("dragLeave", nullptr);
    }
    has_files_ = false;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data_object,
                                 DWORD /*key_state*/,
                                 POINTL /*pt*/,
                                 DWORD* effect) override {
    if (has_files_ && channel_) {
      channel_->InvokeMethod("dragLeave", nullptr);
    }
    has_files_ = false;
    flutter::EncodableList paths = ExtractPaths(data_object);
    if (effect != nullptr) {
      *effect = paths.empty() ? DROPEFFECT_NONE : DROPEFFECT_COPY;
    }
    if (!paths.empty() && channel_) {
      channel_->InvokeMethod(
          "drop",
          std::make_unique<flutter::EncodableValue>(std::move(paths)));
    }
    return S_OK;
  }

 private:
  static bool HasHDrop(IDataObject* data_object) {
    if (data_object == nullptr) {
      return false;
    }
    FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    return SUCCEEDED(data_object->QueryGetData(&fmt));
  }

  static flutter::EncodableList ExtractPaths(IDataObject* data_object) {
    flutter::EncodableList list;
    if (data_object == nullptr) {
      return list;
    }
    FORMATETC fmt = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM stg = {};
    if (FAILED(data_object->GetData(&fmt, &stg))) {
      return list;
    }
    HDROP hdrop = static_cast<HDROP>(::GlobalLock(stg.hGlobal));
    if (hdrop != nullptr) {
      UINT count = ::DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
      for (UINT i = 0; i < count; ++i) {
        UINT len = ::DragQueryFileW(hdrop, i, nullptr, 0);
        if (len == 0) continue;
        std::vector<wchar_t> buf(len + 1, L'\0');
        if (::DragQueryFileW(hdrop, i, buf.data(), len + 1) > 0) {
          std::string utf8 = Utf8FromUtf16(buf.data());
          if (!utf8.empty()) {
            list.emplace_back(std::move(utf8));
          }
        }
      }
      ::GlobalUnlock(stg.hGlobal);
    }
    ::ReleaseStgMedium(&stg);
    return list;
  }

  ULONG ref_count_ = 1;
  bool has_files_ = false;
  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  file_drop_channel_ =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dev.relay.app/file_drop",
          &flutter::StandardMethodCodec::GetInstance());
  if (SUCCEEDED(::OleInitialize(nullptr))) {
    ole_initialized_ = true;
    file_drop_target_ = new FileDropTarget(file_drop_channel_);
    if (FAILED(::RegisterDragDrop(GetHandle(), file_drop_target_))) {
      file_drop_target_->Release();
      file_drop_target_ = nullptr;
    }
  }

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (file_drop_target_ != nullptr) {
    ::RevokeDragDrop(GetHandle());
    file_drop_target_->Release();
    file_drop_target_ = nullptr;
  }
  file_drop_channel_.reset();
  if (ole_initialized_) {
    ::OleUninitialize();
    ole_initialized_ = false;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
