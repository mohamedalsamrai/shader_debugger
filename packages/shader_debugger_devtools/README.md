# shader_debugger_devtools

The Shader Debugger DevTools extension: a Flutter web app that DevTools loads in
a tab. It is not published on its own. Its compiled output ships inside
`package:shader_debugger` under `extension/devtools/build/`.

**Status: placeholder.** It shows the connection to the app and the
type-to-visualization table. The variable picker, heatmap and pixel inspector
arrive in M2 and M3.

## Develop

Run it in the simulated DevTools environment (Chrome, with a panel for
connecting to a running app):

```sh
flutter run -d chrome --dart-define=use_simulated_environment=true
```

## Build into package:shader_debugger

```sh
dart run devtools_extensions build_and_copy --source=. --dest=../shader_debugger/extension/devtools
dart run devtools_extensions validate --package=../shader_debugger
```

Then run the example app (`packages/shader_debugger/example`) and open DevTools.
The build output is git-ignored and kept in the published package by
`extension/devtools/.pubignore`.
