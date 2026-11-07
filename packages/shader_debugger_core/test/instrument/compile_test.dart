/// Compiles generated probes with impellerc, the compiler the Flutter tool
/// uses. Skipped when impellerc cannot be found next to `flutter`.
library;

import 'dart:io';

import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/impellerc.dart';

/// A matrix, an array, and an array of structs, each written in part.
const compositeSource = '''
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;

out vec4 fragColor;

struct Light {
  vec2 position;
  vec3 color;
};

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  mat2 spin = mat2(uv.x, uv.y, -uv.y, uv.x);
  float weights[3];
  weights[0] = 0.25;
  weights[1] = uv.x;
  weights[2] = uv.y;
  Light lights[2];
  lights[0] = Light(vec2(0.2), vec3(1.0, 0.5, 0.0));
  lights[1] = Light(spin * uv, vec3(weights[1]));
  fragColor = vec4(lights[1].color * weights[2], 1.0);
}
''';

/// Captures [name] at the statement starting with [statementStart], along
/// [path], or the picker's default path when it is null.
Probe compositeProbe(
  String statementStart,
  String name, {
  List<Selector>? path,
  required int stamp,
}) {
  final analysis = analyzeShader(compositeSource);
  expect(analysis.diagnostics, isEmpty);
  final statement = analysis.statements.firstWhere(
    (s) => s.span.text.startsWith(statementStart),
  );
  final variable = statement.inScope.firstWhere((v) => v.name == name);
  return instrument(
    analysis,
    CaptureRequest(
      statement: statement,
      variable: variable,
      path: path ?? statement.defaultPath(variable)!,
    ),
    stamp: stamp,
  );
}

void main() {
  final probes = <String, Probe Function()>{
    'gradient: d (scalar)': () {
      final f = GradientFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.dStatement, variable: f.d),
        stamp: 1,
      );
    },
    'gradient: uv (rg)': () {
      final f = GradientFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.uvStatement, variable: f.uv),
        stamp: 2,
      );
    },
    'gradient: col[1] (path)': () {
      final f = GradientFixture();
      return instrument(
        f.analysis,
        CaptureRequest(
          statement: f.colStatement,
          variable: f.col,
          path: const [IndexSelector(1)],
        ),
        stamp: 3,
      );
    },
    'gradient: fragColor (rgba, wrapped expression)': () {
      final f = GradientFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.outputStatement, variable: f.fragColor),
        stamp: 4,
      );
    },
    'branchy: a before return (jump)': () {
      final f = BranchyFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.returnStatement, variable: f.a),
        stamp: 5,
      );
    },
    'branchy: a after the if (control)': () {
      final f = BranchyFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.ifStatement, variable: f.a),
        stamp: 6,
      );
    },
    'branchy: a += b (compound assignment)': () {
      final f = BranchyFixture();
      return instrument(
        f.analysis,
        CaptureRequest(statement: f.compound, variable: f.a),
        stamp: 7,
      );
    },
    'composite: spin[1] (matrix column)': () => compositeProbe(
      'lights[1] =',
      'spin',
      path: const [IndexSelector(1)],
      stamp: 8,
    ),
    'composite: weights[2] where it is written (array element)': () =>
        compositeProbe('weights[2] =', 'weights', stamp: 9),
    'composite: lights[1].position where it is written (struct in array)': () =>
        compositeProbe('lights[1] =', 'lights', stamp: 10),
    'composite: lights[0].color before the output (nested path)': () =>
        compositeProbe(
          'fragColor =',
          'lights',
          path: const [IndexSelector(0), FieldSelector('color')],
          stamp: 11,
        ),
  };

  test('composite probes capture the expected part', () {
    expect(probes.keys.where((k) => k.startsWith('composite')), hasLength(4));
    expect(
      compositeProbe('weights[2] =', 'weights', stamp: 1).request.expression,
      'weights[2]',
    );
    final lights = compositeProbe('lights[1] =', 'lights', stamp: 2);
    expect(lights.request.expression, 'lights[1].position');
    expect(
      lights.source,
      contains('_dbg_value = vec4(lights[1].position, 0.0, 1.0); }'),
    );
  });

  late Directory temp;
  setUpAll(() => temp = Directory.systemTemp.createTempSync('probe_compile'));
  tearDownAll(() => temp.deleteSync(recursive: true));

  for (final MapEntry(key: name, value: build) in probes.entries) {
    for (final target in impellercTargets.keys) {
      test('$name compiles for $target', skip: skipWithoutImpellerc, () async {
        final probe = build();
        final result = await compileShader(
          probe.source,
          directory: temp,
          name: 'probe_${probe.stamp}',
          target: target,
        );
        expect(
          result.exitCode,
          0,
          reason:
              '${result.stdout}\n${result.stderr}\n--- probe ---\n'
              '${probe.source}',
        );
      });
    }
  }
}
