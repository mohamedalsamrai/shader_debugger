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
| `instrument()`, `CaptureRequest`, `Probe` | Probe generation (design doc §4). |

The instrumenter (`instrument()`) turns an analysis and a picked variable
into a probe shader. `lib/protocol.dart` holds the names it shares with the
runtime package.

Next: the preprocessor, the parser, and a resolver that fills the model.
`test/support/fixtures.dart` builds by hand the analyses the resolver must
produce.

```sh
dart test
dart analyze --fatal-infos
```
