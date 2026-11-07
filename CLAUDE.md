# CLAUDE.md

Flutter shader debugger: pick a variable in a Flutter fragment shader (`.frag`)
and see it as a live heatmap in the running app, or read its exact value at a
pixel. It ships as a DevTools extension plus a debug-only runtime package. The
design, research, decisions and status are in docs/design.md:

@docs/design.md

## Layout

This is a pub workspace. Run `flutter pub get` once at the root; every package
resolves against the root `pubspec.lock`.

- `packages/shader_debugger_core/`: pure Dart. The M1 data model is in
  `lib/src/model/` (GLSL types, symbol table, per-statement facts). The
  preprocessor, parser, resolver and instrumenter go next to it. No `dart:io`,
  `dart:ui` or Flutter imports in `lib/`, because it is compiled into the web
  extension.
- `packages/shader_debugger/`: the Flutter runtime (debug only; a scaffold
  until M2). `extension/devtools/` holds `config.yaml` and the compiled
  extension in `build/` (git-ignored, kept for publishing by `.pubignore`).
- `packages/shader_debugger/example/`: demo app. `shaders/gradient.frag` is the
  design doc's example shader. `shaders/_debug/probe.frag` is the placeholder
  probe that the extension overwrites.
- `packages/shader_debugger_devtools/`: the DevTools extension (Flutter web; a
  placeholder until M2).

## Commands

```sh
flutter pub get                       # at the root
flutter analyze                       # at the root: analyzes every package
(cd packages/shader_debugger_core && dart test)

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
- `test/model/shader_analysis_test.dart` is the contract for the resolver.
  Once the parser exists, the same assertions should hold for the analysis
  parsed from the same source.
- Never copy code from glslgen (AGPL-3.0).
- Generated shader identifiers use the `_dbg_` prefix, and debug uniforms go at
  the end of the file.
- The workspace resolves all packages together, so `test` in the core must stay
  compatible with the `test_api` version that Flutter's `flutter_test` pins.
- Out of MVP scope: Flutter web (SkSL), `ImageFilter.shader` and
  `BackdropFilter` shaders.
