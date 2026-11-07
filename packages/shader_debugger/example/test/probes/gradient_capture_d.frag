#version 460 core

#include <flutter/runtime_effect.glsl>

// Shader Debugger probe: generated from the shader below. Do not edit.
vec2 _dbg_fragCoord();
vec4 _dbg_value = vec4(0.0);

uniform vec2 uSize;
uniform vec4 uA;
uniform vec4 uB;

out vec4 fragColor;

void _dbg_main() {
  vec2 uv = _dbg_fragCoord().xy / uSize;
  float d = length(uv - 0.5); _dbg_value = vec4(d, 0.0, 0.0, 1.0);
  vec3 col = mix(uA.rgb, uB.rgb, d);
  fragColor = vec4(col, 1.0);
}

// ---- Shader Debugger probe (generated) ----
uniform float _dbg_mode;
uniform vec2 _dbg_coord;
uniform vec2 _dbg_range;
uniform float _dbg_stamp_1;

vec2 _dbg_fragCoord() {
  return _dbg_mode > 0.5 ? _dbg_coord : FlutterFragCoord();
}

vec3 _dbg_colormap(float t) {
  vec3 c0 = vec3(0.267, 0.004, 0.329);
  vec3 c1 = vec3(0.231, 0.322, 0.545);
  vec3 c2 = vec3(0.129, 0.569, 0.549);
  vec3 c3 = vec3(0.369, 0.788, 0.384);
  vec3 c4 = vec3(0.992, 0.906, 0.145);
  float x = t * 4.0;
  if (x < 1.0) {
    return mix(c0, c1, x);
  }
  if (x < 2.0) {
    return mix(c1, c2, x - 1.0);
  }
  if (x < 3.0) {
    return mix(c2, c3, x - 2.0);
  }
  return mix(c3, c4, x - 3.0);
}

vec4 _dbg_encode(vec4 v) {
  // Pixel modes write raw values with an alpha of 1, so that alpha never
  // scales them; w is read in a second pass.
  if (_dbg_mode > 1.5) {
    return vec4(v.w, 0.0, 0.0, 1.0);
  }
  if (_dbg_mode > 0.5) {
    return vec4(v.xyz, 1.0);
  }
  float extent = _dbg_range.y - _dbg_range.x;
  float scale = extent != 0.0 ? 1.0 / extent : 0.0;
  return vec4(_dbg_colormap(clamp((v.x - _dbg_range.x) * scale, 0.0, 1.0)), 1.0);
}

void main() {
  _dbg_main();
  fragColor = _dbg_encode(_dbg_value);
}
