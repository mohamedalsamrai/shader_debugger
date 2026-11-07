/// Prints the probe that captures a value in a shader, as the DevTools
/// extension would write it.
///
/// Usage, from the repo root:
///
/// ```sh
/// dart --packages=.dart_tool/package_config.json tool/make_probe.dart \
///   <shader.frag> <line> <expression> <stamp>
/// ```
///
/// `line` is 1-based; `expression` is a variable in scope there, optionally
/// with a path to a part of it, such as `d` or `lights[1].position`.
library;

import 'dart:io';

import 'package:shader_debugger_core/shader_debugger_core.dart';

void main(List<String> args) {
  if (args.length != 4) {
    stderr.writeln(
      'Usage: make_probe.dart <shader.frag> <line> <expression> <stamp>',
    );
    exit(64);
  }
  final file = File(args[0]);
  final line = int.parse(args[1]) - 1;
  final stamp = int.parse(args[3]);

  final expression = RegExp(r'^(\w+)((?:\[\d+\]|\.\w+)*)$').firstMatch(args[2]);
  if (expression == null) _fail('Cannot read the expression "${args[2]}".');
  final name = expression.group(1)!;
  final path = [
    for (final step in RegExp(
      r'\[(\d+)\]|\.(\w+)',
    ).allMatches(expression.group(2)!))
      step.group(1) != null
          ? IndexSelector(int.parse(step.group(1)!))
          : FieldSelector(step.group(2)!),
  ];

  final analysis = analyzeShader(file.readAsStringSync(), url: file.uri);
  final statement =
      analysis.statementsOnLine(line).where((s) => s.isPickable).lastOrNull ??
      _fail('No statement to capture at line ${line + 1}.');
  final variable =
      statement.inScope.where((v) => v.name == name).firstOrNull ??
      _fail('$name is not in scope at line ${line + 1}.');
  try {
    stdout.write(
      instrument(
        analysis,
        CaptureRequest(statement: statement, variable: variable, path: path),
        stamp: stamp,
      ).source,
    );
  } on InstrumentationException catch (error) {
    _fail(error.message);
  }
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
