# shader_debugger

Debug-only runtime for the Flutter shader debugger. Add it to an app to get the
Shader Debugger tab in DevTools.

**Status: scaffold.** The runtime API (`DebugShader` and the
`ext.shader_debugger.*` service extensions) arrives in milestone M2. See the
[design doc](../../docs/design.md).

## What it will do

- `DebugShader` wraps a `FragmentShader`, records its uniforms by name and
  replays them on the probe shader.
- Heatmap mode draws the probe where the original shader was drawn.
- Pixel mode renders the probe offscreen and reads back exact float values.

## Layout

- `lib/`: the runtime, debug mode only.
- `extension/devtools/`: `config.yaml` plus the compiled extension in `build/`,
  produced from `packages/shader_debugger_devtools`.
- `example/`: demo app.
