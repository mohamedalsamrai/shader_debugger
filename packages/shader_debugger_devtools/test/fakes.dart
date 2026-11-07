/// Fakes for the debugger's ports: an app that behaves like the runtime
/// package, and an in-memory workspace.
library;

import 'package:flutter/foundation.dart';
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

/// The 0-based line of [text] in [gradientSource].
int lineOf(String text) =>
    gradientSource
        .substring(0, gradientSource.indexOf(text))
        .split('\n')
        .length -
    1;

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
    protocolVersion: 1,
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
  Future<HeatmapAnswer> showHeatmap({
    required String asset,
    required int stamp,
    required double min,
    required double max,
  }) async {
    final call = (asset: asset, stamp: stamp, min: min, max: max);
    heatmapCalls.add(call);
    if (refuseWith != null) {
      return HeatmapAnswer(applied: false, reason: refuseWith);
    }
    if (slowAsks > 0) {
      slowAsks--;
      return const HeatmapAnswer(applied: false, reason: 'probeNotLoaded');
    }
    if (stamp != loadedStamp) {
      return const HeatmapAnswer(applied: false, reason: 'probeNotLoaded');
    }
    shown = call;
    return const HeatmapAnswer(applied: true);
  }

  @override
  Future<void> hideHeatmap() async => shown = null;

  @override
  Future<Uri?> rootLibrary() async => mainLibrary;
}
