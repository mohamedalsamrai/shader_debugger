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
