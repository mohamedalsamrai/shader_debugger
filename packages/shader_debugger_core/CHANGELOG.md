## 1.0.0

First release.

- `analyzeShader()`: lexer, preprocessor (conditionals, macros with `##`,
  includes), parser and resolver for Flutter's GLSL subset. Never throws:
  problems become diagnostics, and statements it does not understand are not
  pickable.
- Data model: `GlslType` (with the parts a picker can select: matrix columns,
  array elements, struct fields), `SymbolTable` / `Scope` / `GlslSymbol`,
  `StatementInfo` (writes, the parts written, variables in scope) and
  `ShaderAnalysis`.
- `instrument()`: turns a selection into a probe shader for heatmaps and
  exact pixel reads.
- `package:shader_debugger_core/protocol.dart`: the names shared by the
  runtime and the DevTools extension (protocol version 5).
