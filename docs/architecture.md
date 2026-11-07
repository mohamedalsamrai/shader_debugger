# Architecture

How the Flutter shader debugger works, what is built, and what comes next.
Read this before changing the analyzer, the instrumenter or the runtime.

The debugger lets you pick a variable in a fragment shader (`.frag`) and see it
as a live heatmap where the shader is drawn in the running app (M2). Next comes
clicking a pixel to read the variable's exact value there (M3), then
auto-generated sliders for uniforms (M4).

## Overview

```
DevTools extension (packages/shader_debugger_devtools, Flutter web)
  [Variable picker] -> [Instrumenter] -> [Results panel]
        |                    |                  ^
        | DTD file system    | hot reload       | VM service
        v (read/write)       v (Flutter tool)   | (ext.shader_debugger.*)
  shaders/_debug/probe.frag -> impellerc -> probe reinitialized in the app
Running app (debug mode, package:shader_debugger)
  [DebugShader: records uniforms] -> [ShaderDebugger: probe, stamp check,
                                      service extensions]
```

**Host side: the DevTools extension**
- **Variable picker:** reads the `.frag` through DTD, runs `analyzeShader()`,
  and lists the variables written and in scope at each statement.
- **Instrumenter:** `instrument()` in `shader_debugger_core` generates the
  probe shader.
- **Results panel:** heatmap controls (range, colormap), and pixel values in
  M3.

**In between: tooling**
- **DTD file system:** `readFileAsString` / `writeFileAsString`. Writes are
  allowed inside the IDE's workspace roots.
- **Flutter tool:** `ServiceManager.performHotReload()` calls the hot-reload
  service the tool registers. A hot reload recompiles changed shaders (see
  "Shader hot reload" below).

**App side: the runtime, debug mode only**
- **`DebugShader`** wraps a `FragmentShader`. It records uniforms by name, and
  images as clones it keeps alive. While a heatmap is shown for its asset, its
  `shader` getter returns the probe, with the recorded uniforms replayed on it.
- **`ShaderDebugger`** loads the probe program, checks the probe's version
  stamp, and answers the extension through service extensions:
  `ext.shader_debugger.getInfo`, `showHeatmap` and `hideHeatmap`. Pixel
  readback joins them in M3.

## How a heatmap gets on screen

1. The extension reads the `.frag` through DTD and analyzes it. The user
   picks a variable at a statement.
2. `instrument()` generates the probe, tagged with a new version stamp.
3. The extension writes `shaders/_debug/probe.frag` and triggers a hot
   reload. The Flutter tool recompiles the probe. The app must register that
   file once under `flutter: shaders:` in its `pubspec.yaml`.
4. The extension calls `showHeatmap(asset, stamp, min, max)`. It retries
   while the app answers `probeNotLoaded`, since the reload may still be
   landing.
5. Every `DebugShader` for that asset now draws the probe, with the app's
   uniforms replayed on it by name.
6. (M3) Pixel mode: the probe pins `FlutterFragCoord` to the chosen pixel.
   The app renders offscreen with
   `Picture.toImageSync(w, h, targetFormat: TargetPixelFormat.rgbaFloat32)`
   and reads back exact 32-bit floats.

## Probes

A probe is the user's shader, edited as text so it stays readable. The rules:

- Rename the user's `main` to `_dbg_main`. A new `main` calls it, then writes
  the encoded captured value to the output. Early `return`s keep working.
- At the picked statement, copy the value into the global `vec4 _dbg_value`,
  widened by type (see the table below).
  - **Declarations:** the copy is appended right after the statement.
  - **Other statements:** they are wrapped in braces with the copy, so it
    stays in the same branch when the statement is the un-braced body of an
    `if` or a loop.
  - **`return`, `discard`, `break` and `continue`:** the copy goes before the
    statement.
- Replace `FlutterFragCoord()` in user code with `_dbg_fragCoord()`, which
  returns `_dbg_coord` in pixel mode.
- Append the debug uniforms at the end of the file, so the user's uniforms
  keep their positions: `_dbg_mode`, `_dbg_coord`, `_dbg_range` and a version
  stamp `_dbg_stamp_<n>`.

Capturing `d` in the example shader:

```glsl
void _dbg_main() {
  vec2 uv = _dbg_fragCoord().xy / uSize;
  float d = length(uv - 0.5); _dbg_value = vec4(d, 0.0, 0.0, 1.0);
  vec3 col = mix(uA.rgb, uB.rgb, d);
  fragColor = vec4(col, 1.0);
}

// ---- Shader Debugger probe (generated) ----
uniform float _dbg_mode;
uniform vec2 _dbg_coord;
uniform vec2 _dbg_range;
uniform float _dbg_stamp_1;
// ... _dbg_fragCoord(), _dbg_colormap(), _dbg_encode() ...

void main() {
  _dbg_main();
  fragColor = _dbg_encode(_dbg_value);
}
```

The full generated file is
`packages/shader_debugger/example/test/probes/gradient_capture_d.frag`. The
runtime tests draw it.

In heatmap mode, scalars go through a viridis colormap scaled by
`_dbg_range`. Vectors are drawn as RG or RGB, and RGBA as RGB, because alpha
would blend with whatever is behind.

## The analyzer

`analyzeShader()` in `shader_debugger_core` is pure Dart, with no `dart:io`,
so it runs in the web extension and in a CLI. It never throws on bad input:
problems become diagnostics.

1. **Lex and preprocess** (`lib/src/parse/lexer.dart`, `preprocessor.dart`)
   - `#if` / `#ifdef` / `#elif`, macros with and without arguments (including
     `##`), and `#include`. `IMPELLER_GRAPHICS_BACKEND` is predefined.
   - `<flutter/runtime_effect.glsl>` becomes a stub declaring
     `vec2 FlutterFragCoord();`. Other includes are read through a callback,
     since the core reads no files.
   - The source map: every token keeps its offset in the original file. A
     macro's output takes the offsets of the macro use, and included code
     takes those of the `#include` line.
2. **Parse** (`parser.dart`, `ast.dart`)
   - Recursive descent for declarations and statements, precedence climbing
     for expressions. Every node knows its first and last token.
   - On a syntax error it reports, skips the statement and goes on.
3. **Resolve** into the data model (`resolver.dart`, `lib/src/model/`)
   - Scopes go global → function → block. A `for` header's scope is shared
     with the loop body.
   - Every declaration becomes a `GlslSymbol` (the name `Symbol` clashes with
     `dart:core`), with GLSL's visibility rules. A variable is visible only
     after its declarator, so in `float x = x + 1.0;` the right-hand `x` is
     still the outer one.
   - Per statement (`StatementInfo`), it records:
     - **Writes:** variables declared with an initializer, assignment targets
       (through fields and indices), `++`/`--`, and arguments passed to `out`
       or `inout` parameters, including built-ins such as `modf`.
     - **In scope:** the variables visible where the value is captured.
     - **Default pick:** the first variable the statement writes.
   - A statement that starts or ends inside a macro expansion is not
     pickable, and statements from included files are not listed.

```glsl
vec2 uv = FlutterFragCoord().xy / uSize; // writes: uv
float d = length(uv - 0.5);              // writes: d · also in scope: uv
vec3 col = mix(uA.rgb, uB.rgb, d);       // writes: col · also in scope: uv, d
```

### Type → visualization

| Type | Shown as |
|---|---|
| `float` | grayscale or colormap |
| `vec2` | RG |
| `vec3` | RGB |
| `vec4` | RGBA (drawn as RGB in heatmap mode) |
| `int`, `uint`, `bool` | cast to float |
| matrix | pick a column |
| array | pick an element |
| struct | pick a field |

### Decisions

- **Don't copy glslgen's parser.** It is AGPL-3.0, and copying from it would
  make this project AGPL. The parser here is written for Flutter's GLSL subset.
- **The parser is not a validator.** impellerc is the judge. When the analyzer
  meets a construct it does not understand, it disables picking on that
  statement instead of failing the whole file.
- **Tests pin the behavior:**
  - **Contract:** `test/support/fixtures.dart` holds hand-built analyses, and
    `contract_test.dart` checks that parsing the same sources reproduces them.
  - **Corpus:** `corpus_test.dart` analyzes real shaders, including the
    Flutter SDK's own, and compiles a probe at every statement with impellerc.
- **Later:** `glslangValidator -i` as a type oracle on a corpus. Expression type
  inference (hovering `length(uv)`) is post-MVP: it needs a built-ins overload
  table plus swizzle and operator rules.

## Shader hot reload

Checked against the Flutter 3.47.8 sources and confirmed end to end on macOS
with Impeller (`tool/e2e_heatmap.py`).

**The Flutter tool** (`flutter_tools`: `devfs.dart`, `resident_runner.dart`,
`build_system/tools/shader_compiler.dart`)
- On hot reload, the tool recompiles a registered `.frag` if the file changed
  or one of its `#include`s did. It syncs the result to the device and calls
  `ext.ui.window.reinitializeShader` with the asset key. A reload with a new
  probe takes about 0.2 s, and the new stamp is visible as soon as the reload
  returns.
- Only files listed under `flutter: shaders:` are compiled. That is why the
  probe has to be registered up front.
- If impellerc fails, the whole hot reload fails ("DevFS synchronization
  failed") before any Dart code reloads, and the device keeps the old probe.

**The engine** (`dart:ui`, debug mode only)
- `FragmentProgram.fromAsset` caches one program per asset key.
  `reinitializeShader` re-reads the asset into that same object, so the probe
  is loaded once and its code is swapped in place.
- Every live `FragmentShader` from that program gets a new, zero-filled
  uniform buffer. That is why `DebugShader` replays uniforms on every paint.
- Named slots are re-pointed at the new layout by name. A slot whose uniform
  disappeared keeps its old index, so `DebugShader` replays by name, never by
  float index.
- **Version stamp:** `getUniformFloat(name)` throws `ArgumentError` for an
  unknown name. impellerc keeps a declared uniform in the reflection data
  even when nothing reads it. So the app can check for `_dbg_stamp_<n>` to
  know which probe is loaded.

## Known limitations

- **DTD workspace roots:** file writes through DTD are allowed only inside
  the IDE's workspace roots. Launching from VS Code or Android Studio works
  best. A small CLI is the fallback.
- **Derivatives in pixel mode:** every invocation computes the same
  coordinate, so `dFdx`, `dFdy` and `fwidth` are 0.
- **Loops and repeated calls:** a value inside a loop, or in a function called
  more than once, shows its last write. Iteration and call selectors come
  later.
- **Pixel readback:** draw the probe with `BlendMode.src`, so blending and
  premultiplied alpha do not alter the raw values.
- **Backend-specific code:** the analyzer assumes `IMPELLER_GRAPHICS_BACKEND`.
  Code in `#ifdef` branches for other backends is not listed.
- **`main` with a separate prototype:** the instrumenter renames only the
  first declaration.
- **Out of scope for the MVP:** `ImageFilter.shader` and `BackdropFilter`
  shaders (the engine sets `u_size` and `u_texture` itself), and Flutter web
  (SkSL).

## Status

| Milestone | Scope | Status |
|---|---|---|
| M1 | Core: analyzer, symbols, instrumenter, with tests. No Flutter needed. | Done |
| M2 | Heatmap mode end to end | Runtime done and verified end to end. The extension side is next. |
| M3 | Pixel inspector | Not started |
| M4 | Auto sliders for uniforms (the analyzer already knows their names and types) | Not started |

**Next, M2's extension side:**
1. Read the `.frag` through DTD.
2. Build the variable picker on `analyzeShader()`.
3. Write the probe and call `performHotReload`.
4. Call `showHeatmap`, with retries.
5. Add range controls.

## Open questions

- What is the fallback when DTD has no workspace roots?

## References

**Flutter and Dart APIs**
- Flutter fragment shaders: https://docs.flutter.dev/ui/advanced/shaders
- DTD `DartToolingDaemon`: https://pub.dev/documentation/dtd/latest/dtd/DartToolingDaemon-class.html
- DTD file system example: https://dart.googlesource.com/sdk/+/stable/pkg/dtd/example/dtd_file_system_service_example.dart
- `ServiceManager.performHotReload`: https://pub.dev/documentation/devtools_app_shared/latest/service/ServiceManager/performHotReload.html
- `callServiceExtensionOnMainIsolate`: https://pub.dev/documentation/devtools_app_shared/latest/service/ServiceManager/callServiceExtensionOnMainIsolate.html
- `Picture.toImageSync`: https://api.flutter.dev/flutter/dart-ui/Picture/toImageSync.html
- `TargetPixelFormat`: https://api.flutter.dev/flutter/dart-ui/TargetPixelFormat.html
- Impeller, reading GPU frame captures: https://flutter.googlesource.com/mirrors/engine/+/a9783b2ba4032763f09a2072a15e746a119d6f49/impeller/docs/read_frame_captures.md

**Shader debugging prior art**
- Shader Studio debugging: https://teaqu.github.io/shader-studio/debugging/
- webgl-shader-editor: https://github.com/gkjohnson/webgl-shader-editor
- Xcode shader debugger: https://developer.apple.com/documentation/xcode/debugging-the-shaders-within-a-draw-command-or-compute-dispatch
