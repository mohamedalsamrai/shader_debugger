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
    this.pixelSelectAsset,
  });

  factory AppInfo.fromJson(Map<String, Object?> json) => AppInfo(
    protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 0,
    probeAsset: json['probeAsset'] as String? ?? defaultProbeAsset,
    shaders: [
      for (final shader in json['shaders'] as List<Object?>? ?? const [])
        if (shader is String) shader,
    ],
    pixelSelectAsset: json['pixelSelectMode'] as String?,
  );

  final int protocolVersion;

  /// The probe's asset key, such as `shaders/_debug/probe.frag`.
  final String probeAsset;

  /// Asset keys of the shaders the app draws through `DebugShader`.
  final List<String> shaders;

  /// The asset in pixel select mode, if it is on.
  final String? pixelSelectAsset;
}

/// The app's answer to `ext.shader_debugger.showHeatmap`, and the part of
/// its answer to `readPixel` that says whether it used the probe.
@immutable
class ProbeAnswer {
  const ProbeAnswer({required this.applied, this.reason});

  final bool applied;

  /// Why not: `probeNotLoaded`, `probeMissing` or `noShaderForAsset`.
  final String? reason;
}

/// The app's answer to `ext.shader_debugger.readPixel`.
final class PixelAnswer extends ProbeAnswer {
  const PixelAnswer({
    required super.applied,
    super.reason,
    this.value,
    this.exact = true,
  });

  factory PixelAnswer.fromJson(Map<String, Object?> json) => PixelAnswer(
    applied: json['applied'] == true,
    reason: json['reason'] as String?,
    value: switch (json['value']) {
      final List<Object?> value when value.isNotEmpty => _floats(value),
      _ => null,
    },
    exact: json['exact'] != false,
  );

  /// The captured value's x, y, z and w, once applied.
  final List<double>? value;

  /// False when the renderer rounded [value] to 8 bits per channel, clamped
  /// to 0..1, because it cannot draw into a 32-bit float image.
  final bool exact;
}

/// Floats from JSON: numbers, or NaN, Infinity and -Infinity as strings,
/// which JSON cannot carry.
List<double> _floats(List<Object?> json) => [
  for (final component in json)
    switch (component) {
      final num number => number.toDouble(),
      final String text => double.tryParse(text) ?? double.nan,
      _ => double.nan,
    },
];

/// The app's answer to `ext.shader_debugger.getUniforms`.
@immutable
final class UniformValues {
  const UniformValues({required this.values, required this.overrides});

  factory UniformValues.fromJson(Map<String, Object?> json) {
    Map<String, List<double>> byName(Object? map) => {
      if (map is Map)
        for (final MapEntry(:key, :value) in map.entries)
          if (key is String && value is List) key: _floats(value),
    };
    return UniformValues(
      values: byName(json['values']),
      overrides: byName(json['overrides']),
    );
  }

  /// The app's own values, by uniform name.
  final Map<String, List<double>> values;

  /// The overrides in force, by uniform name.
  final Map<String, List<double>> overrides;
}

/// A pixel clicked in the app in select mode: a `shader_debugger.pixelPicked`
/// event.
@immutable
final class PixelPick {
  const PixelPick({
    required this.asset,
    this.instance,
    this.x,
    this.y,
    this.width,
    this.height,
    this.reason,
  });

  factory PixelPick.fromJson(Map<String, Object?> json) {
    double? number(String key) => (json[key] as num?)?.toDouble();
    return PixelPick(
      asset: json['asset'] as String? ?? '',
      instance: (json['instance'] as num?)?.toInt(),
      x: number('x'),
      y: number('y'),
      width: number('width'),
      height: number('height'),
      reason: json['reason'] as String?,
    );
  }

  final String asset;

  /// Which `DebugShader` for [asset] was under the tap.
  final int? instance;

  /// The shader coordinates of the pixel tapped.
  final double? x;
  final double? y;

  /// The size of the area the shader was painted in.
  final double? width;
  final double? height;

  /// Why nothing was picked: `notOnShader`.
  final String? reason;

  bool get hit => reason == null && x != null && y != null;
}

/// The running app, through its VM service.
abstract interface class DebuggedApp {
  /// Whether the app has registered the runtime's service extensions, which
  /// it does when it creates its first `DebugShader`.
  ValueListenable<bool> get hasRuntime;

  Future<AppInfo> getInfo();

  Future<ProbeAnswer> showHeatmap({
    required String asset,
    required int stamp,
    required double min,
    required double max,
  });

  Future<void> hideHeatmap();

  /// Reads the captured value at ([x], [y]) in the shader's coordinates,
  /// with the uniforms of the `DebugShader` numbered [instance], or the
  /// first one for [asset].
  Future<PixelAnswer> readPixel({
    required String asset,
    required int stamp,
    required double x,
    required double y,
    int? instance,
  });

  /// Turns pixel select mode on for [asset], or off: while on, the app
  /// reports each click on [pixelPicks]. Returns whether an overlay takes
  /// the clicks; without one, they also reach the app.
  Future<bool> setPixelSelectMode({required bool enabled, String? asset});

  /// Pixels clicked in the app in select mode.
  Stream<PixelPick> get pixelPicks;

  /// Select mode turned off from the app, with its Done button.
  Stream<void> get pixelSelectModeExits;

  /// The float uniforms the app sets for [asset], and the overrides.
  Future<UniformValues> getUniforms(String asset);

  /// Overrides the uniform [name] of [asset]'s shaders with [values]. Returns
  /// null once applied, or why not: `unknownUniform` or `noShaderForAsset`.
  Future<String?> setUniformOverride({
    required String asset,
    required String name,
    required List<double> values,
  });

  /// Drops the override of [name], or every override of [asset].
  Future<void> clearUniformOverrides({required String asset, String? name});

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
