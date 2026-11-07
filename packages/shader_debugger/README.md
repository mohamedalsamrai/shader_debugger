# shader_debugger

Debug-only runtime for the Flutter shader debugger. Add it to an app to get the
Shader Debugger tab in DevTools.

**Status: heatmap (M2), pixel inspector (M3) and uniform overrides (M4)
built.** See
[docs/architecture.md](../../docs/architecture.md).

## Use

Wrap shaders in `DebugShader`, set uniforms by name, and read `shader` in every
paint:

```dart
final shader = await DebugShader.fromAsset('shaders/gradient.frag');
final size = shader.getUniformVec2('uSize');

// In paint():
size.set(width, height);
canvas.drawRect(rect, Paint()..shader = shader.shader);
```

Register the probe once in the app's `pubspec.yaml` (the extension overwrites
it):

```yaml
flutter:
  shaders:
    - shaders/_debug/probe.frag
```

In profile and release mode `DebugShader` records nothing, and `shader` is
always the original.

To pick a pixel by clicking it in the app, draw the shader without
transforming the canvas first: the click is mapped into the painting render
box's coordinates. Otherwise, type the coordinates in DevTools.

Select mode needs nothing else from the app: its overlay goes into the app's
root `Overlay`, which `MaterialApp`, `CupertinoApp` and `WidgetsApp` provide.

## How it works

- `DebugShader` records the uniforms it is given. While a heatmap is shown for
  its asset, `shader` returns the probe instead, with the uniforms replayed on
  it by name.
- `ShaderDebugger` loads the probe, checks its version stamp, and answers the
  DevTools extension through `ext.shader_debugger.getInfo`, `showHeatmap`,
  `hideHeatmap`, `readPixel`, `setPixelSelectMode`, `pickPixel`,
  `getUniforms`, `setUniformOverride` and `clearUniformOverrides`.
- Uniform overrides replace the app's values on every paint, on the shader
  and on the probe, until DevTools drops them; the app's own values then
  apply again.
- Pixel select mode works like the widget inspector's select mode: an
  overlay takes the app's clicks, highlights the pixel under the pointer,
  and reports each click to DevTools, until it is turned off there or with
  its Done button.
- `readPixel` draws the probe offscreen into one 32-bit float pixel, with the
  app's uniforms and `FlutterFragCoord()` pinned to the point, and reads the
  value back exactly (on Impeller).

## Layout

- `lib/`: the runtime.
- `extension/devtools/`: `config.yaml` plus the compiled extension in `build/`,
  produced from `packages/shader_debugger_devtools`.
- `example/`: demo app. Its tests exercise the runtime with real shaders.
