# shader_debugger_core

Pure-Dart core of the Flutter shader debugger. It has no `dart:io` or Flutter
dependency, so it runs both in the DevTools extension (Flutter web) and in a
command-line tool.

**Status: M1 done.** `analyzeShader()` turns a `.frag` file into a
`ShaderAnalysis`, and `instrument()` turns a picked variable into a probe.

| Type | What it is |
|---|---|
| `analyzeShader()` | Preprocess, parse and resolve a shader (design doc §5). Never throws; problems become diagnostics. |
| `GlslType` | The GLSL types Flutter shaders use, and how the probe shows each one (design doc §5, "Type → visualization"). |
| `SymbolTable`, `Scope`, `GlslSymbol` | Scopes (global → function → block) and declarations, with GLSL's visibility rules. |
| `StatementInfo` | What a statement writes, and what is in scope where its value is captured. |
| `ShaderAnalysis` | Everything the variable picker needs from one `.frag` file. |
| `instrument()`, `CaptureRequest`, `Probe` | Probe generation (design doc §4). |

The instrumenter (`instrument()`) turns an analysis and a picked variable
into a probe shader. `lib/protocol.dart` holds the names it shares with the
runtime package.

The tests include a contract (parsing reproduces the hand-built analyses in
`test/support/fixtures.dart`) and a corpus of real shaders, the Flutter SDK's
own among them, with a compiled probe at every statement.

```sh
dart test
dart analyze --fatal-infos
```
