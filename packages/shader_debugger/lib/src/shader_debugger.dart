import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
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

/// Why [ShaderDebugger.showHeatmap] or [ShaderDebugger.readPixel] did not
/// apply.
enum ProbeRejection {
  /// No live [DebugShader] uses the asset.
  noShaderForAsset,

  /// The probe asset could not be loaded: it is probably not registered under
  /// `flutter: shaders:` in the app's pubspec.
  probeMissing,

  /// The loaded probe does not carry the stamp yet. Right after a hot reload
  /// this is usually transient; retry.
  probeNotLoaded,
}

/// The value [ShaderDebugger.readPixel] read, or why it could not.
typedef PixelReading = ({List<double>? value, ProbeRejection? rejection});

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

  /// The asset a tap is awaited for, after [pickPixel].
  String? _pickAsset;

  /// Posts events on the Extension stream; replaceable in tests.
  @visibleForTesting
  void Function(String kind, Map<Object?, Object?> data) postEvent =
      developer.postEvent;

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
  Future<ProbeRejection?> showHeatmap(HeatmapState state) async {
    if (!kDebugMode) return ProbeRejection.noShaderForAsset;
    if (!shaders.any((shader) => shader.asset == state.asset)) {
      return ProbeRejection.noShaderForAsset;
    }
    final ui.FragmentProgram program;
    try {
      program = await _loadProbe();
    } on Exception {
      return ProbeRejection.probeMissing;
    }
    if (!_hasStamp(program, state.stamp)) {
      return ProbeRejection.probeNotLoaded;
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

  /// Reads the captured value at [coord], in the shader's coordinates (what
  /// `FlutterFragCoord()` returns there), as x, y, z and w.
  ///
  /// The probe is drawn offscreen into one 32-bit float pixel, with the
  /// uniforms of the [DebugShader] for [asset] whose [DebugShader.debugId]
  /// is [instance], or of the first one. The engine used by `flutter test`
  /// rounds the result to 8 bits per channel; Impeller reads it exactly.
  Future<PixelReading> readPixel({
    required String asset,
    required int stamp,
    required Offset coord,
    int? instance,
  }) async {
    if (!kDebugMode) {
      return (value: null, rejection: ProbeRejection.noShaderForAsset);
    }
    final candidates = shaders.where((shader) => shader.asset == asset);
    final shader =
        candidates.where((shader) => shader.debugId == instance).firstOrNull ??
        candidates.firstOrNull;
    if (shader == null) {
      return (value: null, rejection: ProbeRejection.noShaderForAsset);
    }
    final ui.FragmentProgram program;
    try {
      program = await _loadProbe();
    } on Exception {
      return (value: null, rejection: ProbeRejection.probeMissing);
    }
    if (!_hasStamp(program, stamp)) {
      return (value: null, rejection: ProbeRejection.probeNotLoaded);
    }
    final probe = program.fragmentShader();
    try {
      shader.replayOnto(probe);
      probe.getUniformVec2(ProbeUniforms.coord).set(coord.dx, coord.dy);
      final mode = probe.getUniformFloat(ProbeUniforms.mode)
        ..set(ProbeMode.pixel.uniformValue);
      final xyz = await _drawPixel(probe);
      mode.set(ProbeMode.pixelW.uniformValue);
      final w = await _drawPixel(probe);
      return (value: [xyz[0], xyz[1], xyz[2], w[0]], rejection: null);
    } finally {
      probe.dispose();
    }
  }

  /// Waits for the next tap in the app, then posts a
  /// [ServiceEvents.pixelPicked] event with what [pickAt] finds there. The
  /// tap still reaches the app.
  void pickPixel(String asset) {
    if (!kDebugMode) return;
    if (_pickAsset == null) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    }
    _pickAsset = asset;
  }

  /// Stops waiting for a tap.
  void cancelPick() {
    if (_pickAsset == null) return;
    _pickAsset = null;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
  }

  /// The shader coordinates under [position], a global logical position, as
  /// [ServiceEvents.pixelPicked] reports them.
  ///
  /// The tap goes to the topmost render box that painted a [DebugShader] for
  /// [asset], and is moved to the center of the device pixel it falls in.
  /// The coordinates are that box's local ones, which is what
  /// `FlutterFragCoord()` returns unless the painter transformed the canvas.
  Map<String, Object?> pickAt(String asset, Offset position, {int? viewId}) {
    final owners = <RenderBox, DebugShader>{};
    for (final shader in shaders.where((shader) => shader.asset == asset)) {
      for (final box in shader.painters) {
        owners.putIfAbsent(box, () => shader);
      }
    }
    final views = RendererBinding.instance.renderViews;
    final view =
        views.where((view) => view.flutterView.viewId == viewId).firstOrNull ??
        views.firstOrNull;
    RenderBox? box;
    if (view != null) {
      final result = HitTestResult();
      try {
        RendererBinding.instance.hitTestInView(
          result,
          position,
          view.flutterView.viewId,
        );
      } on AssertionError {
        // Part of the tree awaits layout; fall back to the bounds below.
      }
      box = result.path
          .map((entry) => entry.target)
          .whereType<RenderBox>()
          .where(owners.containsKey)
          .firstOrNull;
    }
    // A box that is not hit-testable can still have painted there.
    box ??= owners.keys
        .where((box) => box.size.contains(box.globalToLocal(position)))
        .firstOrNull;
    if (box == null) return {'asset': asset, 'reason': 'notOnShader'};
    final ratio = view?.flutterView.devicePixelRatio ?? 1.0;
    double center(double logical) =>
        ((logical * ratio).floorToDouble() + 0.5) / ratio;
    final local = box.globalToLocal(
      Offset(center(position.dx), center(position.dy)),
    );
    return {
      'asset': asset,
      'instance': owners[box]!.debugId,
      'x': local.dx,
      'y': local.dy,
      'width': box.size.width,
      'height': box.size.height,
    };
  }

  void _pointer(PointerEvent event) {
    final asset = _pickAsset;
    if (event is! PointerDownEvent || asset == null) return;
    cancelPick();
    postEvent(
      ServiceEvents.pixelPicked,
      pickAt(asset, event.position, viewId: event.viewId),
    );
  }

  static Future<void> _endOfPendingFrame() async {
    final scheduler = SchedulerBinding.instance;
    if (!scheduler.hasScheduledFrame &&
        scheduler.schedulerPhase == SchedulerPhase.idle) {
      return;
    }
    // A hidden window may never draw it; do not wait forever.
    await scheduler.endOfFrame.timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
  }

  static Future<List<double>> _drawPixel(ui.FragmentShader shader) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      Paint()
        ..shader = shader
        ..blendMode = BlendMode.src,
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      1,
      1,
      targetFormat: ui.TargetPixelFormat.rgbaFloat32,
    );
    try {
      final bytes = await image.toByteData(
        format: ui.ImageByteFormat.rawExtendedRgba128,
      );
      return bytes!.buffer.asFloat32List(bytes.offsetInBytes, 4);
    } finally {
      image.dispose();
      picture.dispose();
    }
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
      case ServiceExtensions.readPixel:
        final asset = parameters['asset'];
        final stamp = int.tryParse(parameters['stamp'] ?? '');
        if (asset == null || stamp == null) {
          throw const FormatException(
            'readPixel needs "asset", an integer "stamp", "x" and "y".',
          );
        }
        final instance = parameters['instance'];
        final reading = await readPixel(
          asset: asset,
          stamp: stamp,
          coord: Offset(
            _parseDouble(parameters, 'x', null),
            _parseDouble(parameters, 'y', null),
          ),
          instance: instance == null ? null : int.tryParse(instance),
        );
        return {
          'applied': reading.rejection == null,
          'reason': reading.rejection?.name,
          // JSON has no NaN or infinities; a shader value can be either.
          'value': [
            for (final component in reading.value ?? const <double>[])
              component.isFinite ? component : '$component',
          ],
        };
      case ServiceExtensions.pickPixel:
        final asset = parameters['asset'];
        if (asset == null) {
          throw const FormatException('pickPixel needs "asset".');
        }
        if (parameters.containsKey('x') || parameters.containsKey('y')) {
          // Unlike a tap, this can come right after a heatmap change marked
          // the tree for layout; hit testing needs it laid out.
          await _endOfPendingFrame();
          return pickAt(
            asset,
            Offset(
              _parseDouble(parameters, 'x', null),
              _parseDouble(parameters, 'y', null),
            ),
          );
        }
        pickPixel(asset);
        return {'armed': true};
      case ServiceExtensions.cancelPick:
        cancelPick();
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
      ServiceExtensions.readPixel,
      ServiceExtensions.pickPixel,
      ServiceExtensions.cancelPick,
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

  /// The number [key] in [parameters], or [fallback] when it is missing.
  /// Without a [fallback], it is required.
  static double _parseDouble(
    Map<String, String> parameters,
    String key,
    double? fallback,
  ) {
    final raw = parameters[key];
    if (raw == null) {
      return fallback ?? (throw FormatException('"$key" is required.'));
    }
    return double.tryParse(raw) ??
        (throw FormatException('"$key" must be a number, not "$raw".'));
  }
}
