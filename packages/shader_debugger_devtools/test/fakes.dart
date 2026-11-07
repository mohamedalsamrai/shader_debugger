/// Fakes for the debugger's ports: an app that behaves like the runtime
/// package, and an in-memory workspace.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shader_debugger_core/protocol.dart';
import 'package:shader_debugger_devtools/src/ports.dart';

const gradientAsset = 'shaders/gradient.frag';
const probeAsset = 'shaders/_debug/probe.frag';
final appRoot = Uri.parse('file:///work/app/');
final gradientFile = appRoot.resolve(gradientAsset);
final probeFile = appRoot.resolve(probeAsset);

const gradientSource = '''
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform vec4 uA;
uniform vec4 uB;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float d = length(uv - 0.5);
  vec3 col = mix(uA.rgb, uB.rgb, d);
  fragColor = vec4(col, 1.0);
}
''';

/// A matrix, an array and an array of structs, each written in part.
const compositeSource = '''
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;

out vec4 fragColor;

struct Light {
  vec2 position;
  vec3 color;
};

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  mat2 spin = mat2(uv.x, uv.y, -uv.y, uv.x);
  float weights[3];
  weights[2] = uv.y;
  Light lights[2];
  lights[1] = Light(spin * uv, vec3(weights[2]));
  fragColor = vec4(lights[1].color, 1.0);
}
''';

/// The 0-based line of [text] in [source].
int lineOf(String text, [String source = gradientSource]) =>
    source.substring(0, source.indexOf(text)).split('\n').length - 1;

class FakeWorkspace implements Workspace {
  final files = <Uri, String>{
    appRoot.resolve('pubspec.yaml'): 'name: app\n',
    gradientFile: gradientSource,
    probeFile: '// placeholder\n',
  };

  /// When set, every call fails with this error.
  WorkspaceError? failWith;

  @override
  Future<String> read(Uri file) async {
    final error = failWith;
    if (error != null) throw WorkspaceException(error, 'denied');
    return files[file] ??
        (throw const WorkspaceException(WorkspaceError.notFound, 'missing'));
  }

  @override
  Future<void> write(Uri file, String contents) async {
    final error = failWith;
    if (error != null) throw WorkspaceException(error, 'denied');
    files[file] = contents;
  }
}

/// Behaves like an app using package:shader_debugger: a hot reload compiles
/// the probe file and loads its stamp.
class FakeApp implements DebuggedApp {
  FakeApp(this.workspace);

  final FakeWorkspace workspace;
  final runtime = ValueNotifier(false);
  var info = const AppInfo(
    protocolVersion: protocolVersion,
    probeAsset: probeAsset,
    shaders: [gradientAsset],
  );
  Uri? mainLibrary = appRoot.resolve('lib/main.dart');

  /// The stamp of the probe the app has loaded.
  int? loadedStamp;

  /// How many showHeatmap calls answer probeNotLoaded before the reloaded
  /// probe lands.
  int slowAsks = 0;

  bool failReload = false;
  String? refuseWith;
  int reloads = 0;
  final heatmapCalls = <({String asset, int stamp, double min, double max})>[];
  ({String asset, int stamp, double min, double max})? shown;

  /// What readPixel answers at a point, once the probe is loaded.
  List<double> Function(double x, double y) pixelValue = (x, y) => [
    x / 100,
    y / 100,
    0,
    1,
  ];

  /// What readPixel says about precision.
  bool exactPixels = true;
  final pixelCalls =
      <({String asset, int stamp, double x, double y, int? instance})>[];

  /// The app's uniform values, and how many components each has.
  final uniformValues = <String, List<double>>{
    'uSize': [400, 300],
    'uA': [0.1, 0.2, 0.9, 1],
    'uB': [1, 0.6, 0.1, 1],
  };
  final overrides = <String, List<double>>{};
  final overrideCalls = <(String, List<double>)>[];

  /// While set, setUniformOverride waits for it.
  Future<void>? holdOverrides;

  /// The asset in pixel select mode, while it is on.
  String? selecting;

  /// Whether select mode shows an overlay that takes the clicks.
  bool hasOverlay = true;
  final _picks = StreamController<PixelPick>.broadcast();
  final _exits = StreamController<void>.broadcast();

  /// A click in the app: reported while select mode is on.
  void click(PixelPick pick) {
    if (selecting != null) _picks.add(pick);
  }

  /// A hot restart: the runtime goes away and comes back, having forgotten
  /// the heatmap, select mode and overrides. The probe stays compiled.
  Future<void> restart() async {
    runtime.value = false;
    shown = null;
    selecting = null;
    overrides.clear();
    await Future<void>.delayed(Duration.zero);
    runtime.value = true;
  }

  /// The overlay's Done button.
  void pressDone() {
    selecting = null;
    _exits.add(null);
  }

  ProbeAnswer _answer(int stamp) {
    if (refuseWith != null) {
      return ProbeAnswer(applied: false, reason: refuseWith);
    }
    if (slowAsks > 0) {
      slowAsks--;
      return const ProbeAnswer(applied: false, reason: 'probeNotLoaded');
    }
    if (stamp != loadedStamp) {
      return const ProbeAnswer(applied: false, reason: 'probeNotLoaded');
    }
    return const ProbeAnswer(applied: true);
  }

  @override
  ValueListenable<bool> get hasRuntime => runtime;

  @override
  Future<AppInfo> getInfo() async => info;

  @override
  Future<void> hotReload() async {
    reloads++;
    if (failReload) throw StateError('Unable to reload sources');
    final probe = workspace.files[probeFile] ?? '';
    final stamp = RegExp(r'_dbg_stamp_(\d+)').firstMatch(probe)?.group(1);
    loadedStamp = stamp == null ? null : int.parse(stamp);
  }

  @override
  Future<ProbeAnswer> showHeatmap({
    required String asset,
    required int stamp,
    required double min,
    required double max,
  }) async {
    final call = (asset: asset, stamp: stamp, min: min, max: max);
    heatmapCalls.add(call);
    final answer = _answer(stamp);
    if (answer.applied) shown = call;
    return answer;
  }

  @override
  Future<void> hideHeatmap() async => shown = null;

  @override
  Future<PixelAnswer> readPixel({
    required String asset,
    required int stamp,
    required double x,
    required double y,
    int? instance,
  }) async {
    pixelCalls.add((
      asset: asset,
      stamp: stamp,
      x: x,
      y: y,
      instance: instance,
    ));
    final answer = _answer(stamp);
    return PixelAnswer(
      applied: answer.applied,
      reason: answer.reason,
      value: answer.applied ? pixelValue(x, y) : null,
      exact: exactPixels,
    );
  }

  @override
  Future<bool> setPixelSelectMode({
    required bool enabled,
    String? asset,
  }) async {
    selecting = enabled ? asset : null;
    return enabled && hasOverlay;
  }

  @override
  Stream<PixelPick> get pixelPicks => _picks.stream;

  @override
  Stream<void> get pixelSelectModeExits => _exits.stream;

  @override
  Future<UniformValues> getUniforms(String asset) async => UniformValues(
    values: Map.of(uniformValues),
    overrides: Map.of(overrides),
  );

  @override
  Future<String?> setUniformOverride({
    required String asset,
    required String name,
    required List<double> values,
  }) async {
    overrideCalls.add((name, values));
    await holdOverrides;
    if (uniformValues[name]?.length != values.length) return 'unknownUniform';
    overrides[name] = values;
    return null;
  }

  @override
  Future<void> clearUniformOverrides({
    required String asset,
    String? name,
  }) async {
    if (name == null) {
      overrides.clear();
    } else {
      overrides.remove(name);
    }
  }

  @override
  Future<Uri?> rootLibrary() async => mainLibrary;
}
