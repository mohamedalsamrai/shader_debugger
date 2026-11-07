import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:shader_debugger_core/protocol.dart';

import 'shader_debugger.dart';

/// A fragment shader that the Shader Debugger can replace with a probe.
///
/// Use it like a [ui.FragmentShader] whose uniforms are set by name, and read
/// [shader] in every paint, after setting the uniforms:
///
/// ```dart
/// final shader = await DebugShader.fromAsset('shaders/gradient.frag');
/// final size = shader.getUniformVec2('uSize');
///
/// // In paint():
/// size.set(width, height);
/// canvas.drawRect(rect, Paint()..shader = shader.shader);
/// ```
///
/// In debug mode it records every uniform it is given. While the DevTools
/// extension shows a heatmap for this shader's [asset], [shader] returns the
/// probe with the recorded uniforms replayed on it. In profile and release
/// mode it records nothing and [shader] is always the original.
///
/// Only the name-based uniform API is offered: the probe adds uniforms of its
/// own, so values are replayed by name, never by float index.
class DebugShader {
  /// Wraps a new shader from [program], which was loaded from [asset].
  ///
  /// [asset] must be the asset key the program came from, such as
  /// `shaders/gradient.frag`: the DevTools extension reads that file to
  /// instrument it.
  DebugShader(ui.FragmentProgram program, {required this.asset})
    : _original = program.fragmentShader() {
    if (kDebugMode) ShaderDebugger.instance.register(this);
  }

  /// Loads the program for [asset] and wraps a shader from it.
  static Future<DebugShader> fromAsset(String asset) async =>
      DebugShader(await ui.FragmentProgram.fromAsset(asset), asset: asset);

  /// The asset key of the shader's source, such as `shaders/gradient.frag`.
  final String asset;

  static int _lastId = 0;

  /// Tells this shader apart from others for the same [asset]: a pixel
  /// picked in the app names the instance under it, and
  /// [ShaderDebugger.readPixel] reads with that instance's uniforms.
  final int debugId = ++_lastId;

  /// The render boxes that painted with [shader] lately, most recent first.
  final List<WeakReference<RenderBox>> _painters = [];

  final ui.FragmentShader _original;
  final Map<(String, int), double> _floats = {};
  final Map<String, ui.Image> _images = {};

  ui.FragmentShader? _probe;
  final Map<(String, int), ui.UniformFloatSlot?> _probeFloats = {};
  final Map<String, ui.ImageSamplerSlot?> _probeSamplers = {};
  bool _disposed = false;

  /// The shader to draw with: the original, or the probe while a heatmap is
  /// shown for [asset].
  ///
  /// Read it in every paint, after setting this frame's uniforms. Reading it
  /// copies the recorded uniforms onto the probe; a hot reload of the probe
  /// resets them to zero.
  ui.Shader get shader {
    assert(!_disposed, 'DebugShader used after dispose: $asset');
    if (!kDebugMode) return _original;
    _notePainter();
    final heatmap = ShaderDebugger.instance.heatmapFor(asset);
    if (heatmap == null) return _original;
    final probe = _probe ??= ShaderDebugger.instance.newProbeShader();
    if (probe == null) return _original;
    _replay(heatmap);
    return probe;
  }

  /// The float uniform [name], or its component [index] for a vector or
  /// matrix (in column-major order).
  DebugUniformFloat getUniformFloat(String name, [int index = 0]) =>
      DebugUniformFloat._(
        this,
        name,
        index,
        _original.getUniformFloat(name, index),
      );

  /// The `vec2` uniform [name].
  DebugUniformVec2 getUniformVec2(String name) {
    _original.getUniformVec2(name); // Throws unless [name] is a vec2.
    return DebugUniformVec2._([
      for (var i = 0; i < 2; i++) getUniformFloat(name, i),
    ]);
  }

  /// The `vec3` uniform [name].
  DebugUniformVec3 getUniformVec3(String name) {
    _original.getUniformVec3(name); // Throws unless [name] is a vec3.
    return DebugUniformVec3._([
      for (var i = 0; i < 3; i++) getUniformFloat(name, i),
    ]);
  }

  /// The `vec4` uniform [name].
  DebugUniformVec4 getUniformVec4(String name) {
    _original.getUniformVec4(name); // Throws unless [name] is a vec4.
    return DebugUniformVec4._([
      for (var i = 0; i < 4; i++) getUniformFloat(name, i),
    ]);
  }

  /// The `sampler2D` uniform [name].
  DebugImageSampler getImageSampler(String name) =>
      DebugImageSampler._(this, name, _original.getImageSampler(name));

  /// Releases the shaders and the recorded images.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (kDebugMode) ShaderDebugger.instance.unregister(this);
    _original.dispose();
    _probe?.dispose();
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }

  /// The attached render boxes that painted with [shader] lately, most
  /// recent first. A tap maps to the shader's coordinates through them.
  @internal
  Iterable<RenderBox> get painters => _painters
      .map((reference) => reference.target)
      .whereType<RenderBox>()
      .where((box) => box.attached);

  /// Sets the recorded uniforms on [target], a shader from the probe, by
  /// name. Uniforms the probe does not have are skipped.
  @internal
  void replayOnto(ui.FragmentShader target) {
    for (final MapEntry(key: (name, index), :value) in _floats.entries) {
      try {
        target.getUniformFloat(name, index).set(value);
      } on ArgumentError {
        // Not in the probe.
      }
    }
    for (final MapEntry(key: name, value: image) in _images.entries) {
      try {
        target.getImageSampler(name).set(image);
      } on ArgumentError {
        // Not in the probe.
      }
    }
  }

  /// Forgets the probe's slots; called when a different probe is shown.
  @internal
  void resetProbe({required bool discardShader}) {
    _probeFloats.clear();
    _probeSamplers.clear();
    if (discardShader) {
      _probe?.dispose();
      _probe = null;
    }
  }

  // Remembers the render box painting with this shader. A painter that
  // transforms the canvas itself is not accounted for.
  void _notePainter() {
    final painter = RenderObject.debugActivePaint;
    if (painter is! RenderBox) return;
    if (_painters.isNotEmpty && identical(_painters.first.target, painter)) {
      return;
    }
    _painters
      ..removeWhere(
        (reference) =>
            reference.target == null || identical(reference.target, painter),
      )
      ..insert(0, WeakReference(painter));
    if (_painters.length > 8) _painters.removeLast();
  }

  void _record(String name, int index, double value) {
    if (kDebugMode) _floats[(name, index)] = value;
  }

  void _recordImage(String name, ui.Image image) {
    if (!kDebugMode) return;
    // A clone keeps the image alive even if the app disposes its handle.
    _images[name]?.dispose();
    _images[name] = image.clone();
  }

  void _replay(HeatmapState heatmap) {
    for (final MapEntry(key: (name, index), :value) in _floats.entries) {
      _probeFloat(name, index)?.set(value);
    }
    for (final MapEntry(key: name, value: image) in _images.entries) {
      _probeSampler(name)?.set(image);
    }
    _probeFloat(ProbeUniforms.mode, 0)?.set(ProbeMode.heatmap.uniformValue);
    _probeFloat(ProbeUniforms.range, 0)?.set(heatmap.min);
    _probeFloat(ProbeUniforms.range, 1)?.set(heatmap.max);
  }

  // A uniform missing from the probe is cached as null, so it is looked up
  // once, not on every frame.
  ui.UniformFloatSlot? _probeFloat(String name, int index) =>
      _probeFloats.putIfAbsent((name, index), () {
        try {
          return _probe!.getUniformFloat(name, index);
        } on ArgumentError {
          return null;
        }
      });

  ui.ImageSamplerSlot? _probeSampler(String name) =>
      _probeSamplers.putIfAbsent(name, () {
        try {
          return _probe!.getImageSampler(name);
        } on ArgumentError {
          return null;
        }
      });

  @override
  String toString() => 'DebugShader($asset)';
}

/// A float uniform of a [DebugShader], like [ui.UniformFloatSlot].
final class DebugUniformFloat {
  DebugUniformFloat._(this._shader, this.name, this.index, this._slot);

  final DebugShader _shader;
  final ui.UniformFloatSlot _slot;

  /// The uniform's name.
  final String name;

  /// The component within the uniform: 1 for `foo.y`.
  final int index;

  /// Sets the value on the shader and records it for the probe.
  void set(double value) {
    _slot.set(value);
    _shader._record(name, index, value);
  }
}

/// A `vec2` uniform of a [DebugShader], like [ui.UniformVec2Slot].
final class DebugUniformVec2 {
  DebugUniformVec2._(this._components);

  final List<DebugUniformFloat> _components;

  void set(double x, double y) {
    _components[0].set(x);
    _components[1].set(y);
  }
}

/// A `vec3` uniform of a [DebugShader], like [ui.UniformVec3Slot].
final class DebugUniformVec3 {
  DebugUniformVec3._(this._components);

  final List<DebugUniformFloat> _components;

  void set(double x, double y, double z) {
    _components[0].set(x);
    _components[1].set(y);
    _components[2].set(z);
  }
}

/// A `vec4` uniform of a [DebugShader], like [ui.UniformVec4Slot].
final class DebugUniformVec4 {
  DebugUniformVec4._(this._components);

  final List<DebugUniformFloat> _components;

  void set(double x, double y, double z, double w) {
    _components[0].set(x);
    _components[1].set(y);
    _components[2].set(z);
    _components[3].set(w);
  }
}

/// A `sampler2D` uniform of a [DebugShader], like [ui.ImageSamplerSlot].
final class DebugImageSampler {
  DebugImageSampler._(this._shader, this.name, this._slot);

  final DebugShader _shader;
  final ui.ImageSamplerSlot _slot;

  /// The uniform's name.
  final String name;

  /// Binds [image] on the shader and records a clone of it for the probe.
  void set(ui.Image image) {
    _slot.set(image);
    _shader._recordImage(name, image);
  }
}
