/// Real shaders: the example app's, and the Flutter SDK's own (read from the
/// installed SDK, not copied). Each must analyze without problems, and a
/// probe at every statement must compile with impellerc.
library;

import 'dart:io';

import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

import '../support/impellerc.dart';

void main() {
  final sdk = flutterRoot?.path;
  final shaders = {
    for (final name in ['gradient', 'lights', 'checkerboard', 'ripple'])
      'example: $name.frag': File(
        '../shader_debugger/example/shaders/$name.frag',
      ),
    'Flutter SDK: ink_sparkle.frag': File(
      '$sdk/packages/flutter/lib/src/material/shaders/ink_sparkle.frag',
    ),
    'Flutter SDK: stretch_effect.frag': File(
      '$sdk/packages/flutter/lib/src/widgets/shaders/stretch_effect.frag',
    ),
  };

  late Directory temp;
  setUpAll(() => temp = Directory.systemTemp.createTempSync('corpus'));
  tearDownAll(() => temp.deleteSync(recursive: true));

  for (final MapEntry(key: name, value: file) in shaders.entries) {
    final missing = file.existsSync() ? false : 'not found: ${file.path}';

    group(name, () {
      ShaderAnalysis analyze() =>
          analyzeShader(file.readAsStringSync(), url: file.uri);

      test('analyzes without problems', skip: missing, () {
        final analysis = analyze();
        expect(analysis.diagnostics, isEmpty);
        expect(analysis.mainFunction, isNotNull);
        expect(analysis.statements, isNotEmpty);
        expect(analysis.statements.where((s) => !s.isPickable), isEmpty);
      });

      test(
        'a probe at every statement compiles',
        skip: missing != false ? missing : skipWithoutImpellerc,
        () async {
          final analysis = analyze();
          final probes = <Probe>[];
          // What the picker selects first: the written variable, down to
          // the part written, or the first variable with a drawable part.
          for (final statement in analysis.statements) {
            final variable = [
              ?statement.defaultPick,
              ...statement.inScope,
            ].where((v) => statement.defaultPath(v) != null).firstOrNull;
            if (variable == null) continue;
            probes.add(
              instrument(
                analysis,
                CaptureRequest(
                  statement: statement,
                  variable: variable,
                  path: statement.defaultPath(variable)!,
                ),
                stamp: statement.id,
              ),
            );
          }
          expect(probes, isNotEmpty);

          final failures = <String>[];
          const batch = 8;
          for (var i = 0; i < probes.length; i += batch) {
            await Future.wait([
              for (final probe in probes.skip(i).take(batch))
                compileShader(
                  probe.source,
                  directory: temp,
                  name: '${file.uri.pathSegments.last}_${probe.stamp}',
                ).then((result) {
                  if (result.exitCode != 0) {
                    final statement = probe.request.statement;
                    failures.add(
                      'line ${statement.line + 1} (${probe.request.expression}): '
                      '${result.stderr}${result.stdout}',
                    );
                  }
                }),
            ]);
          }
          expect(failures, isEmpty, reason: '${probes.length} probes');
        },
      );
    });
  }
}
