/// What the debugger needs from the outside world: the running app, and the
/// developer's files. `devtools_ports.dart` implements these on top of
/// DevTools; tests use fakes.
library;

import 'package:flutter/foundation.dart';
import 'package:shader_debugger_core/protocol.dart';

/// The app's answer to `ext.shader_debugger.getInfo`.
@immutable
final class AppInfo {
  const AppInfo({
    required this.protocolVersion,
    required this.probeAsset,
    required this.shaders,
  });

  factory AppInfo.fromJson(Map<String, Object?> json) => AppInfo(
    protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 0,
    probeAsset: json['probeAsset'] as String? ?? defaultProbeAsset,
    shaders: [
      for (final shader in json['shaders'] as List<Object?>? ?? const [])
        if (shader is String) shader,
    ],
  );

  final int protocolVersion;

  /// The probe's asset key, such as `shaders/_debug/probe.frag`.
  final String probeAsset;

  /// Asset keys of the shaders the app draws through `DebugShader`.
  final List<String> shaders;
}

/// The app's answer to `ext.shader_debugger.showHeatmap`.
@immutable
final class HeatmapAnswer {
  const HeatmapAnswer({required this.applied, this.reason});

  final bool applied;

  /// Why not: `probeNotLoaded`, `probeMissing` or `noShaderForAsset`.
  final String? reason;
}

/// The running app, through its VM service.
abstract interface class DebuggedApp {
  /// Whether the app has registered the runtime's service extensions, which
  /// it does when it creates its first `DebugShader`.
  ValueListenable<bool> get hasRuntime;

  Future<AppInfo> getInfo();

  Future<HeatmapAnswer> showHeatmap({
    required String asset,
    required int stamp,
    required double min,
    required double max,
  });

  Future<void> hideHeatmap();

  /// Hot reloads the app. Throws if the reload fails, for example because the
  /// probe does not compile.
  Future<void> hotReload();

  /// The file URI of the app's main library, or null if it is not known.
  Future<Uri?> rootLibrary();
}

/// Why a [Workspace] call failed.
enum WorkspaceError {
  /// No connection to the Dart Tooling Daemon.
  unavailable,

  /// The file is outside the IDE's workspace folders.
  permissionDenied,

  /// The file does not exist.
  notFound,

  other,
}

final class WorkspaceException implements Exception {
  const WorkspaceException(this.error, this.message);

  final WorkspaceError error;
  final String message;

  @override
  String toString() => 'WorkspaceException(${error.name}): $message';
}

/// The developer's files, through the Dart Tooling Daemon.
abstract interface class Workspace {
  /// Throws a [WorkspaceException] when [file] cannot be read.
  Future<String> read(Uri file);

  /// Throws a [WorkspaceException] when [file] cannot be written.
  Future<void> write(Uri file, String contents);
}
