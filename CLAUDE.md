# CLAUDE.md

Flutter shader debugger: pick a variable in a Flutter fragment shader (`.frag`)
and see it as a live heatmap in the running app, or read its exact value at a
pixel. It ships as a DevTools extension plus a debug-only runtime package. The
architecture, decisions, status and next steps are in docs/architecture.md:

@docs/architecture.md

The maintainer's private notes (motivation, landscape research) are in
docs/design.md, which is git-ignored and may not exist in your checkout:

@docs/design.md

## Layout

This is a pub workspace. Run `flutter pub get` once at the root; every package
resolves against the root `pubspec.lock`.

- `packages/shader_debugger_core/`: pure Dart. `lib/src/model/` is the data
  model (GLSL types, symbol table, per-statement facts). `lib/src/parse/` is
  lexer → preprocessor → parser → resolver, behind `analyzeShader()` in
  `lib/src/analyze.dart`. `lib/src/instrument/` generates probes.
  `lib/protocol.dart` holds the names shared with the runtime (probe uniforms,
  service extensions) and has no dependencies. No `dart:io`, `dart:ui` or
  Flutter imports in `lib/`, because it is compiled into the web extension.
- `packages/shader_debugger/`: the Flutter runtime, debug only. `DebugShader`
  records uniforms and swaps in the probe; `ShaderDebugger` owns the probe
  program and the `ext.shader_debugger.*` service extensions.
  `extension/devtools/` holds `config.yaml` and the compiled extension in
  `build/` (git-ignored, kept for publishing by `.pubignore`).
- `packages/shader_debugger/example/`: demo app and the runtime's tests.
  `shaders/gradient.frag` is the example shader the docs use;
  `shaders/_debug/probe.frag` is the placeholder probe the extension
  overwrites. `test/probes/gradient_capture_d.frag` is the instrumenter's
  golden output, which the runtime tests draw.
- `packages/shader_debugger_devtools/`: the DevTools extension (Flutter web; a
  placeholder until the parser exists).
- `tool/e2e_heatmap.py`: end-to-end check through the real Flutter tool on
  macOS (write probe, hot reload, service extensions).

## Commands

```sh
flutter pub get                       # at the root
flutter analyze                       # at the root: analyzes every package
(cd packages/shader_debugger_core && dart test)   # includes impellerc compile checks
(cd packages/shader_debugger/example && flutter test)   # runtime, real shaders
python3 tool/e2e_heatmap.py [SCREENSHOT_DIR]            # end to end, macOS

# After changing the instrumenter's output, regenerate the golden probe
(cd packages/shader_debugger_core && UPDATE_GOLDENS=1 dart test test/instrument)

# DevTools extension, from packages/shader_debugger_devtools
flutter run -d chrome --dart-define=use_simulated_environment=true
dart run devtools_extensions build_and_copy --source=. --dest=../shader_debugger/extension/devtools
dart run devtools_extensions validate --package=../shader_debugger

# Example app, from packages/shader_debugger/example
flutter run -d macos

# Compile a shader the way the Flutter tool does for macOS, for example to
# check a generated probe. --reflection-json lists the uniforms the app sees.
IMPELLERC="$(dirname "$(which flutter)")/cache/artifacts/engine/darwin-x64/impellerc"
OUT="$(mktemp -d)"
"$IMPELLERC" --sksl --runtime-stage-metal --iplr --sl="$OUT/out.iplr" \
  --spirv="$OUT/out.spirv" --reflection-json="$OUT/out.json" \
  --input=shaders/gradient.frag --input-type=frag \
  --include=shaders --include="$(dirname "$IMPELLERC")/shader_lib"
```

## Conventions

- Spans are `package:source_span` `FileSpan`s into the original file, before
  preprocessing. Lines in the model are 0-based; add 1 for display.
- The symbol class is `GlslSymbol`, not `Symbol`, which clashes with
  `dart:core`. Built-in `GlslType`s are canonical: take them from the
  `GlslType.*` constants, `GlslType.fromKeyword` or the `.of` constructors.
- The parser is not a validator; impellerc is. For a construct it does not
  understand, set `StatementInfo.unsupportedReason` and add a `Diagnostic`.
  Never fail the whole file.
- `test/support/fixtures.dart` in core is the contract for the resolver:
  `contract_test.dart` checks that parsing the same sources reproduces those
  hand-built analyses exactly. Change both together.
- `corpus_test.dart` analyzes real shaders (the example's, and the Flutter
  SDK's own, read from the installed SDK) and compiles a probe at every
  statement. Add shaders there when the analyzer learns a new construct.
- Tokens keep offsets in the original file (a macro's output gets the macro
  use's offsets, included code the `#include`'s); that is the source map.
- Probes are edited copies of the user's source, never re-printed from an AST.
  Every capture variant must compile with impellerc (`compile_test.dart`).
- `DebugShader` offers only the name-based uniform API: the probe adds its own
  uniforms, so values are replayed by name, never by float index. A hot
  reload zeroes uniforms, so replay happens on every read of `shader`.
- Never copy code from glslgen (AGPL-3.0).
- Generated shader identifiers use the `_dbg_` prefix, and debug uniforms go at
  the end of the file.
- The workspace resolves all packages together, so `test` in the core must stay
  compatible with the `test_api` version that Flutter's `flutter_test` pins.
- Out of MVP scope: Flutter web (SkSL), `ImageFilter.shader` and
  `BackdropFilter` shaders.
