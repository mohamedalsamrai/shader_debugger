// Three point lights, an array of structs summed in a loop.
//
// In the debugger: pick `lights`, then an element and a field, to see one
// light's parameters; pick `color` after the loop to see the sum. A value
// inside the loop shows the last iteration, so `dist` there is the distance
// to the last light.
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;

out vec4 fragColor;

struct Light {
  vec2 position;
  vec3 color;
  float radius;
};

const int LIGHT_COUNT = 3;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  Light lights[LIGHT_COUNT];
  lights[0] = Light(vec2(0.3 + 0.15 * sin(uTime), 0.35), vec3(1.0, 0.35, 0.2), 0.4);
  lights[1] = Light(vec2(0.7, 0.4 + 0.15 * cos(0.8 * uTime)), vec3(0.2, 0.6, 1.0), 0.35);
  lights[2] = Light(vec2(0.5, 0.75), vec3(0.4, 1.0, 0.45), 0.3 + 0.05 * sin(1.7 * uTime));

  vec3 color = vec3(0.02);
  for (int i = 0; i < LIGHT_COUNT; i++) {
    float dist = length(uv - lights[i].position);
    float falloff = smoothstep(lights[i].radius, 0.0, dist);
    color += lights[i].color * falloff;
  }
  fragColor = vec4(color, 1.0);
}
