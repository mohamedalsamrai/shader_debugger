/// Names shared by the instrumenter (which writes them into probes), the
/// runtime package (which sets them in the app) and the DevTools extension
/// (which calls the service extensions).
///
/// This library has no dependencies, so the runtime package can import it
/// without pulling in the parser.
library;

/// The version of the app ↔ extension protocol. Bump it when a service
/// extension or a probe uniform changes meaning.
const int protocolVersion = 3;

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
///
/// Both pixel modes pin `FlutterFragCoord()` to [ProbeUniforms.coord] and
/// write an alpha of 1, so that alpha never scales the color: reading a
/// `vec4` takes one pass for x, y and z and one for w.
enum ProbeMode {
  /// The captured value, normalized by the range and colored.
  heatmap(0.0),

  /// The raw x, y and z of the captured value, with an alpha of 1.
  pixel(1.0),

  /// The raw w of the captured value, in the red channel.
  pixelW(2.0);

  const ProbeMode(this.uniformValue);

  /// The value to set on [ProbeUniforms.mode].
  final double uniformValue;
}

/// The service extensions the runtime package registers in debug mode.
abstract final class ServiceExtensions {
  static const String prefix = 'ext.shader_debugger';

  /// Returns the protocol version, the probe asset, the assets of the live
  /// `DebugShader`s, the current heatmap, if any, and the asset in pixel
  /// select mode (`pixelSelectMode`), if any.
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

  /// Reads the captured value at one point, as exact 32-bit floats.
  ///
  /// Parameters: `asset`, `stamp`, and `x` and `y` in the shader's
  /// coordinates (what `FlutterFragCoord()` returns there). Optionally
  /// `instance`, from a [ServiceEvents.pixelPicked] event, picks which
  /// `DebugShader` for the asset supplies the uniforms; by default, the first
  /// one. Answers `{"applied": true, "value": [x, y, z, w]}`, or `applied`
  /// false with a `reason`, as [showHeatmap] does. Components that are not
  /// finite come as the strings `NaN`, `Infinity` and `-Infinity`.
  static const String readPixel = '$prefix.readPixel';

  /// Turns pixel select mode on or off, like the widget inspector's select
  /// mode.
  ///
  /// Parameters: `enabled` (`true` or `false`), and `asset` when enabling.
  /// While on, an overlay covers the app and takes its clicks and taps:
  /// hovering a `DebugShader` for the asset highlights the pixel under the
  /// pointer, and each click posts a [ServiceEvents.pixelPicked] event. It
  /// stays on until turned off, here or with the overlay's Done button,
  /// which posts [ServiceEvents.pixelSelectMode].
  ///
  /// Answers `{"enabled": bool, "overlay": bool}`. `overlay` is false when
  /// the app has no `Overlay` to show it in (no `WidgetsApp` or `Navigator`);
  /// clicks are then still reported, but also reach the app.
  static const String setPixelSelectMode = '$prefix.setPixelSelectMode';

  /// Picks the pixel at a global logical position right away, as a click in
  /// select mode would, and answers with the [ServiceEvents.pixelPicked]
  /// event's data instead of posting it. For tools and tests.
  ///
  /// Parameters: `asset`, `x` and `y`.
  static const String pickPixel = '$prefix.pickPixel';
}

/// The events the runtime package posts on the VM service's Extension
/// stream.
abstract final class ServiceEvents {
  /// A pixel was clicked in select mode
  /// ([ServiceExtensions.setPixelSelectMode]).
  ///
  /// Data: `asset`, and either `instance`, `x` and `y` (the shader
  /// coordinates of the device pixel tapped, at its center) with `width` and
  /// `height` (the size of the box the shader was painted in), or a
  /// `reason`: `notOnShader` when the tap missed every `DebugShader` for the
  /// asset.
  static const String pixelPicked = 'shader_debugger.pixelPicked';

  /// Select mode was turned off from the app, with the overlay's Done
  /// button. Data: `enabled` (false).
  static const String pixelSelectMode = 'shader_debugger.pixelSelectMode';
}
