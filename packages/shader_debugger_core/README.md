# shader_debugger_core

Pure-Dart core of the Flutter shader debugger. It has no `dart:io` or Flutter
dependency, so it runs both in the DevTools extension (Flutter web) and in a
command-line tool.

**Status: M1 in progress.** The data model is in place:

| Type | What it is |
|---|---|
| `GlslType` | The GLSL types Flutter shaders use, and how the probe shows each one (design doc §5, "Type → visualization"). |
| `SymbolTable`, `Scope`, `GlslSymbol` | Scopes (global → function → block) and declarations, with GLSL's visibility rules. |
| `StatementInfo` | What a statement writes, and what is in scope where its value is captured. |
| `ShaderAnalysis` | Everything the variable picker needs from one `.frag` file. |

Next: the preprocessor, the parser, a resolver that fills the model, and the
instrumenter. `test/model/shader_analysis_test.dart` builds by hand the
analysis the resolver must produce for the design doc's example shader.

```sh
dart test
dart analyze --fatal-infos
```
