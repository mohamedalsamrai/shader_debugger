// Runs DebugShader and ShaderDebugger against real shaders: gradient.frag and
// the probe the instrumenter generates for "capture d" (stamp 1). Both are
// compiled by the Flutter tool and executed by the test engine.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_debugger/shader_debugger.dart';

const gradient = 'shaders/gradient.frag';
const goldenProbe = 'test/probes/gradient_capture_d.frag';
const goldenStamp = 1;
const size = 4;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final debugger = ShaderDebugger.instance;
  late DebugShader shader;

  setUp(() async {
    debugger
      ..probeAsset = goldenProbe
      ..hideHeatmap()
      ..clearUniformOverrides(gradient);
    shader = await DebugShader.fromAsset(gradient);
    shader.getUniformVec2('uSize').set(size.toDouble(), size.toDouble());
    shader.getUniformVec4('uA').set(1, 0, 0, 1);
    shader.getUniformVec4('uB').set(0, 0, 1, 1);
  });

  tearDown(() => shader.dispose());

  Future<void> show({double min = 0, double max = 1}) async {
    final rejection = await debugger.showHeatmap(
      HeatmapState(asset: gradient, stamp: goldenStamp, min: min, max: max),
    );
    expect(rejection, isNull);
  }

  test('draws the original shader while no heatmap is shown', () async {
    final pixels = await render(shader.shader);
    // d = 0.53 at pixel (0, 0): mix(red, blue, d).
    expectPixel(pixels, 0, 0, [1 - dAt(0, 0), 0, dAt(0, 0)]);
  });

  test('draws the heatmap of d, with the uniforms replayed', () async {
    await show();
    final pixels = await render(shader.shader);
    for (final (x, y) in [(0, 0), (1, 1), (1, 2), (3, 0)]) {
      expectPixel(pixels, x, y, viridis(dAt(x, y)));
    }
  });

  test('maps the range onto the colormap', () async {
    await show(min: 0.5, max: 0.6);
    final pixels = await render(shader.shader);
    expectPixel(pixels, 0, 0, viridis((dAt(0, 0) - 0.5) / 0.1));
    // Below the range clamps to the low end.
    expectPixel(pixels, 1, 1, viridis(0));
  });

  test('uniforms set while the heatmap is shown reach the probe', () async {
    await show();
    // A larger uSize shrinks uv, which moves d at pixel (3, 3).
    shader.getUniformVec2('uSize').set(8, 8);
    final pixels = await render(shader.shader);
    final uv = (3.5 / 8, 3.5 / 8);
    final d = math.sqrt(math.pow(uv.$1 - 0.5, 2) + math.pow(uv.$2 - 0.5, 2));
    expectPixel(pixels, 3, 3, viridis(d));
  });

  test('hideHeatmap brings the original back', () async {
    await show();
    debugger.hideHeatmap();
    expect(debugger.heatmap, isNull);
    final pixels = await render(shader.shader);
    expectPixel(pixels, 0, 0, [1 - dAt(0, 0), 0, dAt(0, 0)]);
  });

  group('rejects', () {
    test('a stamp the loaded probe does not carry', () async {
      final rejection = await debugger.showHeatmap(
        const HeatmapState(asset: gradient, stamp: 2),
      );
      expect(rejection, ProbeRejection.probeNotLoaded);
      expect(debugger.heatmap, isNull);
    });

    test('an asset no DebugShader uses', () async {
      final rejection = await debugger.showHeatmap(
        const HeatmapState(asset: 'shaders/other.frag', stamp: goldenStamp),
      );
      expect(rejection, ProbeRejection.noShaderForAsset);
    });

    test('a probe asset that is not registered', () async {
      debugger.probeAsset = 'shaders/_debug/missing.frag';
      final rejection = await debugger.showHeatmap(
        const HeatmapState(asset: gradient, stamp: goldenStamp),
      );
      expect(rejection, ProbeRejection.probeMissing);
    });
  });

  group('service extensions', () {
    test('getInfo lists the live shaders and the heatmap', () async {
      await show(min: -1, max: 2);
      final info = await debugger.handleServiceExtension(
        'ext.shader_debugger.getInfo',
        {},
      );
      expect(info['protocolVersion'], 4);
      expect(info['probeAsset'], goldenProbe);
      expect(info['shaders'], [gradient]);
      expect(info['heatmap'], {
        'asset': gradient,
        'stamp': goldenStamp,
        'min': -1.0,
        'max': 2.0,
      });
    });

    test('showHeatmap and hideHeatmap take string parameters', () async {
      final shown = await debugger.handleServiceExtension(
        'ext.shader_debugger.showHeatmap',
        {'asset': gradient, 'stamp': '$goldenStamp', 'max': '0.75'},
      );
      expect(shown, {'applied': true, 'reason': null});
      expect(debugger.heatmap?.max, 0.75);

      final stale = await debugger.handleServiceExtension(
        'ext.shader_debugger.showHeatmap',
        {'asset': gradient, 'stamp': '99'},
      );
      expect(stale, {'applied': false, 'reason': 'probeNotLoaded'});

      await debugger.handleServiceExtension(
        'ext.shader_debugger.hideHeatmap',
        {},
      );
      expect(debugger.heatmap, isNull);
    });

    test('bad parameters are reported, not thrown past the handler', () {
      expect(
        debugger.handleServiceExtension('ext.shader_debugger.showHeatmap', {
          'asset': gradient,
        }),
        throwsFormatException,
      );
      expect(
        debugger.handleServiceExtension('ext.shader_debugger.showHeatmap', {
          'asset': gradient,
          'stamp': '1',
          'min': 'low',
        }),
        throwsFormatException,
      );
    });
  });

  test('a disposed shader is no longer listed', () async {
    final extra = await DebugShader.fromAsset(gradient);
    expect(debugger.shaders, contains(extra));
    extra.dispose();
    expect(debugger.shaders, isNot(contains(extra)));
  });

  group('readPixel', () {
    // The test engine rounds to 8 bits; Impeller reads exact floats.
    const tolerance = 1 / 255;

    Future<List<double>> read(
      Offset coord, {
      int stamp = goldenStamp,
      int? instance,
    }) async {
      final reading = await debugger.readPixel(
        asset: gradient,
        stamp: stamp,
        coord: coord,
        instance: instance,
      );
      expect(reading.rejection, isNull);
      return reading.value!;
    }

    test(
      'reads the captured value at a coordinate, without a heatmap',
      () async {
        final value = await read(const Offset(0.5, 0.5));
        // d widened to vec4(d, 0, 0, 1); w comes from the second pass.
        expect(value[0], closeTo(dAt(0, 0), tolerance));
        expect(value.sublist(1), [0.0, 0.0, 1.0]);
        expect(
          (await read(const Offset(3.5, 0.5)))[0],
          closeTo(dAt(3, 0), tolerance),
        );
        expect(debugger.heatmap, isNull);
      },
    );

    test("uses the uniforms of the instance it is given", () async {
      final wide = await DebugShader.fromAsset(gradient);
      addTearDown(wide.dispose);
      wide.getUniformVec2('uSize').set(8, 8);
      const coord = Offset(3.5, 3.5);
      final d8 = math.sqrt(2 * math.pow(3.5 / 8 - 0.5, 2));
      expect(
        (await read(coord, instance: wide.debugId))[0],
        closeTo(d8, tolerance),
      );
      expect(
        (await read(coord, instance: shader.debugId))[0],
        closeTo(dAt(3, 3), tolerance),
      );
    });

    test('rejects like showHeatmap', () async {
      final stale = await debugger.readPixel(
        asset: gradient,
        stamp: 2,
        coord: Offset.zero,
      );
      expect(stale.rejection, ProbeRejection.probeNotLoaded);
      final other = await debugger.readPixel(
        asset: 'shaders/other.frag',
        stamp: goldenStamp,
        coord: Offset.zero,
      );
      expect(other.rejection, ProbeRejection.noShaderForAsset);
    });

    test('the service extension takes string parameters', () async {
      final answer = await debugger.handleServiceExtension(
        'ext.shader_debugger.readPixel',
        {'asset': gradient, 'stamp': '$goldenStamp', 'x': '0.5', 'y': '0.5'},
      );
      expect(answer['applied'], isTrue);
      expect((answer['value']! as List)[0], closeTo(dAt(0, 0), tolerance));
      expect(
        debugger.handleServiceExtension('ext.shader_debugger.readPixel', {
          'asset': gradient,
          'stamp': '$goldenStamp',
          'x': '0.5',
        }),
        throwsFormatException,
      );
    });
  });

  group('uniform overrides', () {
    test(
      "replace the app's value when drawn; clearing brings it back",
      () async {
        expect(
          debugger.setUniformOverride(gradient, 'uA', [0, 1, 0, 1]),
          isNull,
        );
        var pixels = await render(shader.shader);
        // mix(green, blue, d) instead of mix(red, blue, d).
        expectPixel(pixels, 0, 0, [0, 1 - dAt(0, 0), dAt(0, 0)]);

        // The app does not set uA again: its recorded value comes back.
        debugger.clearUniformOverrides(gradient, name: 'uA');
        pixels = await render(shader.shader);
        expectPixel(pixels, 0, 0, [1 - dAt(0, 0), 0, dAt(0, 0)]);
      },
    );

    test('reach the probe, in the heatmap and in pixel reads', () async {
      await show();
      debugger.setUniformOverride(gradient, 'uSize', [8, 8]);
      final d8 = math.sqrt(2 * math.pow(3.5 / 8 - 0.5, 2));
      expectPixel(await render(shader.shader), 3, 3, viridis(d8));
      final reading = await debugger.readPixel(
        asset: gradient,
        stamp: goldenStamp,
        coord: const Offset(3.5, 3.5),
      );
      expect(reading.value![0], closeTo(d8, 1 / 255));
    });

    test('need a float uniform of that name and component count', () {
      expect(
        debugger.setUniformOverride(gradient, 'uNope', [1]),
        UniformRejection.unknownUniform,
      );
      expect(
        debugger.setUniformOverride(gradient, 'uA', [1, 2]),
        UniformRejection.unknownUniform,
      );
      expect(
        debugger.setUniformOverride('shaders/other.frag', 'uA', [1, 0, 0, 1]),
        UniformRejection.noShaderForAsset,
      );
      expect(debugger.overridesFor(gradient), isEmpty);
    });

    test('through the service extensions', () async {
      Future<Map<String, Object?>> call(
        String name,
        Map<String, String> parameters,
      ) => debugger.handleServiceExtension(
        'ext.shader_debugger.$name',
        parameters,
      );

      expect(await call('getUniforms', {'asset': gradient}), {
        'values': {
          'uSize': [4.0, 4.0],
          'uA': [1.0, 0.0, 0.0, 1.0],
          'uB': [0.0, 0.0, 1.0, 1.0],
        },
        'overrides': <String, Object>{},
      });
      expect(
        await call('setUniformOverride', {
          'asset': gradient,
          'name': 'uA',
          'values': '0, 1, 0, 1',
        }),
        {'applied': true, 'reason': null},
      );
      expect((await call('getUniforms', {'asset': gradient}))['overrides'], {
        'uA': [0.0, 1.0, 0.0, 1.0],
      });
      expect(
        await call('setUniformOverride', {
          'asset': gradient,
          'name': 'uA',
          'values': '1',
        }),
        {'applied': false, 'reason': 'unknownUniform'},
      );
      await expectLater(
        call('setUniformOverride', {
          'asset': gradient,
          'name': 'uA',
          'values': 'red',
        }),
        throwsFormatException,
      );
      await call('clearUniformOverrides', {'asset': gradient});
      expect(
        (await call('getUniforms', {'asset': gradient}))['overrides'],
        isEmpty,
      );
    });

    testWidgets('repaint what drew the shader', (tester) async {
      var paints = 0;
      await tester.pumpWidget(
        CustomPaint(
          painter: _ShaderPainter(shader, onPaint: () => paints++),
          size: const Size(4, 4),
        ),
      );
      expect(paints, 1);
      debugger.setUniformOverride(gradient, 'uA', [0, 1, 0, 1]);
      await tester.pump();
      expect(paints, 2);
      debugger.clearUniformOverrides(gradient);
      await tester.pump();
      expect(paints, 3);
    });
  });

  group('picking a pixel', () {
    // A 400x300 logical screen at 2 device pixels per logical pixel. The
    // gradient is painted 4x4 at (10, 200), and a second instance with
    // another uSize at (30, 200).
    const top = 200.0;
    late DebugShader second;
    final events = <List<Object?>>[];
    var appTaps = 0;

    setUp(() async {
      second = await DebugShader.fromAsset(gradient);
      second.getUniformVec2('uSize').set(8, 8);
      events.clear();
      appTaps = 0;
      debugger.postEvent = (kind, data) => events.add([kind, data]);
    });

    tearDown(() {
      debugger.setPixelSelectMode(enabled: false);
      second.dispose();
    });

    // The counter wraps everything, so every tap that reaches the app counts.
    Widget shaders() => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => appTaps++,
      child: Stack(
        children: [
          for (final (left, debugShader) in [(10.0, shader), (30.0, second)])
            Positioned(
              left: left,
              top: top,
              width: size.toDouble(),
              height: size.toDouble(),
              child: CustomPaint(painter: _ShaderPainter(debugShader)),
            ),
        ],
      ),
    );

    /// Pumps the shaders in a MaterialApp, or with [overlay] false, in a
    /// bare tree without an Overlay.
    Future<void> pumpShaders(WidgetTester tester, {bool overlay = true}) async {
      tester.view
        ..physicalSize = const Size(800, 600)
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        overlay
            ? MaterialApp(home: shaders())
            : Directionality(
                textDirection: TextDirection.ltr,
                child: shaders(),
              ),
      );
    }

    Map<Object?, Object?> picked(double x, double y, DebugShader on) => {
      'asset': gradient,
      'instance': on.debugId,
      'x': x,
      'y': y,
      'width': 4.0,
      'height': 4.0,
    };

    testWidgets('maps a position to the device pixel center in the shader', (
      tester,
    ) async {
      await pumpShaders(tester);
      // 12.3 * 2 = 24.6 -> device pixel 24, center 24.5 -> 12.25 -> 2.25.
      expect(
        debugger.pickAt(gradient, const Offset(12.3, top + 1.7)),
        picked(2.25, 1.75, shader),
      );
      expect(
        debugger.pickAt(gradient, const Offset(31, top + 1))['instance'],
        second.debugId,
      );
      expect(debugger.pickAt(gradient, const Offset(20, top + 1)), {
        'asset': gradient,
        'reason': 'notOnShader',
      });
    });

    testWidgets('select mode takes the clicks: each one picks a pixel', (
      tester,
    ) async {
      await pumpShaders(tester);
      expect(
        debugger.setPixelSelectMode(enabled: true, asset: gradient),
        isTrue,
      );
      await tester.pump();
      expect(
        find.text('Shader Debugger: click a pixel of $gradient'),
        findsOneWidget,
      );

      await tester.tapAt(const Offset(12.3, top + 1.7));
      await tester.tapAt(const Offset(31.2, top + 3.3));
      await tester.tapAt(const Offset(100, 100));
      expect(events, [
        ['shader_debugger.pixelPicked', picked(2.25, 1.75, shader)],
        ['shader_debugger.pixelPicked', picked(1.25, 3.25, second)],
        [
          'shader_debugger.pixelPicked',
          {'asset': gradient, 'reason': 'notOnShader'},
        ],
      ]);
      expect(appTaps, 0, reason: 'clicks go to the debugger, not the app');
      expect(debugger.pixelSelectAsset, gradient);
    });

    testWidgets('hovering frames the pixel under the pointer', (tester) async {
      await pumpShaders(tester);
      debugger.setPixelSelectMode(enabled: true, asset: gradient);
      await tester.pump();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(const Offset(12.3, top + 1.7));
      await tester.pump();

      final layer = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString() == '_PixelSelectPainter',
      );
      expect(
        tester.renderObject(layer),
        paints
          // The shader's area, then the frame around the device pixel.
          ..rect(rect: const Rect.fromLTRB(10.5, top + 0.5, 13.5, top + 3.5))
          ..rect(
            rect: Rect.fromCenter(
              center: const Offset(12.25, top + 1.75),
              width: 9,
              height: 9,
            ),
          ),
      );
      expect(events, isEmpty, reason: 'hovering picks nothing');
    });

    testWidgets("the overlay's Done button leaves select mode", (tester) async {
      await pumpShaders(tester);
      debugger.setPixelSelectMode(enabled: true, asset: gradient);
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pump();
      expect(events, [
        [
          'shader_debugger.pixelSelectMode',
          {'enabled': false},
        ],
      ]);
      expect(debugger.pixelSelectAsset, isNull);
      expect(find.text('Done'), findsNothing);
      await tester.tapAt(const Offset(12.3, top + 1.7));
      expect(appTaps, 1);
    });

    testWidgets('without an Overlay, clicks are watched and reach the app', (
      tester,
    ) async {
      await pumpShaders(tester, overlay: false);
      expect(
        debugger.setPixelSelectMode(enabled: true, asset: gradient),
        isFalse,
      );
      await tester.tapAt(const Offset(12.3, top + 1.7));
      expect(events.single, [
        'shader_debugger.pixelPicked',
        picked(2.25, 1.75, shader),
      ]);
      expect(appTaps, 1);

      debugger.setPixelSelectMode(enabled: false);
      await tester.tapAt(const Offset(12.3, top + 1.7));
      expect(events, hasLength(1));
    });

    testWidgets('the service extensions', (tester) async {
      await pumpShaders(tester);
      Future<Map<String, Object?>> call(
        String name,
        Map<String, String> parameters,
      ) => debugger.handleServiceExtension(
        'ext.shader_debugger.$name',
        parameters,
      );

      expect(
        await call('setPixelSelectMode', {
          'enabled': 'true',
          'asset': gradient,
        }),
        {'enabled': true, 'overlay': true},
      );
      // pickPixel waits for a pending frame, which only a pump draws here.
      await tester.pump();
      expect((await call('getInfo', {}))['pixelSelectMode'], gradient);
      expect(
        await call('pickPixel', {
          'asset': gradient,
          'x': '12.3',
          'y': '${top + 1.7}',
        }),
        picked(2.25, 1.75, shader),
      );
      expect(await call('setPixelSelectMode', {'enabled': 'false'}), {
        'enabled': false,
        'overlay': false,
      });
      expect((await call('getInfo', {}))['pixelSelectMode'], isNull);

      for (final bad in [
        {'enabled': 'yes', 'asset': gradient},
        {'enabled': 'true'},
      ]) {
        await expectLater(
          call('setPixelSelectMode', bad),
          throwsFormatException,
        );
      }
      await expectLater(
        call('pickPixel', {'asset': gradient}),
        throwsFormatException,
      );
    });

    testWidgets('the picked value is the one drawn there', (tester) async {
      await pumpShaders(tester, overlay: false);
      await tester.runAsync(show);
      await tester.pump();
      const position = Offset(13.3, top + 2.8);
      final pick = debugger.pickAt(gradient, position);
      final reading = (await tester.runAsync(
        () => debugger.readPixel(
          asset: gradient,
          stamp: goldenStamp,
          coord: Offset(pick['x']! as double, pick['y']! as double),
          instance: pick['instance']! as int,
        ),
      ))!;
      // The heatmap pixel on screen, at the same device pixel.
      final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
      final pixel = (await tester.runAsync(() async {
        final image = await layer.toImage(
          Rect.fromLTWH(
            (position.dx * 2).floorToDouble(),
            (position.dy * 2).floorToDouble(),
            1,
            1,
          ),
        );
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!.buffer.asUint8List();
      }))!;
      final expected = viridis(reading.value![0]);
      for (var c = 0; c < 3; c++) {
        expect(
          (pixel[c] - expected[c] * 255).abs(),
          lessThanOrEqualTo(3),
          reason: 'screen $pixel, colormap of ${reading.value} is $expected',
        );
      }
    });
  });
}

/// The value of `d` in gradient.frag at pixel (x, y), sampled at its center.
double dAt(int x, int y) {
  final u = (x + 0.5) / size - 0.5;
  final v = (y + 0.5) / size - 0.5;
  return math.sqrt(u * u + v * v);
}

/// The probe's colormap: viridis at five stops, interpolated linearly.
List<double> viridis(double t) {
  const stops = [
    [0.267, 0.004, 0.329],
    [0.231, 0.322, 0.545],
    [0.129, 0.569, 0.549],
    [0.369, 0.788, 0.384],
    [0.992, 0.906, 0.145],
  ];
  final x = t.clamp(0.0, 1.0) * 4;
  final i = math.min(x.floor(), 3);
  final f = x - i;
  return [
    for (var c = 0; c < 3; c++)
      stops[i][c] + (stops[i + 1][c] - stops[i][c]) * f,
  ];
}

Future<Uint8List> render(ui.Shader shader) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..shader = shader,
  );
  final image = await recorder.endRecording().toImage(size, size);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// Expects opaque [rgb] (0–1 floats) at (x, y), within 2/255 per channel.
void expectPixel(Uint8List pixels, int x, int y, List<double> rgb) {
  final offset = (y * size + x) * 4;
  final actual = pixels.sublist(offset, offset + 4);
  final expected = [for (final c in rgb) (c * 255).round(), 255];
  for (var c = 0; c < 4; c++) {
    expect(
      (actual[c] - expected[c]).abs(),
      lessThanOrEqualTo(2),
      reason: 'pixel ($x, $y): got $actual, expected $expected',
    );
  }
}

class _ShaderPainter extends CustomPainter {
  _ShaderPainter(this.shader, {this.onPaint});

  final DebugShader shader;
  final VoidCallback? onPaint;

  @override
  void paint(Canvas canvas, Size size) {
    onPaint?.call();
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader.shader);
  }

  // Never asks to repaint: only the debugger does.
  @override
  bool shouldRepaint(_ShaderPainter oldDelegate) => false;
}
