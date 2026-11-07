/// Debug-only runtime for the Flutter shader debugger.
///
/// Status: scaffold. Milestone M2 adds `DebugShader`, a thin wrapper around
/// `FragmentShader` that records uniforms by name and replays them on the
/// probe shader, plus the `ext.shader_debugger.*` service extensions that the
/// DevTools extension calls. See docs/design.md §3 in the repository.
///
/// Depending on this package is also what makes DevTools offer the Shader
/// Debugger extension: the built extension ships in `extension/devtools/`.
library;
