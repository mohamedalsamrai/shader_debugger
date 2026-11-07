# shader_debugger

Debug-only runtime for the Flutter shader debugger. Add it to an app to get the
Shader Debugger tab in DevTools.

**Status: M2 in progress.** The runtime side of heatmap mode works; the
DevTools extension's side is next. See
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

## How it works

- `DebugShader` records the uniforms it is given. While a heatmap is shown for
  its asset, `shader` returns the probe instead, with the uniforms replayed on
  it by name.
- `ShaderDebugger` loads the probe, checks its version stamp, and answers the
  DevTools extension through `ext.shader_debugger.getInfo`, `showHeatmap` and
  `hideHeatmap`.

## Layout

- `lib/`: the runtime.
- `extension/devtools/`: `config.yaml` plus the compiled extension in `build/`,
  produced from `packages/shader_debugger_devtools`.
- `example/`: demo app. Its tests exercise the runtime with real shaders.
