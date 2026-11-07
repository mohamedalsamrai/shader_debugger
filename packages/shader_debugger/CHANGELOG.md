## 1.0.1

- Fix: the Shader Debugger tab's side panel failed to build inside DevTools,
  whose theme aligns tab bars to the start, which only scrollable tab bars
  allow. The extension's tests now run under DevTools' own theme.
- The example's probe is the placeholder again, not a generated probe.
- New README with recorded GIFs and screenshots, a quick start and platform
  notes. The example app is a gallery of four shaders, each with a hint on
  what to try.

## 1.0.0

First release. Verified end to end on macOS with Impeller; other platforms
are untested so far.

- `DebugShader`: wraps a fragment shader, records its uniforms by name, and
  draws the probe while a heatmap is shown. Inert in profile and release.
- `ShaderDebugger`: the `ext.shader_debugger.*` service extensions for the
  DevTools extension:
  - heatmaps of any value at any statement;
  - exact pixel reads (32-bit floats on Impeller), with pixel select mode, an
    overlay in the app modeled on the widget inspector's select mode;
  - uniform overrides, applied to the shader and the probe until cleared.
- The Shader Debugger DevTools extension, built into `extension/devtools/`.
