// Placeholder probe for the Shader Debugger.
//
// The DevTools extension overwrites this file with an instrumented copy of the
// shader you are debugging, then hot reloads. It must stay registered under
// `flutter: shaders:` in pubspec.yaml, because the Flutter tool only compiles
// (and hot-reloads) shaders listed there.
#version 460 core

#include <flutter/runtime_effect.glsl>

out vec4 fragColor;

void main() {
  fragColor = vec4(0.0);
}
