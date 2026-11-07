import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart'
    show Element, OverlayEntry, OverlayState, StatefulElement, WidgetsBinding;
import 'package:shader_debugger_core/protocol.dart';

import 'debug_shader.dart';
import 'pixel_select.dart';

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

/// Why [ShaderDebugger.setUniformOverride] did not apply.
enum UniformRejection {
  /// No live [DebugShader] uses the asset.
  noShaderForAsset,

  /// The shader has no float uniform of that name and component count.
  unknownUniform,
}

/// A pixel of a [DebugShader] on screen, found by
/// [ShaderDebugger.pixelTargetAt].
@internal
final class PixelTarget {
  const PixelTarget({
    required this.shader,
    required this.box,
    required this.coord,
    required this.center,
    required this.bounds,
  });

  final DebugShader shader;

  /// The render box that painted [shader] there.
  final RenderBox box;

  /// The shader coordinates: what `FlutterFragCoord()` returns at [center].
  final Offset coord;

  /// The center of the device pixel, as a global logical position.
  final Offset center;

  /// Where [box] is, in global logical coordinates.
  final Rect bounds;

  Map<String, Object?> toJson() => {
    'asset': shader.asset,
    'instance': shader.debugId,
    'x': coord.dx,
    'y': coord.dy,
    'width': box.size.width,
    'height': box.size.height,
  };
}

/// The value [ShaderDebugger.readPixel] read, or why it could not.
///
/// [exact] is false when the renderer rounded the value to 8 bits per
/// channel, clamped to 0..1, because it cannot draw into a 32-bit float
/// image.
typedef PixelReading = ({
  List<double>? value,
  ProbeRejection? rejection,
  bool exact,
});

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

  /// The asset whose pixels are being selected, while select mode is on.
  String? _selectAsset;

  /// Uniform overrides, by asset, then by uniform name.
  final Map<String, Map<String, List<double>>> _overrides = {};

  /// The select mode overlay, or null when select mode is off or the app
  /// has no Overlay.
  OverlayEntry? _selectEntry;

  /// Whether select mode watches pointers instead, without an overlay.
  bool _watchingPointers = false;

  /// Whether this renderer reads pixels back as exact 32-bit floats; found
  /// out once.
  Future<bool>? _exactReadback;

  /// Set while [pixelTargetAt] hit tests, so the select mode overlay lets the
  /// test through to the app below it.
  @internal
  bool hitTestingForPixel = false;

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
      return (
        value: null,
        rejection: ProbeRejection.noShaderForAsset,
        exact: false,
      );
    }
    final candidates = shaders.where((shader) => shader.asset == asset);
    final shader =
        candidates.where((shader) => shader.debugId == instance).firstOrNull ??
        candidates.firstOrNull;
    if (shader == null) {
      return (
        value: null,
        rejection: ProbeRejection.noShaderForAsset,
        exact: false,
      );
    }
    final ui.FragmentProgram program;
    try {
      program = await _loadProbe();
    } on Exception {
      return (
        value: null,
        rejection: ProbeRejection.probeMissing,
        exact: false,
      );
    }
    if (!_hasStamp(program, stamp)) {
      return (
        value: null,
        rejection: ProbeRejection.probeNotLoaded,
        exact: false,
      );
    }
    final probe = program.fragmentShader();
    try {
      shader.replayOnto(probe);
      probe.getUniformVec2(ProbeUniforms.coord).set(coord.dx, coord.dy);
      final mode = probe.getUniformFloat(ProbeUniforms.mode)
        ..set(ProbeMode.pixel.uniformValue);
      final xyz = await _drawPixel(Paint()..shader = probe);
      mode.set(ProbeMode.pixelW.uniformValue);
      final w = await _drawPixel(Paint()..shader = probe);
      return (
        value: [xyz[0], xyz[1], xyz[2], w[0]],
        rejection: null,
        exact: await (_exactReadback ??= _readsExactFloats()),
      );
    } finally {
      probe.dispose();
    }
  }

  /// The asset whose pixels are being selected, while select mode is on.
  String? get pixelSelectAsset => _selectAsset;

  /// The uniform overrides in force for [asset], by uniform name.
  Map<String, List<double>> overridesFor(String asset) =>
      _overrides[asset] ?? const {};

  /// The float uniforms the app set on the first [DebugShader] for [asset],
  /// or null when no [DebugShader] uses it.
  Map<String, List<double>>? uniformValues(String asset) => shaders
      .where((shader) => shader.asset == asset)
      .firstOrNull
      ?.recordedUniforms;

  /// Overrides the float uniform [name] of every [DebugShader] for [asset]
  /// with [values], one per component: on every paint, and in the probe,
  /// until [clearUniformOverrides]. Returns null once applied, or why not.
  UniformRejection? setUniformOverride(
    String asset,
    String name,
    List<double> values,
  ) {
    if (!kDebugMode) return UniformRejection.noShaderForAsset;
    final first = shaders.where((shader) => shader.asset == asset).firstOrNull;
    if (first == null) return UniformRejection.noShaderForAsset;
    if (!first.hasFloatUniform(name, values.length)) {
      return UniformRejection.unknownUniform;
    }
    (_overrides[asset] ??= {})[name] = List.unmodifiable(values);
    _repaintShaders(asset);
    return null;
  }

  /// Drops the override of [name] for [asset], or every override for it
  /// when [name] is null, so the app's own values apply again.
  void clearUniformOverrides(String asset, {String? name}) {
    final overrides = _overrides[asset];
    if (overrides == null) return;
    if (name == null) {
      _overrides.remove(asset);
    } else {
      overrides.remove(name);
      if (overrides.isEmpty) _overrides.remove(asset);
    }
    _repaintShaders(asset);
  }

  /// Repaints what painted the [DebugShader]s for [asset], so a change shows
  /// even when the app has no reason to repaint.
  void _repaintShaders(String asset) {
    for (final shader in shaders.where((shader) => shader.asset == asset)) {
      for (final box in shader.painters) {
        box.markNeedsPaint();
      }
    }
  }

  /// Turns pixel select mode on for [asset], or off.
  ///
  /// Like the widget inspector's select mode: an overlay covers the app and
  /// takes its clicks and taps, hovering highlights the pixel under the
  /// pointer, and each click posts a [ServiceEvents.pixelPicked] event. It
  /// stays on until turned off. Returns whether the overlay is shown; without
  /// an `Overlay` in the app (no `WidgetsApp` or `Navigator`), clicks are
  /// watched instead, and also reach the app.
  bool setPixelSelectMode({required bool enabled, String? asset}) {
    if (!kDebugMode) return false;
    if (!enabled) {
      _endPixelSelect();
      return false;
    }
    if (asset == null) throw ArgumentError.notNull('asset');
    _selectAsset = asset;
    if (_selectEntry case final entry?) {
      entry.markNeedsBuild();
      return true;
    }
    if (_watchingPointers) return false;
    if (_rootOverlay() case final overlay?) {
      final entry = OverlayEntry(
        builder: (context) => PixelSelectLayer(debugger: this),
      );
      _selectEntry = entry;
      overlay.insert(entry);
      return true;
    }
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
    _watchingPointers = true;
    return false;
  }

  /// Leaves select mode from the app, with the overlay's Done button, and
  /// tells DevTools.
  @internal
  void leavePixelSelectMode() {
    _endPixelSelect();
    postEvent(ServiceEvents.pixelSelectMode, {'enabled': false});
  }

  /// A click in select mode: posts what is under [position] as a
  /// [ServiceEvents.pixelPicked] event, and returns it.
  @internal
  PixelTarget? selectPixel(Offset position, {int? viewId}) {
    final asset = _selectAsset;
    if (asset == null) return null;
    final target = pixelTargetAt(asset, position, viewId: viewId);
    postEvent(
      ServiceEvents.pixelPicked,
      target?.toJson() ?? {'asset': asset, 'reason': 'notOnShader'},
    );
    return target;
  }

  /// The shader coordinates under [position], a global logical position, as
  /// [ServiceEvents.pixelPicked] reports them.
  Map<String, Object?> pickAt(String asset, Offset position, {int? viewId}) =>
      pixelTargetAt(asset, position, viewId: viewId)?.toJson() ??
      {'asset': asset, 'reason': 'notOnShader'};

  /// The pixel of a [DebugShader] for [asset] under [position], a global
  /// logical position, or null.
  ///
  /// The position goes to the topmost render box that painted a
  /// [DebugShader] for [asset], and is moved to the center of the device
  /// pixel it falls in. The coordinates are that box's local ones, which is
  /// what `FlutterFragCoord()` returns unless the painter transformed the
  /// canvas.
  @internal
  PixelTarget? pixelTargetAt(String asset, Offset position, {int? viewId}) {
    final owners = <RenderBox, DebugShader>{};
    for (final shader in shaders.where((shader) => shader.asset == asset)) {
      for (final box in shader.painters) {
        owners.putIfAbsent(box, () => shader);
      }
    }
    if (owners.isEmpty) return null;
    final views = RendererBinding.instance.renderViews;
    final view =
        views.where((view) => view.flutterView.viewId == viewId).firstOrNull ??
        views.firstOrNull;
    RenderBox? box;
    if (view != null) {
      final result = HitTestResult();
      hitTestingForPixel = true;
      try {
        RendererBinding.instance.hitTestInView(
          result,
          position,
          view.flutterView.viewId,
        );
      } on AssertionError {
        // Part of the tree awaits layout; fall back to the bounds below.
      } finally {
        hitTestingForPixel = false;
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
    if (box == null) return null;
    final ratio = view?.flutterView.devicePixelRatio ?? 1.0;
    double centered(double logical) =>
        ((logical * ratio).floorToDouble() + 0.5) / ratio;
    final center = Offset(centered(position.dx), centered(position.dy));
    return PixelTarget(
      shader: owners[box]!,
      box: box,
      coord: box.globalToLocal(center),
      center: center,
      bounds: MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      ),
    );
  }

  void _endPixelSelect() {
    _selectAsset = null;
    final entry = _selectEntry;
    _selectEntry = null;
    if (entry != null) {
      entry
        ..remove()
        ..dispose();
    }
    if (_watchingPointers) {
      _watchingPointers = false;
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
    }
  }

  /// Select mode without an overlay: clicks are watched, not taken.
  void _pointer(PointerEvent event) {
    if (event is PointerDownEvent) {
      selectPixel(event.position, viewId: event.viewId);
    }
  }

  /// The app's outermost Overlay: the root Navigator's, in a `WidgetsApp`.
  static OverlayState? _rootOverlay() {
    OverlayState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element case StatefulElement(:final OverlayState state)) {
        found = state;
        return;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return found;
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

  /// Draws a known 0.3 into a 32-bit float pixel and reads it back: an
  /// 8-bit target returns 77/255 instead.
  static Future<bool> _readsExactFloats() async {
    final read = await _drawPixel(
      Paint()..color = const Color.from(alpha: 1, red: 0.3, green: 0, blue: 0),
    );
    return (read[0] - 0.3).abs() < 1e-6;
  }

  static Future<List<double>> _drawPixel(Paint paint) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 1, 1),
      paint..blendMode = BlendMode.src,
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
          'pixelSelectMode': _selectAsset,
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
          'exact': reading.exact,
          // JSON has no NaN or infinities; a shader value can be either.
          'value': [
            for (final component in reading.value ?? const <double>[])
              component.isFinite ? component : '$component',
          ],
        };
      case ServiceExtensions.setPixelSelectMode:
        final enabled = switch (parameters['enabled']) {
          'true' => true,
          'false' => false,
          _ => throw const FormatException(
            'setPixelSelectMode needs "enabled": true or false.',
          ),
        };
        final asset = parameters['asset'];
        if (enabled && asset == null) {
          throw const FormatException(
            'setPixelSelectMode needs "asset" to turn it on.',
          );
        }
        final overlay = setPixelSelectMode(enabled: enabled, asset: asset);
        return {'enabled': enabled, 'overlay': overlay};
      case ServiceExtensions.getUniforms:
        final asset = _required(parameters, 'asset');
        List<Object> json(List<double> values) => [
          for (final value in values) value.isFinite ? value : '$value',
        ];
        return {
          'values': {
            for (final MapEntry(:key, :value)
                in (uniformValues(asset) ?? const {}).entries)
              key: json(value),
          },
          'overrides': {
            for (final MapEntry(:key, :value) in overridesFor(asset).entries)
              key: json(value),
          },
        };
      case ServiceExtensions.setUniformOverride:
        final asset = _required(parameters, 'asset');
        final name = _required(parameters, 'name');
        final values = [
          for (final text in _required(parameters, 'values').split(','))
            double.tryParse(text.trim()) ??
                (throw FormatException('"values" has "$text", not a number.')),
        ];
        final rejection = setUniformOverride(asset, name, values);
        return {'applied': rejection == null, 'reason': rejection?.name};
      case ServiceExtensions.clearUniformOverrides:
        clearUniformOverrides(
          _required(parameters, 'asset'),
          name: parameters['name'],
        );
        return {'applied': true};
      case ServiceExtensions.pickPixel:
        final asset = parameters['asset'];
        if (asset == null) {
          throw const FormatException('pickPixel needs "asset", "x" and "y".');
        }
        final position = Offset(
          _parseDouble(parameters, 'x', null),
          _parseDouble(parameters, 'y', null),
        );
        // Unlike a click, this can come right after a heatmap change marked
        // the tree for layout; hit testing needs it laid out.
        await _endOfPendingFrame();
        return pickAt(asset, position);
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
      ServiceExtensions.setPixelSelectMode,
      ServiceExtensions.pickPixel,
      ServiceExtensions.getUniforms,
      ServiceExtensions.setUniformOverride,
      ServiceExtensions.clearUniformOverrides,
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

  static String _required(Map<String, String> parameters, String key) =>
      parameters[key] ?? (throw FormatException('"$key" is required.'));

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
