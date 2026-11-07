// A checkerboard turned by a rotation matrix.
//
// In the debugger: pick `spin` and a column to see the matrix, `cell` for
// the integer cell coordinates, or `dark`, a bool shown as 0 or 1.
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uCells;

out vec4 fragColor;

mat2 rotation(float angle) {
  float c = cos(angle);
  float s = sin(angle);
  return mat2(c, s, -s, c);
}

void main() {
  vec2 centered = FlutterFragCoord().xy - 0.5 * uSize;
  mat2 spin = rotation(0.3 * uTime);
  vec2 turned = spin * centered / uSize.y;
  ivec2 cell = ivec2(floor(turned * uCells));
  bool dark = mod(float(cell.x + cell.y), 2.0) < 1.0;
  vec3 color = dark ? vec3(0.13, 0.15, 0.2) : vec3(0.9, 0.86, 0.78);
  fragColor = vec4(color, 1.0);
}
