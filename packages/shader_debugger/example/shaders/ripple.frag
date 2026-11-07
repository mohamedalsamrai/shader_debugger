// An image seen through moving ripples.
//
// In the debugger: pick `offset` or `shade`, which ripple() writes through
// out parameters, or `texel`, sampled from an image the app made. The
// probe gets the same image.
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform sampler2D uImage;

out vec4 fragColor;

void ripple(vec2 uv, float time, out vec2 offset, out float shade) {
  vec2 fromCenter = uv - 0.5;
  float wave = sin(length(fromCenter) * 40.0 - 4.0 * time);
  offset = normalize(fromCenter + 0.0001) * wave * 0.01;
  shade = 0.85 + 0.15 * wave;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  vec2 offset;
  float shade;
  ripple(uv, uTime, offset, shade);
  vec4 texel = texture(uImage, uv + offset);
  fragColor = vec4(texel.rgb * shade, 1.0);
}
