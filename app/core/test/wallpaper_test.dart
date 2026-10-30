import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:relay_core/core/i18n/app_strings.dart';
import 'package:relay_core/core/platform/wallpaper_processor.dart';
import 'package:relay_core/core/settings/wallpaper.dart';
import 'package:relay_core/core/settings/app_settings_controller.dart';
import 'package:relay_core/core/theme/app_theme.dart';
import 'package:relay_core/core/widgets/chat_wallpaper.dart';
import 'package:relay_core/features/settings/wallpaper_screen.dart';
import 'package:relay_core/features/settings/app_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    support = Directory.systemTemp.createTempSync('relay-wallpaper-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => support.path,
    );
  });
  tearDown(() => support.deleteSync(recursive: true));

  test('one shared wallpaper persists image and both theme values together',
      () async {
    final AppSettingsController settings = AppSettingsController();
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.wallpaper.bytes, isNull);
    expect(settings.wallpaper.lightOpacity, 0.8);
    expect(settings.wallpaper.darkOpacity, 0.2);
    expect(settings.wallpaper.blur, Wallpaper.defaultBlur);
    expect(settings.wallpaper.tint, Wallpaper.defaultTint);
    final Uint8List bytes =
        await prepareWallpaper(img.encodePng(img.Image(width: 12, height: 8)));
    await settings.saveWallpaper(
      Wallpaper(
        bytes: bytes,
        lightOpacity: 0.65,
        darkOpacity: 0.35,
        blur: 12,
        tint: 0.4,
      ),
    );
    final AppSettingsController restored = AppSettingsController();
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.wallpaper.bytes, bytes);
    expect(restored.wallpaper.lightOpacity, 0.65);
    expect(restored.wallpaper.darkOpacity, 0.35);
    expect(restored.wallpaper.blur, 12);
    expect(restored.wallpaper.tint, 0.4);
    await restored
        .saveWallpaper(const Wallpaper(lightOpacity: 0.65, darkOpacity: 0.35));
    await settings.load();
    expect(settings.wallpaper.bytes, isNull);
    expect(settings.wallpaper.darkOpacity, 0.35);
  });

  testWidgets('a pushed page gains the acrylic backdrop without losing state',
      (WidgetTester tester) async {
    final AppSettingsController settings = AppSettingsController();
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: const MaterialApp(
          home: WallpaperBackdrop(
            child: Scaffold(body: TextField()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'draft');
    expect(find.byType(ChatWallpaper), findsNothing);
    await settings.saveWallpaper(
      Wallpaper(bytes: img.encodePng(img.Image(width: 4, height: 3))),
    );
    await tester.pump();
    expect(find.text('draft'), findsOneWidget);
    // The image itself is blurred, so the page reads no backdrop.
    expect(
      tester.widget<ChatWallpaper>(find.byType(ChatWallpaper)).blurred,
      isTrue,
    );
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      Theme.of(tester.element(find.byType(TextField))).scaffoldBackgroundColor,
      Colors.transparent,
    );
  });

  test('invalid imports fail without replacing the saved wallpaper', () async {
    final AppSettingsController settings = AppSettingsController();
    addTearDown(settings.dispose);
    final Uint8List bytes = img.encodePng(img.Image(width: 4, height: 6));
    await settings.saveWallpaper(Wallpaper(bytes: bytes));
    await expectLater(
      prepareWallpaper(Uint8List.fromList(<int>[1, 2, 3])),
      throwsFormatException,
    );
    await settings.load();
    expect(settings.wallpaper.bytes, bytes);
    await expectLater(prepareWallpaper(Uint8List(0)), throwsFormatException);
  });

  test('native imports keep the original file in the app directory', () async {
    final AppSettingsController settings = AppSettingsController();
    addTearDown(settings.dispose);
    final Uint8List original =
        img.encodePng(img.Image(width: 5000, height: 3000));
    final Uint8List bytes = await prepareWallpaper(original);
    expect(bytes, same(original));
    await settings.saveWallpaper(Wallpaper(bytes: bytes));
    final Directory images = Directory('${support.path}/wallpaper');
    List<File> files() => images.listSync().whereType<File>().toList();
    expect(files().single.readAsBytesSync(), original);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('relay.wallpaper.v2'), contains('"wallpaper-'));
    final String stored = files().single.path;
    await settings.saveWallpaper(
      settings.wallpaper.withOpacity(dark: true, value: 0.5),
    );
    expect(files().single.path, stored);
    final Uint8List replacement = img.encodePng(img.Image(width: 7, height: 7));
    await settings.saveWallpaper(Wallpaper(bytes: replacement));
    expect(files().single.readAsBytesSync(), replacement);
    await settings.load();
    expect(settings.wallpaper.bytes, replacement);
    await settings.saveWallpaper(const Wallpaper());
    expect(files(), isEmpty);
  });

  for (final Size size in <Size>[const Size(390, 844), const Size(1200, 900)]) {
    for (final bool dark in <bool>[false, true]) {
      testWidgets(
          'one live slider previews before explicit Save, dark=$dark at $size',
          (WidgetTester tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final AppSettingsController settings = AppSettingsController();
        addTearDown(settings.dispose);
        await settings.saveWallpaper(
          Wallpaper(bytes: img.encodePng(img.Image(width: 6, height: 4))),
        );
        await tester.pumpWidget(
          AppScope(
            controller: settings,
            child: MaterialApp(
              theme: dark ? AppTheme.dark() : AppTheme.light(),
              home: AppSettingsScreen(settingsController: settings),
            ),
          ),
        );
        await tester.tap(find.text('Wallpaper'));
        await tester.pumpAndSettle();
        expect(find.byType(WallpaperScreen), findsOneWidget);
        expect(find.byType(ChoiceChip), findsNothing);
        expect(find.byType(Slider), findsOneWidget);
        final double initial = dark ? 0.2 : 0.8;
        final Finder photo = find.byWidgetPredicate(
          (Widget widget) => widget is Image && widget.image is MemoryImage,
        );
        expect(tester.widget<Image>(photo).opacity!.value, initial);
        final Finder slider =
            find.byKey(const ValueKey<String>('wallpaper-opacity'));
        await tester.ensureVisible(slider);
        final Rect bounds = tester.getRect(slider);
        final TestGesture gesture = await tester.startGesture(
          Offset(
            bounds.left + 24 + (bounds.width - 48) * initial,
            bounds.center.dy,
          ),
        );
        await gesture.moveBy(Offset(dark ? 30 : -30, 0));
        await tester.pump();
        final double first = tester.widget<Image>(photo).opacity!.value;
        expect(first, isNot(initial));
        expect(
          dark
              ? settings.wallpaper.darkOpacity
              : settings.wallpaper.lightOpacity,
          initial,
        );
        await gesture.moveBy(Offset(dark ? 35 : -35, 0));
        await tester.pump();
        final double second = tester.widget<Image>(photo).opacity!.value;
        expect(second, isNot(first));
        expect(tester.widget<Slider>(slider).onChanged, isNotNull);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        expect(
          dark
              ? settings.wallpaper.darkOpacity
              : settings.wallpaper.lightOpacity,
          closeTo(second, 0.001),
        );
        final AppSettingsController restored = AppSettingsController();
        addTearDown(restored.dispose);
        await restored.load();
        expect(
          dark
              ? restored.wallpaper.darkOpacity
              : restored.wallpaper.lightOpacity,
          closeTo(second, 0.001),
        );
        expect(
          dark
              ? restored.wallpaper.lightOpacity
              : restored.wallpaper.darkOpacity,
          dark ? 0.8 : 0.2,
        );
        await tester.ensureVisible(find.text('Remove wallpaper'));
        await tester.tap(find.text('Remove wallpaper'));
        await tester.pumpAndSettle();
        expect(settings.wallpaper.bytes, isNotNull);
        expect(
          tester
              .widget<ChatWallpaper>(find.byType(ChatWallpaper))
              .wallpaper
              .bytes,
          isNull,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();
        expect(settings.wallpaper.bytes, isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the wallpaper decodes only what covers the display',
      (WidgetTester tester) async {
    tester.view.display.size = const Size(1000, 2000);
    addTearDown(tester.view.display.resetSize);
    Future<ImageProvider> providerFor(int width, int height) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChatWallpaper(
            wallpaper: Wallpaper(
              bytes: img.encodePng(img.Image(width: width, height: height)),
            ),
            child: const SizedBox(),
          ),
        ),
      );
      return tester.widget<Image>(find.byType(Image)).image;
    }

    // Short side 3000 shrinks to the display's long side 2000, so a 4500 x
    // 3000 image fits a 3000 box whichever way it is oriented.
    for (final (int w, int h) in <(int, int)>[(4500, 3000), (3000, 4500)]) {
      final ResizeImage resized = await providerFor(w, h) as ResizeImage;
      expect((resized.width, resized.height), (3000, 3000));
      expect(resized.policy, ResizeImagePolicy.fit);
    }
    expect(await providerFor(1500, 2000), isA<MemoryImage>());
  });

  testWidgets('chat surfaces share one backdrop unless nested',
      (WidgetTester tester) async {
    Widget surface({Widget child = const SizedBox(height: 40)}) =>
        ChatChromeSurface(
          acrylic: true,
          color: Colors.white,
          border: const Border(),
          child: child,
        );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatWallpaper(
          wallpaper: Wallpaper(
            bytes: img.encodePng(img.Image(width: 4, height: 3)),
          ),
          child: Column(
            children: <Widget>[
              surface(),
              surface(),
              surface(child: surface()),
            ],
          ),
        ),
      ),
    );
    final List<BackdropKey?> keys = tester
        .renderObjectList<RenderBackdropFilter>(find.byType(BackdropFilter))
        .map((RenderBackdropFilter filter) => filter.backdropKey)
        .toList();
    expect(keys, hasLength(4));
    expect(keys.take(3).toSet(), hasLength(1));
    expect(keys.first, isNotNull);
    expect(keys.last, isNot(keys.first));
  });

  testWidgets(
      'the single slider follows theme changes without losing either draft',
      (WidgetTester tester) async {
    final AppSettingsController settings = AppSettingsController();
    addTearDown(settings.dispose);
    await settings.saveWallpaper(
      Wallpaper(bytes: img.encodePng(img.Image(width: 6, height: 4))),
    );
    final ValueNotifier<ThemeMode> mode =
        ValueNotifier<ThemeMode>(ThemeMode.light);
    addTearDown(mode.dispose);
    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: mode,
          builder: (BuildContext context, ThemeMode value, Widget? _) =>
              MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: value,
            home: WallpaperScreen(settingsController: settings),
          ),
        ),
      ),
    );
    final Finder slider = find.byType(Slider);
    await tester.ensureVisible(slider);
    await tester.drag(slider, const Offset(-65, 0));
    await tester.pumpAndSettle();
    final double lightDraft = tester.widget<Slider>(slider).value;
    expect(lightDraft, isNot(0.8));
    mode.value = ThemeMode.dark;
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 0.2);
    await tester.drag(slider, const Offset(65, 0));
    await tester.pumpAndSettle();
    final double darkDraft = tester.widget<Slider>(slider).value;
    expect(darkDraft, isNot(0.2));
    mode.value = ThemeMode.light;
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, lightDraft);
    expect(settings.wallpaper.lightOpacity, 0.8);
    expect(settings.wallpaper.darkOpacity, 0.2);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(settings.wallpaper.lightOpacity, lightDraft);
    expect(settings.wallpaper.darkOpacity, darkDraft);
  });

  testWidgets(
      'acrylic number fields preview before Save and reject out-of-range values',
      (WidgetTester tester) async {
    final AppSettingsController settings = AppSettingsController();
    addTearDown(settings.dispose);
    await settings.saveWallpaper(
      Wallpaper(bytes: img.encodePng(img.Image(width: 6, height: 4))),
    );
    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: MaterialApp(home: WallpaperScreen(settingsController: settings)),
      ),
    );
    WallpaperScope preview() =>
        tester.widget<WallpaperScope>(find.byType(WallpaperScope));
    final Finder blur = find.byKey(const ValueKey<String>('wallpaper-blur'));
    final Finder tint = find.byKey(const ValueKey<String>('wallpaper-tint'));
    await tester.ensureVisible(blur);
    await tester.enterText(blur, '12');
    await tester.enterText(tint, '40');
    await tester.pump();
    expect((preview().blur, preview().tint), (12, 0.4));
    expect(settings.wallpaper.blur, Wallpaper.defaultBlur);
    await tester.enterText(blur, '31');
    await tester.pump();
    final TextField field = tester.widget<TextField>(
      find.descendant(of: blur, matching: find.byType(TextField)),
    );
    expect(field.decoration!.errorText, '0–30');
    expect(preview().blur, 12);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect((settings.wallpaper.blur, settings.wallpaper.tint), (12, 0.4));
  });

  testWidgets(
      'choosing an image shows a loading spinner until the picker finishes',
      (WidgetTester tester) async {
    const MethodChannel picker =
        MethodChannel('miguelruivo.flutter.plugins.filepicker');
    final Completer<List<Map<String, Object?>>?> picked =
        Completer<List<Map<String, Object?>>?>();
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (MethodCall call) => picked.future);
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(picker, null),
    );
    final AppSettingsController settings = AppSettingsController();
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      AppScope(
        controller: settings,
        child: MaterialApp(home: WallpaperScreen(settingsController: settings)),
      ),
    );
    await tester.ensureVisible(find.text('Choose image'));
    await tester.tap(find.text('Choose image'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Processing wallpaper…'), findsOneWidget);
    picked.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(settings.wallpaper.bytes, isNull);
  });
}
