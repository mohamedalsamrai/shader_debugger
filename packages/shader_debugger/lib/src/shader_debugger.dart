import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:shader_debugger_core/protocol.dart';

import 'debug_shader.dart';

/// The heatmap being shown: which shader, which probe, and the value range.
@immutable
final class HeatmapState {
  const HeatmapState({
    required this.asset,
    required this.stamp,
    this.min = 0,
    this.max = 1,
  });

  /// The asset key of the shader the probe was generated from.
  final String asset;

  /// The stamp the loaded probe must carry.
  final int stamp;

  /// The value drawn as the low end of the colormap.
  final double min;

  /// The value drawn as the high end of the colormap.
  final double max;

  Map<String, Object> toJson() => {
    'asset': asset,
    'stamp': stamp,
    'min': min,
    'max': max,
  };

  @override
  String toString() => 'HeatmapState($asset, stamp $stamp, $min..$max)';
}

/// Why [ShaderDebugger.showHeatmap] did not apply.
enum HeatmapRejection {
  /// No live [DebugShader] uses the asset.
  noShaderForAsset,

  /// The probe asset could not be loaded: it is probably not registered under
  /// `flutter: shaders:` in the app's pubspec.
  probeMissing,

  /// The loaded probe does not carry the stamp yet. Right after a hot reload
  /// this is usually transient; retry.
  probeNotLoaded,
}

/// The app side of the Shader Debugger: it tracks the live [DebugShader]s,
/// owns the probe program, and answers the DevTools extension through the
/// `ext.shader_debugger.*` service extensions (debug mode only).
final class ShaderDebugger {
  ShaderDebugger._();

  static final ShaderDebugger instance = ShaderDebugger._();

  /// The probe's asset key. It must be registered under `flutter: shaders:`.
  String probeAsset = defaultProbeAsset;

  final List<WeakReference<DebugShader>> _shaders = [];
  HeatmapState? _heatmap;
  ui.FragmentProgram? _probeProgram;
  String? _probeProgramAsset;
  bool _extensionsRegistered = false;

  /// The heatmap being shown, or null.
  HeatmapState? get heatmap => _heatmap;

  /// The live debug shaders.
  Iterable<DebugShader> get shaders =>
      _shaders.map((reference) => reference.target).whereType<DebugShader>();

  /// Registers the service extensions now. [DebugShader] does this on first
  /// use; call it earlier so DevTools sees the extensions before any shader
  /// exists. Does nothing outside debug mode.
  static void ensureInitialized() => instance._registerExtensions();

  /// Draws the probe in place of the debug shaders for [state]'s asset.
  ///
  /// Returns null once applied, or why it was not. A rejection leaves the
  /// current heatmap as it was.
  Future<HeatmapRejection?> showHeatmap(HeatmapState state) async {
    if (!kDebugMode) return HeatmapRejection.noShaderForAsset;
    if (!shaders.any((shader) => shader.asset == state.asset)) {
      return HeatmapRejection.noShaderForAsset;
    }
    final ui.FragmentProgram program;
    try {
      program = await _loadProbe();
    } on Exception {
      return HeatmapRejection.probeMissing;
    }
    if (!_hasStamp(program, state.stamp)) {
      return HeatmapRejection.probeNotLoaded;
    }
    _heatmap = state;
    for (final shader in shaders) {
      shader.resetProbe(discardShader: false);
    }
    _repaint();
    return null;
  }

  /// Draws the original shaders again.
  void hideHeatmap() {
    if (_heatmap == null) return;
    _heatmap = null;
    _repaint();
  }

  /// Answers one of the [ServiceExtensions] calls. Throws a
  /// [FormatException] for bad parameters.
  @visibleForTesting
  Future<Map<String, Object?>> handleServiceExtension(
    String method,
    Map<String, String> parameters,
  ) async {
    switch (method) {
      case ServiceExtensions.getInfo:
        return {
          'protocolVersion': protocolVersion,
          'probeAsset': probeAsset,
          'shaders': shaders.map((shader) => shader.asset).toSet().toList(),
          'heatmap': _heatmap?.toJson(),
        };
      case ServiceExtensions.showHeatmap:
        final asset = parameters['asset'];
        final stamp = int.tryParse(parameters['stamp'] ?? '');
        if (asset == null || stamp == null) {
          throw const FormatException(
            'showHeatmap needs "asset" and an integer "stamp".',
          );
        }
        final rejection = await showHeatmap(
          HeatmapState(
            asset: asset,
            stamp: stamp,
            min: _parseDouble(parameters, 'min', 0),
            max: _parseDouble(parameters, 'max', 1),
          ),
        );
        return {'applied': rejection == null, 'reason': rejection?.name};
      case ServiceExtensions.hideHeatmap:
        hideHeatmap();
        return {'applied': true};
    }
    throw FormatException('Unknown method: $method');
  }

  /// Called by [DebugShader] when it is created.
  @internal
  void register(DebugShader shader) {
    _registerExtensions();
    _shaders
      ..removeWhere((reference) => reference.target == null)
      ..add(WeakReference(shader));
  }

  /// Called by [DebugShader.dispose].
  @internal
  void unregister(DebugShader shader) => _shaders.removeWhere(
    (reference) =>
        reference.target == null || identical(reference.target, shader),
  );

  /// The heatmap for [asset], if one is shown.
  @internal
  HeatmapState? heatmapFor(String asset) =>
      _heatmap?.asset == asset ? _heatmap : null;

  /// A new shader from the probe program, or null before it is loaded.
  @internal
  ui.FragmentShader? newProbeShader() => _probeProgram?.fragmentShader();

  Future<ui.FragmentProgram> _loadProbe() async {
    final loaded = _probeProgram;
    if (loaded != null && _probeProgramAsset == probeAsset) return loaded;
    // fromAsset caches the program; hot reload then swaps its code in place.
    final program = await ui.FragmentProgram.fromAsset(probeAsset);
    _probeProgram = program;
    _probeProgramAsset = probeAsset;
    for (final shader in shaders) {
      shader.resetProbe(discardShader: true);
    }
    return program;
  }

  static bool _hasStamp(ui.FragmentProgram program, int stamp) {
    final shader = program.fragmentShader();
    try {
      shader.getUniformFloat(ProbeUniforms.stamp(stamp));
      return true;
    } on ArgumentError {
      return false;
    } finally {
      shader.dispose();
    }
  }

  /// Repaints everything, including layers behind repaint boundaries, the way
  /// hot reload does. Debug only, and only when the heatmap changes.
  static void _repaint() {
    for (final view in RendererBinding.instance.renderViews) {
      view.reassemble();
    }
  }

  void _registerExtensions() {
    if (!kDebugMode || _extensionsRegistered) return;
    _extensionsRegistered = true;
    for (final method in [
      ServiceExtensions.getInfo,
      ServiceExtensions.showHeatmap,
      ServiceExtensions.hideHeatmap,
    ]) {
      developer.registerExtension(method, (method, parameters) async {
        try {
          final result = await handleServiceExtension(method, parameters);
          return developer.ServiceExtensionResponse.result(jsonEncode(result));
        } on FormatException catch (error) {
          return developer.ServiceExtensionResponse.error(
            developer.ServiceExtensionResponse.invalidParams,
            error.message,
          );
        }
      });
    }
  }

  static double _parseDouble(
    Map<String, String> parameters,
    String key,
    double fallback,
  ) {
    final raw = parameters[key];
    if (raw == null) return fallback;
    return double.tryParse(raw) ??
        (throw FormatException('"$key" must be a number, not "$raw".'));
  }
}
