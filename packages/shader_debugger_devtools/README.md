# shader_debugger_devtools

The Shader Debugger DevTools extension: a Flutter web app that DevTools loads in
a tab. It is not published on its own. Its compiled output ships inside
`package:shader_debugger` under `extension/devtools/build/`.

**Status: heatmap (M2), pixel inspector (M3) and uniform overrides (M4).**
Pick a shader the app
draws through `DebugShader`, click a line, choose a value (for a matrix,
array or struct, also the column, element or field), and press Show heatmap.
The extension writes the probe through the Dart Tooling Daemon, hot reloads,
and has the app draw it; the range can change without a reload. In the Pixel
section, turn on Select pixel mode (like the inspector's Select Widget Mode)
and click pixels of the shader in the app, or type coordinates, to read the
value there as exact 32-bit floats. In the Uniforms tab, watch the app's
uniform values live and override any float uniform with sliders.

| File | What it does |
|---|---|
| `lib/src/controller.dart` | The flow and its state; no DevTools imports. |
| `lib/src/screen.dart` | The page. |
| `lib/src/ports.dart` | What the controller needs from the app and the files. |
| `lib/src/devtools_ports.dart` | Those ports on top of DevTools' `serviceManager` and `dtdManager`. |

## Develop

Run it in the simulated DevTools environment (Chrome, with a panel for
connecting to a running app):

```sh
flutter run -d chrome --dart-define=use_simulated_environment=true
```

## Test

```sh
flutter test   # controller and page, with fakes
```

`test/live_test.dart` runs the controller against a real session started by
`tool/devtools_session.py` (see the repo's CLAUDE.md).

## Build into package:shader_debugger

```sh
dart run devtools_extensions build_and_copy --source=. --dest=../shader_debugger/extension/devtools
dart run devtools_extensions validate --package=../shader_debugger
```

Then run the example app (`packages/shader_debugger/example`) and open DevTools.
The build output is git-ignored and kept in the published package by
`extension/devtools/.pubignore`.
