# shader_debugger_example

Demo app for the Flutter shader debugger: a gallery of shaders, each with a
hint on what to try.

| Shader | Shows |
|---|---|
| [`gradient.frag`](shaders/gradient.frag) | A scalar heatmap (`d`). The example [docs/architecture.md](../../../docs/architecture.md) uses. |
| [`lights.frag`](shaders/lights.frag) | An array of structs summed in a loop: pick an element and a field. Values inside the loop are the last iteration's. |
| [`checkerboard.frag`](shaders/checkerboard.frag) | A rotation matrix (pick a column), an `ivec2` and a `bool`. |
| [`ripple.frag`](shaders/ripple.frag) | Values written through `out` parameters, and an image sampled with `sampler2D` (the app draws the image at startup). |

The animated shaders take a `uTime` uniform; the pause button in the app bar
holds every value still while you read pixels.

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
