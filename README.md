# Flutter Shader Debugger

Debug Flutter fragment shaders in the running app. Pick a variable in a `.frag`
file and see it as a live heatmap where the shader is drawn, or click a pixel
to read the variable's exact value there.

It ships as a DevTools extension plus a debug-only runtime package. Outside
Flutter, the closest tools are Xcode's Metal shader debugger, RenderDoc, Shader
Studio and webgl-shader-editor.

**Status: early development.** M1 (the pure-Dart core) is done; M2 (heatmap
mode) is in progress. Nothing is published yet.
[docs/architecture.md](docs/architecture.md) covers how it works, the status
and the plan.

## Packages

| Package | What it is | Status |
|---|---|---|
| [`shader_debugger_core`](packages/shader_debugger_core) | Pure Dart: GLSL analyzer and probe instrumenter. | M1 done |
| [`shader_debugger`](packages/shader_debugger) | Debug-only runtime. It also ships the DevTools extension. | Heatmap runtime works |
| [`shader_debugger_devtools`](packages/shader_debugger_devtools) | The DevTools extension (Flutter web). | Placeholder |
| [`example`](packages/shader_debugger/example) | Demo app that draws the example shader the docs use. | Runs (checked on macOS) |

## Develop

Requires Flutter 3.47 or later. The repo is a pub workspace, so one
`flutter pub get` at the root sets up every package.

```sh
flutter pub get
flutter analyze
(cd packages/shader_debugger_core && dart test)
```

To see the extension in DevTools, build it into the runtime package, then run
the example app and open DevTools:

```sh
cd packages/shader_debugger_devtools
dart run devtools_extensions build_and_copy --source=. --dest=../shader_debugger/extension/devtools
cd ../shader_debugger/example
flutter run -d macos
```

## Milestones

1. **M1:** `shader_debugger_core`: parser, symbols and instrumenter, with unit
   tests.
2. **M2:** heatmap mode end to end.
3. **M3:** pixel inspector.
4. **M4:** auto-generated sliders for uniforms.

## License

[MIT](LICENSE)
