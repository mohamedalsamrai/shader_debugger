/// Compiles generated probes with impellerc, the compiler the Flutter tool
/// uses. Skipped when impellerc cannot be found next to `flutter`.
library;

import 'dart:io';

import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/impellerc.dart';

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
  };

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
