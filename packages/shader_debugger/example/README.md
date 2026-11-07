# shader_debugger_example

Demo app for the Flutter shader debugger. It draws
[`shaders/gradient.frag`](shaders/gradient.frag), the example shader from the
design doc.

```sh
flutter run -d macos   # or any device; Flutter web is out of scope
```

Then open DevTools from the running app and find the `shader_debugger` tab.

The setup a user's app needs is all here:

- a dependency on `package:shader_debugger`, which makes DevTools offer the
  extension;
- `shaders/_debug/probe.frag`, registered once under `flutter: shaders:` in
  `pubspec.yaml`. The extension overwrites it with the instrumented probe and
  hot reloads.
