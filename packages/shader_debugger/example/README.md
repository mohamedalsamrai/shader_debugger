# shader_debugger_example

Demo app for the Flutter shader debugger. It draws
[`shaders/gradient.frag`](shaders/gradient.frag), the example shader that
[docs/architecture.md](../../../docs/architecture.md) uses.

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

Commit only the placeholder probe, never a generated one. To keep the
extension's writes out of `git status` in your clone, run once:

```sh
git update-index --skip-worktree shaders/_debug/probe.frag
```

Undo it with `--no-skip-worktree` before changing the placeholder on purpose.
