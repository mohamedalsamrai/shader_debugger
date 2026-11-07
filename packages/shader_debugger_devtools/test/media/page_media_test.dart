// Renders the DevTools page for the README: the real page, theme and fonts,
// with the example's shaders analyzed for real, and the app's answers from
// the fakes. Writes PNGs to doc/media/ at the repo root.
//
// Run only on purpose, from packages/shader_debugger_devtools:
//   UPDATE_MEDIA=1 flutter test test/media
// then `python3 tool/readme_media.py --encode` from the root for the GIF.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_debugger_devtools/src/controller.dart';
import 'package:shader_debugger_devtools/src/ports.dart';
import 'package:shader_debugger_devtools/src/screen.dart';

import '../fakes.dart';

const _assets = [
  'shaders/gradient.frag',
  'shaders/lights.frag',
  'shaders/checkerboard.frag',
  'shaders/ripple.frag',
];

/// The gradient card's painted size in the README's recordings.
const _painted = Size(342, 324.89);

void main() {
  final update = Platform.environment['UPDATE_MEDIA'] == '1';

  testWidgets('the DevTools page, for the README', skip: !update, (
    tester,
  ) async {
    await tester.runAsync(_loadFonts);
    tester.view
      ..physicalSize = const Size(2480, 2200)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final workspace = FakeWorkspace();
    for (final asset in _assets) {
      workspace.files[appRoot.resolve(asset)] = File(
        '../shader_debugger/example/$asset',
      ).readAsStringSync();
    }
    final app = FakeApp(workspace)
      ..info = const AppInfo(
        protocolVersion: 5,
        probeAsset: probeAsset,
        shaders: _assets,
      )
      ..uniformValues.addAll({
        'uSize': [_painted.width, _painted.height],
        'uA': [0.1, 0.2, 0.9, 1],
        'uB': [1, 0.6, 0.1, 1],
      })
      // gradient.frag's d at the point read.
      ..pixelValue = (x, y) {
        final u = x / _painted.width - 0.5;
        final v = y / _painted.height - 0.5;
        return [math.sqrt(u * u + v * v), 0, 0, 1];
      };
    final controller = ShaderDebuggerController(
      app: app,
      workspace: workspace,
      retryDelay: Duration.zero,
    )..start();
    addTearDown(controller.dispose);

    final page = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: themeFor(
          isDarkTheme: true,
          ideTheme: IdeTheme(),
          theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
        ),
        home: RepaintBoundary(
          key: page,
          child: Scaffold(body: ShaderDebuggerScreen(controller: controller)),
        ),
      ),
    );
    app.runtime.value = true;
    await tester.pumpAndSettle();

    Future<void> save(String name) async {
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(page),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        File('../../doc/media/$name.png')
            .writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    // 1. Inspect: d as a heatmap, and its value at a clicked pixel.
    await tester.tap(find.text('  float d = length(uv - 0.5);'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show heatmap'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select pixel mode'));
    await tester.pumpAndSettle();
    app.click(
      PixelPick(
        asset: _assets.first,
        instance: 1,
        x: 118.75,
        y: 219.75,
        width: _painted.width,
        height: _painted.height,
      ),
    );
    await save('devtools-inspect');

    // 2. A struct in an array: pick the element and the field.
    await controller.setPixelSelectMode(false);
    await controller.selectShader('shaders/lights.frag');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('  lights[1] = Light('));
    await tester.pumpAndSettle();
    await tester.tap(find.text('.position'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('.color').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show heatmap'));
    await save('devtools-composite');

    // 3. Uniforms: the app's live values, one overridden. Less tall: the
    // tab has less to show.
    tester.view.physicalSize = const Size(2480, 1440);
    await controller.selectShader(_assets.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Uniforms'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).at(1));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Values'),
      '0.95, 0.3, 0.55, 1',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await save('devtools-uniforms');
  });
}

/// The fonts DevTools uses: Roboto and Roboto Mono from devtools_app_shared,
/// and Material icons from the Flutter SDK. Tests draw boxes otherwise.
Future<void> _loadFonts() async {
  // flutter_tester cannot resolve package URIs: read the workspace's
  // package config instead.
  final config = File('../../.dart_tool/package_config.json');
  final packages =
      (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
  final root =
      (packages.firstWhere(
            (package) => (package as Map)['name'] == 'devtools_app_shared',
          ) as Map)['rootUri']
          as String;
  final shared = config.absolute.uri.resolve('$root/').resolve('fonts/');
  // flutter_tester sits in <flutter>/bin/cache/artifacts/engine/<host>/.
  final artifacts = File(Platform.resolvedExecutable).parent.parent.parent;
  final fonts = {
    'Roboto': [
      for (final weight in ['Regular', 'Medium', 'Bold'])
        File.fromUri(shared.resolve('Roboto/Roboto-$weight.ttf')),
    ],
    'RobotoMono': [
      for (final weight in ['Regular', 'Medium', 'Bold'])
        File.fromUri(shared.resolve('Roboto_Mono/RobotoMono-$weight.ttf')),
    ],
    'MaterialIcons': [
      File('${artifacts.path}/material_fonts/MaterialIcons-Regular.otf'),
    ],
  };
  for (final MapEntry(key: family, value: files) in fonts.entries) {
    final loader = FontLoader(family);
    for (final file in files) {
      loader.addFont(
        Future.value(ByteData.sublistView(file.readAsBytesSync())),
      );
    }
    await loader.load();
  }
}
