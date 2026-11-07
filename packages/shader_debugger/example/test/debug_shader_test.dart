// Runs DebugShader and ShaderDebugger against real shaders: gradient.frag and
// the probe the instrumenter generates for "capture d" (stamp 1). Both are
// compiled by the Flutter tool and executed by the test engine.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
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
      ..hideHeatmap();
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
      expect(rejection, HeatmapRejection.probeNotLoaded);
      expect(debugger.heatmap, isNull);
    });

    test('an asset no DebugShader uses', () async {
      final rejection = await debugger.showHeatmap(
        const HeatmapState(asset: 'shaders/other.frag', stamp: goldenStamp),
      );
      expect(rejection, HeatmapRejection.noShaderForAsset);
    });

    test('a probe asset that is not registered', () async {
      debugger.probeAsset = 'shaders/_debug/missing.frag';
      final rejection = await debugger.showHeatmap(
        const HeatmapState(asset: gradient, stamp: goldenStamp),
      );
      expect(rejection, HeatmapRejection.probeMissing);
    });
  });

  group('service extensions', () {
    test('getInfo lists the live shaders and the heatmap', () async {
      await show(min: -1, max: 2);
      final info = await debugger.handleServiceExtension(
        'ext.shader_debugger.getInfo',
        {},
      );
      expect(info['protocolVersion'], 1);
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
