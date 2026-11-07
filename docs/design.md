# Flutter Shader Debugger — Project Context

> Exported from a Claude chat (Nov 5–7, 2026). It summarizes the decisions, research and design so far.
> `CLAUDE.md` at the repo root imports this file, so coding agents load it automatically.

---

## 1. Goal and decision

**Goal:** start an open-source **graphics** project that is genuinely useful to developers and **not a duplicate** of existing work.

**Chosen project:** an in-app **shader debugger for Flutter fragment shaders**, shipped as a **DevTools extension** plus a **debug-only runtime package**.

- Pick a variable in a `.frag` → see it as a **live heatmap** where the shader is drawn in the running app.
- Click a pixel → see the **exact values** of that variable at that pixel.
- Later: auto-generated **sliders for uniforms**.

**Why this one**
- Every shader author needs it, and no Flutter equivalent was found.
- Prior art exists outside Flutter: Xcode's Metal shader debugger, RenderDoc, Shader Studio (rewrites the shader to render a chosen variable as color), webgl-shader-editor (per-pixel local variable values).
- Builds on Flutter's name-based uniform API (`getUniformFloat` / `UniformFloatSlot`).
- Strong portfolio piece (e.g. for GSoC).

---

## 2. Landscape research (Nov 2026)

### Other candidates (backlog)

| Idea | Gap found |
|---|---|
| 2D lighting for Flame (point/spot lights, normal maps, forge2d shadows) | Flame's official bridge packages have no lighting; lighting exists only in `flame_3d` (3D). LibGDX has an equivalent 2D engine. |
| Frame inspector for Flutter GPU ("Spector.js for Flutter GPU") | Flutter GPU is on stable since 3.44 (opt-in per platform), but frame debugging still relies on Xcode / RenderDoc / Android GPU Inspector. |
| Charts for millions of points on Flutter GPU | Closest: `flutter_native_charts` (native GPU inside a PlatformView, financial charts, Android/iOS only). Web analog: ChartGPU. |

### Already exists — excluded

- Gaussian splatting → `flutter_gaussian_splatter`; also built into `flutter_scene`
- Runtime glTF / KTX2 import → `flutter_scene`
- Type-safe uniform codegen → `glslgen` (AGPL-3.0), `flar/shader_prototypes` (proof of concept)
- Perceptual golden-test diffs → `golden_lens`
- Color-vision-deficiency simulation → `cvd_simulator`, `wcag_vision`
- Decoded-vs-displayed image audits → `buoy_images`

---

## 3. MVP architecture

```
DevTools extension (Flutter web, package:devtools_extensions)
  [Variable picker] -> [Instrumenter] -> [Results panel]
        |                    |                  ^
        | DTD FileSystem     | hot reload       | VM service
        v (read/write)       v (Flutter tool)   | (ext.shader_debugger.*)
  shaders/_debug/probe.frag -> impellerc recompile |
                               -> shader reinitialized in the app
Running app (debug mode, package:shader_debugger)
  [DebugShader: records uniforms] -> [Probe renderer] -> [Service extensions]
```

### Host side — DevTools extension

- **Variable picker:** reads the `.frag` through DTD and lists variables per statement (see §5).
- **Instrumenter:** `shader_debugger_core` (pure Dart) generates the probe shader.
- **Results panel:** heatmap controls (range, colormap) and pixel values.

### In between — tooling

- **DTD FileSystem service:** `readFileAsString` / `writeFileAsString`. Write permission comes from the IDE workspace roots (see §7).
- **Flutter tool:** for Flutter apps, `ServiceManager.performHotReload()` calls the hot-reload service the Flutter tool registers. So the tool runs a full hot reload, and debug-mode shaders are recompiled on hot reload.

### App side — runtime (debug only)

- **`DebugShader`:** a thin wrapper around `FragmentShader`. It records float uniforms by name (`getUniformFloat` / `UniformFloatSlot`) and sampler images (keep `image.clone()` handles alive).
- **Probe renderer:** replays the recorded uniforms on the probe program.
  - Heatmap mode: paints the probe in place of the original shader, live.
  - Pixel mode: renders offscreen and reads values back.
- **Service extensions:** `ext.shader_debugger.*` (list shaders, set mode, inspect pixel). The extension calls them with `callServiceExtensionOnMainIsolate`.

---

## 4. Flow

1. The user picks a variable. The extension reads the `.frag` through DTD.
2. The Instrumenter generates the probe shader.
3. The extension writes `shaders/_debug/probe.frag` and triggers hot reload, and the Flutter tool recompiles the probe. The probe file must be registered once under `flutter: shaders:` in `pubspec.yaml`.
4. The extension sends the mode through a service extension. `DebugShader` replays the uniforms by name on the probe, giving a live heatmap where the original shader was drawn.
5. Pixel mode: the probe pins `FlutterFragCoord` to the chosen pixel. The app renders offscreen with `Picture.toImageSync(w, h, targetFormat: TargetPixelFormat.rgbaFloat32)` and reads back exact 32-bit floats.

### Instrumentation rules

- Rename the user's `main` to `_dbg_main`. Add a new `main` that calls it, then writes the encoded captured value to `fragColor`. Early `return`s in the original keep working.
- After the selected statement, copy the variable into a global `vec4 _dbg_value`, widened by type.
- Replace calls to `FlutterFragCoord()` in user code with `_dbg_fragCoord()`. In pixel mode it returns `_dbg_coord`.
- Append all debug uniforms **at the end of the file**, so the user's uniform indices don't change.
- Embed a version stamp, so the app can confirm the reload actually landed.

Example — capturing `d`:

```glsl
// original
void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float d = length(uv - 0.5);
  vec3 col = mix(uA.rgb, uB.rgb, d);
  fragColor = vec4(col, 1.0);
}
```

```glsl
// generated probe (sketch; user uniforms stay declared above, unchanged)
vec2 _dbg_fragCoord();                    // forward declaration
vec4 _dbg_value;

void _dbg_main() {
  vec2 uv = _dbg_fragCoord().xy / uSize;
  float d = length(uv - 0.5);
  _dbg_value = vec4(d, 0.0, 0.0, 1.0);    // injected after the selected statement
  vec3 col = mix(uA.rgb, uB.rgb, d);
  fragColor = vec4(col, 1.0);
}

uniform float _dbg_mode;                  // 0 = heatmap, 1 = pixel (appended last)
uniform vec2 _dbg_coord;                  // pixel mode: target local coordinate
uniform vec2 _dbg_range;                  // heatmap normalization (min, max)

vec2 _dbg_fragCoord() {
  return _dbg_mode > 0.5 ? _dbg_coord : FlutterFragCoord();
}

void main() {
  _dbg_main();
  fragColor = _dbg_encode(_dbg_value);    // colormap (heatmap) or raw value (pixel)
}
```

---

## 5. Variable picker — how it knows variables and their types

GLSL declarations always state their type explicitly (`vec3 col = ...`), so variable types come straight from the AST.

### Pipeline in `shader_debugger_core`

The core is pure Dart with no `dart:io`, so it runs in the extension (web) and in a CLI.

1. **Preprocess**
   - Expand `#define`.
   - Resolve `#include <flutter/runtime_effect.glsl>` with a stub that copies the real engine file's declarations.
   - Keep a source map back to the original lines.
2. **Parse**
   - Tokenizer, recursive descent for statements, and a Pratt parser for expressions.
   - Every AST node carries a span.
3. **Symbol table**
   - Scopes go global, then function, then block.
   - Each declaration becomes `Symbol(id, name, type, scope)`. (In code: `GlslSymbol`, because `Symbol` clashes with `dart:core`.)
   - Handles shadowing, `in`/`out`/`inout` params, uniforms, arrays and structs.
4. **Per statement**
   - Compute which symbols are written: declaration, `=`, `+=`, or an `out` param.
   - Compute which symbols are in scope.
   - The picker shows these for the cursor line. The default is the variable written on that line.

```glsl
vec2 uv = FlutterFragCoord().xy / uSize; // writes: uv (vec2)
float d = length(uv - 0.5);              // writes: d · scope: uv
vec3 col = mix(uA, uB, d);               // writes: col · scope: uv, d
```

### Type → visualization

| Type | Shown as |
|---|---|
| `float` | grayscale or colormap |
| `vec2` | RG |
| `vec3` | RGB |
| `vec4` | RGBA |
| `int`, `bool` | cast to float |
| matrix | pick a column |
| array | pick an index |
| struct | pick a field |

### Decisions

- **Don't copy glslgen's parser.** It's AGPL-3.0, and copying from it would force this project to be AGPL. Write a small parser for Flutter's GLSL subset instead.
- **The parser is not a validator.** impellerc is the judge. If a construct isn't understood, disable picking on that line instead of failing the whole tool.
- **Use `glslangValidator -i` as a test oracle.** It prints the AST with types, so compare your inferred types against it on a corpus of real shaders.
- **After the MVP:** hovering an expression such as `length(uv)` needs expression type inference. That means a built-ins overload table (genType) plus swizzle and operator rules (`mat * vec`, `vec * float`).

---

## 6. Milestones

- **M1:** `shader_debugger_core` — parser, symbols and instrumenter, with unit tests. No Flutter needed.
- **M2:** heatmap mode end-to-end.
- **M3:** pixel inspector.
- **M4:** auto sliders for uniforms. The parser already knows their names and types.

---

## 7. Known gotchas and limitations

- **DTD workspace roots:** DTD file writes are permitted within the IDE workspace roots. It works best when launched from VS Code or Android Studio. Keep a small CLI as a fallback.
- **Derivatives in pixel mode:** every invocation computes the same coordinate, so `dFdx`, `dFdy` and `fwidth` become 0. Document this as a limitation.
- **Probe compile failures:** if the probe fails to compile, the old probe stays loaded. Check the version stamp before showing results.
- **Loops and repeated calls:** for variables inside loops, or in functions called several times, capture the last value first. Add iteration and call selectors later.
- **Pixel readback:** draw the probe with `BlendMode.src`, so blending and premultiplied alpha don't alter the raw values.
- **Out of MVP scope:**
  - `ImageFilter.shader` / `BackdropFilter` shaders (the engine sets `u_size` and `u_texture` automatically)
  - Flutter web (SkSL)

---

## 8. Open questions

- What is the fallback when DTD has no workspace roots?
- ~~How does shader hot reload work inside the Flutter tool and the engine?~~ Answered below.

### Answered: how shader hot reload works

Checked on Nov 7, 2026 against the Flutter 3.47.8 sources.

**Flutter tool** (`flutter_tools`: `devfs.dart`, `resident_runner.dart`, `build_system/tools/shader_compiler.dart`)
- On hot reload, the tool recompiles a registered `.frag` with impellerc if the file changed or one of its `#include`s did (tracked through impellerc depfiles). It syncs the result to the device and calls `ext.ui.window.reinitializeShader` with the asset key.
- Only files listed under `flutter: shaders:` are compiled. That is why the probe has to be registered up front.
- If impellerc fails, the DevFS sync throws `DevFSShaderCompilationException`. That hot reload stops before any Dart code is reloaded, and the device keeps the old probe.

**Engine** (`dart:ui`, debug mode only)
- `FragmentProgram.fromAsset` caches one program per asset key. `reinitializeShader` re-reads the asset into that same `FragmentProgram` object. A program that was never loaded is skipped, and the next `fromAsset` loads the new file.
- Every live `FragmentShader` made from that program gets a new, zero-filled uniform buffer, so uniforms must be set again after each reload.
- Named slots (`getUniformFloat`, `getUniformVec2` … `getUniformMat4`, image sampler slots) are re-pointed at the new layout by name. A slot whose uniform no longer exists is dropped from rebinding and keeps its old index.

**What this means for the design**
- Load the probe once with `FragmentProgram.fromAsset('shaders/_debug/probe.frag')` and keep it. Each reload swaps its code in place, and its `FragmentShader`s stay valid.
- `DebugShader` must replay uniforms on every paint, not once, because a reload zeroes them.
- Version stamp: `getUniformFloat(name)` throws `ArgumentError` for an unknown name. Put the stamp in a debug uniform's name (for example `_dbg_stamp_42`) and the app can tell which probe is loaded without reading the asset. impellerc keeps a declared uniform in the reflection data even when the shader never reads it (checked with `--reflection-json`), so the stamp uniform can stay unused.

**Confirmed end to end** (Nov 7, 2026, macOS, Impeller; `tool/e2e_heatmap.py`)
- After writing a new probe, the hot reload (`app.restart`) takes about 0.2 s, and the new stamp is already visible on the first `showHeatmap` call after it returns.
- A probe that does not compile makes the hot reload fail with "DevFS synchronization failed". The previous probe stays loaded and still works.

**API assumptions verified** (Flutter 3.47.8, devtools_app_shared 0.5.1)
- `FragmentShader.getUniformFloat`, `getUniformVec2/3/4`, `getUniformMat2/3/4`, uniform arrays and `ImageSamplerSlot` exist.
- `Picture.toImageSync(w, h, targetFormat: TargetPixelFormat.rgbaFloat32)` exists.
- `ServiceManager.performHotReload` and `callServiceExtensionOnMainIsolate` exist.
- `FlutterFragCoord()` returns `vec2`. Under Impeller it reads `in vec2 _fragCoord`, under Skia `gl_FragCoord.xy`. The parser's stub must declare `vec2 FlutterFragCoord()`.

## 9. Next steps

Done (Nov 7, 2026):
- Scaffolded the repo as a pub workspace: `shader_debugger_core`, `shader_debugger` (runtime, with `example/`) and `shader_debugger_devtools` (the extension).
- Wrote the M1 data model with unit tests: `GlslType`, `SymbolTable` / `Scope` / `GlslSymbol`, `StatementInfo` and `ShaderAnalysis`.

Started M2 (Nov 7, 2026), with the parts that do not need the parser:
- Instrumenter (`instrument()` in core). It works from the data model, so it runs on hand-built analyses until the parser exists. Every probe variant in the tests compiles with impellerc for macOS and Android.
- Runtime: `DebugShader` (records uniforms by name, swaps in the probe), `ShaderDebugger` (probe program, stamp check, `ext.shader_debugger.getInfo` / `showHeatmap` / `hideHeatmap`). Tested against real shader execution in the example app, and end to end through the Flutter tool with `tool/e2e_heatmap.py`.

Next:
- M1: preprocessor with a source map (`#define`, the `runtime_effect.glsl` stub), tokenizer and parser, and a resolver that fills the data model. `test/support/fixtures.dart` in core spells out its expected output; the instrumenter's identifier scan should then move to the tokenizer.
- M2, extension side (needs the parser): read the `.frag` through DTD, variable picker, write the probe, `performHotReload`, then `showHeatmap` with retries; range controls.

---

## 10. References

**Flutter / Dart APIs**
- Flutter fragment shaders: https://docs.flutter.dev/ui/advanced/shaders
- DTD `DartToolingDaemon`: https://pub.dev/documentation/dtd/latest/dtd/DartToolingDaemon-class.html
- DTD file system example: https://dart.googlesource.com/sdk/+/stable/pkg/dtd/example/dtd_file_system_service_example.dart
- `ServiceManager.performHotReload`: https://pub.dev/documentation/devtools_app_shared/latest/service/ServiceManager/performHotReload.html
- `callServiceExtensionOnMainIsolate`: https://pub.dev/documentation/devtools_app_shared/latest/service/ServiceManager/callServiceExtensionOnMainIsolate.html
- `Picture.toImageSync`: https://api.flutter.dev/flutter/dart-ui/Picture/toImageSync.html
- `TargetPixelFormat`: https://api.flutter.dev/flutter/dart-ui/TargetPixelFormat.html
- Impeller — reading GPU frame captures: https://flutter.googlesource.com/mirrors/engine/+/a9783b2ba4032763f09a2072a15e746a119d6f49/impeller/docs/read_frame_captures.md

**Shader debugging prior art**
- Shader Studio debugging: https://teaqu.github.io/shader-studio/debugging/
- webgl-shader-editor: https://github.com/gkjohnson/webgl-shader-editor
- Xcode shader debugger: https://developer.apple.com/documentation/xcode/debugging-the-shaders-within-a-draw-command-or-compute-dispatch

**Existing packages checked**
- glslgen: https://pub.dev/packages/glslgen
- shader_prototypes: https://github.com/flar/shader_prototypes
- flutter_scene: https://pub.dev/packages/flutter_scene/versions/0.21.1
- flutter_gaussian_splatter: https://pub.dev/packages/flutter_gaussian_splatter
- golden_lens: https://pub.dev/packages/golden_lens
- cvd_simulator: https://github.com/fischerscode/flutter-cvd_simulator
- wcag_vision: https://pub.dev/packages/wcag_vision
- buoy_images: https://pub.dev/packages/buoy_images
- flutter_native_charts: https://pub.dev/packages/flutter_native_charts
- GdxNormalLight (LibGDX 2D lighting): https://github.com/BennyOe/GdxNormalLight
