/// Names shared by the instrumenter (which writes them into probes), the
/// runtime package (which sets them in the app) and the DevTools extension
/// (which calls the service extensions).
///
/// This library has no dependencies, so the runtime package can import it
/// without pulling in the parser.
library;

/// The version of the app ↔ extension protocol. Bump it when a service
/// extension or a probe uniform changes meaning.
const int protocolVersion = 1;

/// Where the probe shader lives in the app, as an asset key. The app must
/// register it under `flutter: shaders:` in its pubspec.
const String defaultProbeAsset = 'shaders/_debug/probe.frag';

/// The debug uniforms every probe declares, after the user's uniforms.
abstract final class ProbeUniforms {
  /// `float`: the [ProbeMode] value.
  static const String mode = '_dbg_mode';

  /// `vec2`: in pixel mode, the local coordinate every invocation sees.
  static const String coord = '_dbg_coord';

  /// `vec2`: the heatmap's value range, as (min, max).
  static const String range = '_dbg_range';

  /// The name of the version-stamp uniform for [stamp].
  ///
  /// The stamp uniform is declared but never read. impellerc still keeps it in
  /// the reflection data, so `FragmentShader.getUniformFloat` finds it only
  /// when the loaded probe carries that stamp.
  static String stamp(int stamp) => '_dbg_stamp_$stamp';
}

/// What the probe writes to its output.
enum ProbeMode {
  /// The captured value, normalized by the range and colored.
  heatmap(0.0),

  /// The raw captured value, for exact readback.
  pixel(1.0);

  const ProbeMode(this.uniformValue);

  /// The value to set on [ProbeUniforms.mode].
  final double uniformValue;
}

/// The service extensions the runtime package registers in debug mode.
abstract final class ServiceExtensions {
  static const String prefix = 'ext.shader_debugger';

  /// Returns the protocol version, the probe asset, the assets of the live
  /// `DebugShader`s and the current heatmap, if any.
  static const String getInfo = '$prefix.getInfo';

  /// Draws the probe in place of every `DebugShader` for an asset.
  ///
  /// Parameters: `asset`, `stamp`, and optionally `min` and `max` (default 0
  /// and 1). Answers `{"applied": false, "reason": "probeNotLoaded"}` while the
  /// loaded probe does not carry `stamp` yet, for example right after a hot
  /// reload; the caller retries.
  static const String showHeatmap = '$prefix.showHeatmap';

  /// Draws the original shaders again.
  static const String hideHeatmap = '$prefix.hideHeatmap';
}
