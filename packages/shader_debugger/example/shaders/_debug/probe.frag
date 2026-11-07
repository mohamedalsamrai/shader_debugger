// The design doc's example shader (docs/design.md §4). A good first target
// for the debugger: pick `d` to see the distance field as a heatmap.
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
  float d = length(uv - 0.5); _dbg_value = fragColor;
  vec3 col = mix(uA.rgb, uB.rgb, d);
  fragColor = vec4(col, 1.0);
}

// ---- Shader Debugger probe (generated) ----
uniform float _dbg_mode;
uniform vec2 _dbg_coord;
uniform vec2 _dbg_range;
uniform float _dbg_stamp_794062475;

vec2 _dbg_fragCoord() {
  return _dbg_mode > 0.5 ? _dbg_coord : FlutterFragCoord();
}

vec4 _dbg_encode(vec4 v) {
  if (_dbg_mode > 0.5) {
    return v;
  }
  float extent = _dbg_range.y - _dbg_range.x;
  float scale = extent != 0.0 ? 1.0 / extent : 0.0;
  return vec4(clamp((v.rgb - _dbg_range.x) * scale, 0.0, 1.0), 1.0);
}

void main() {
  _dbg_main();
  fragColor = _dbg_encode(_dbg_value);
}
