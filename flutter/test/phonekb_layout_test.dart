// PhoneKB: render the "模拟键盘" session page offline, to check the layout before
// installing on a device.
//
//   flutter test test/phonekb_layout_test.dart --update-goldens
//
// Screenshots land in test/phonekb_shots/ (not committed).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/keyboard_page.dart';
import 'package:flutter_hbb/mobile/phonekb_relay.dart';

Future<void> _loadFont(String family, String path) async {
  final f = File(path);
  if (!f.existsSync()) return;
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  await loader.load();
}

void main() {
  setUpAll(() async {
    // Real glyphs instead of the test font's boxes.
    await _loadFont('UI', 'C:/Windows/Fonts/msyh.ttc');
    final root = Platform.environment['FLUTTER_ROOT'] ?? '';
    await _loadFont('MaterialIcons',
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  });

  const phone = Size(412, 892); // Redmi K80, logical px
  final cases = <(String, Size, bool, bool)>[
    ('portrait_touch', phone, false, false),
    ('portrait_touch_kb', phone, false, true),
    ('portrait_gyro', phone, true, false),
    ('landscape_touch', Size(phone.height, phone.width), false, false),
    ('landscape_gyro', Size(phone.height, phone.width), true, false),
  ];
  for (final c in [
    ('home_pc', false, <FoundTablet>[]),
    ('home_tablet', true, [
      FoundTablet('192.168.43.120', 'Xiaomi Pad 7S Pro', '100.97.81.22', 'x')
    ]),
    ('home_tablet_none', true, <FoundTablet>[]),
  ]) {
    testWidgets(c.$1, (t) async {
      t.view.devicePixelRatio = 2;
      t.view.physicalSize = phone * 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'UI'),
        home: Scaffold(
            body: SafeArea(
                child: KeyboardHomePage(
                    preview: true,
                    previewTablet: c.$2,
                    previewTablets: c.$3))),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await expectLater(find.byType(KeyboardHomePage),
          matchesGoldenFile('phonekb_shots/${c.$1}.png'));
    });
  }
  for (final c in cases) {
    testWidgets(c.$1, (t) async {
      t.view.devicePixelRatio = 2;
      t.view.physicalSize = c.$2 * 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'UI'),
        home: KeyboardSessionPage(
            id: '100.97.81.22',
            preview: true,
            previewGyro: c.$3,
            previewDrawer: c.$4),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await expectLater(find.byType(KeyboardSessionPage),
          matchesGoldenFile('phonekb_shots/${c.$1}.png'));
    });
  }
}
