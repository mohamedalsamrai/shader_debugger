/// Generates probe shaders (design doc §4, "Instrumentation rules").
///
/// A probe is the user's shader, edited as text so it stays readable:
///
/// * `main` is renamed `_dbg_main`, and a new `main` calls it and then writes
///   the captured value to the output. Early `return`s keep working.
/// * At the picked statement, the picked value is copied into `_dbg_value`,
///   widened to `vec4` by type.
/// * `FlutterFragCoord()` in user code becomes `_dbg_fragCoord()`, which
///   pixel mode can pin to one coordinate.
/// * The debug uniforms, including a version stamp, go at the end of the file,
///   so the user's uniforms keep their positions.
library;

import '../../protocol.dart';
import '../model/glsl_type.dart';
import '../model/shader_analysis.dart';
import '../model/statement_info.dart';
import '../model/symbols.dart';

/// What to capture: a variable as it is at one statement, optionally
/// narrowed to a part of it (a matrix column, an array element, a field).
final class CaptureRequest {
  CaptureRequest({
    required this.statement,
    required this.variable,
    Iterable<Selector> path = const [],
  }) : path = List.unmodifiable(path);

  final StatementInfo statement;
  final VariableSymbol variable;

  /// Steps from [variable] to the captured part. Empty captures it whole.
  final List<Selector> path;

  /// The GLSL expression the probe reads, such as `uLights[1].color`.
  String get expression =>
      path.fold(variable.name, (expression, step) => step.applyTo(expression));
}

/// A generated probe and what the results panel needs to read it.
final class Probe {
  const Probe._({
    required this.source,
    required this.stamp,
    required this.request,
    required this.valueType,
    required this.visualization,
  });

  /// The probe's GLSL source, ready to write to the probe asset.
  final String source;

  /// The version stamp embedded in [source] (see [ProbeUniforms.stamp]).
  final int stamp;

  final CaptureRequest request;

  /// The type of the captured value, after the request's path.
  final GlslType valueType;

  /// How heatmap mode draws the value.
  final Visualization visualization;

  /// The name of the stamp uniform the app checks for.
  String get stampUniform => ProbeUniforms.stamp(stamp);
}

/// Thrown when a [CaptureRequest] cannot be turned into a probe.
final class InstrumentationException implements Exception {
  const InstrumentationException(this.message);

  final String message;

  @override
  String toString() => 'InstrumentationException: $message';
}

/// Builds the probe that captures [request] in the shader [analysis]
/// describes, tagged with [stamp].
///
/// Throws an [InstrumentationException] when the request cannot be captured:
/// the statement is not pickable, the variable is not in scope there, the
/// path does not lead to a scalar or vector, or the shader has no `main` or
/// no single output.
Probe instrument(
  ShaderAnalysis analysis,
  CaptureRequest request, {
  required int stamp,
}) {
  if (stamp < 0) {
    throw ArgumentError.value(stamp, 'stamp', 'Must not be negative');
  }
  final statement = request.statement;
  if (!identical(analysis.statementById(statement.id), statement)) {
    throw ArgumentError.value(
      statement,
      'request.statement',
      'Not part of this analysis',
    );
  }
  final line = statement.line + 1;
  if (!statement.isPickable) {
    throw InstrumentationException(
      'Cannot capture at line $line: ${statement.unsupportedReason}.',
    );
  }
  if (!statement.inScope.contains(request.variable)) {
    throw InstrumentationException(
      '${request.variable.name} is not in scope at line $line.',
    );
  }
  final valueType = request.variable.type.selectPath(request.path);
  final visualization = valueType?.visualization;
  if (valueType == null || visualization == null) {
    throw InstrumentationException(
      '${request.expression} (${valueType ?? request.variable.type}) cannot be '
      'shown directly; pick a scalar or vector part of it.',
    );
  }
  final mainSpan = analysis.mainFunction?.span;
  if (mainSpan == null || !identical(mainSpan.file, analysis.source)) {
    throw const InstrumentationException('The shader has no main() to rename.');
  }
  final outputs = analysis.symbols.global.variables
      .where((variable) => variable.kind == VariableKind.output)
      .toList();
  if (outputs.length != 1) {
    throw InstrumentationException(
      outputs.isEmpty
          ? 'The shader declares no output variable.'
          : 'The shader declares ${outputs.length} outputs; expected one.',
    );
  }

  final text = analysis.source.getText(0);
  final headerEnd = _headerEnd(text);
  final edits = <_Edit>[
    _Edit(mainSpan.start.offset, mainSpan.end.offset, '_dbg_main'),
  ];

  var usesFragCoord = false;
  for (final (offset, name) in _identifiers(text, from: headerEnd)) {
    if (name == 'FlutterFragCoord') {
      usesFragCoord = true;
      edits.add(_Edit(offset, offset + name.length, '_dbg_fragCoord'));
    }
  }

  final declarations = [
    '// Shader Debugger probe: generated from the shader below. Do not edit.',
    if (usesFragCoord) 'vec2 _dbg_fragCoord();',
    'vec4 _dbg_value = vec4(0.0);',
  ].join('\n');
  edits.add(
    _Edit.insert(
      headerEnd,
      headerEnd == 0 ? '$declarations\n\n' : '\n\n$declarations',
    ),
  );

  final capture = '_dbg_value = ${valueType.widenToVec4(request.expression)};';
  final start = statement.span.start.offset;
  final end = statement.span.end.offset;
  switch (statement.kind) {
    case StatementKind.declaration:
      // Braces would end the declared variable's scope, so append instead.
      edits.add(_Edit.insert(end, ' $capture'));
    case StatementKind.expression || StatementKind.control:
      // Braces keep the capture in the same branch when the statement is the
      // un-braced body of an if or a loop.
      edits
        ..add(_Edit.insert(start, '{ '))
        ..add(_Edit.insert(end, ' $capture }'));
    case StatementKind.jump:
      edits
        ..add(_Edit.insert(start, '{ $capture '))
        ..add(_Edit.insert(end, ' }'));
  }

  final source = StringBuffer(_apply(text, edits));
  if (!text.endsWith('\n')) source.writeln();
  source
    ..writeln()
    ..writeln('// ---- Shader Debugger probe (generated) ----')
    ..writeln('uniform float ${ProbeUniforms.mode};')
    ..writeln('uniform vec2 ${ProbeUniforms.coord};')
    ..writeln('uniform vec2 ${ProbeUniforms.range};')
    ..writeln('uniform float ${ProbeUniforms.stamp(stamp)};');
  if (usesFragCoord) source.write(_fragCoordFunction);
  if (visualization == Visualization.scalar) source.write(_colormapFunction);
  source
    ..write(_encodeFunction(visualization))
    ..write(_mainFunction(outputs.single.name));

  return Probe._(
    source: source.toString(),
    stamp: stamp,
    request: request,
    valueType: valueType,
    visualization: visualization,
  );
}

const _fragCoordFunction =
    '''

vec2 _dbg_fragCoord() {
  return ${ProbeUniforms.mode} > 0.5 ? ${ProbeUniforms.coord} : FlutterFragCoord();
}
''';

/// Viridis (CC0), sampled at five stops and interpolated linearly.
const _colormapFunction = '''

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
''';

String _encodeFunction(Visualization visualization) {
  final heatmap = switch (visualization) {
    Visualization.scalar =>
      'vec4(_dbg_colormap(clamp((v.x - ${ProbeUniforms.range}.x) * scale, 0.0, 1.0)), 1.0)',
    Visualization.rg =>
      'vec4(clamp((v.xy - ${ProbeUniforms.range}.x) * scale, 0.0, 1.0), 0.0, 1.0)',
    // RGBA values are drawn as RGB: alpha would blend with what is behind.
    Visualization.rgb || Visualization.rgba =>
      'vec4(clamp((v.rgb - ${ProbeUniforms.range}.x) * scale, 0.0, 1.0), 1.0)',
  };
  return '''

vec4 _dbg_encode(vec4 v) {
  if (${ProbeUniforms.mode} > 0.5) {
    return v;
  }
  float extent = ${ProbeUniforms.range}.y - ${ProbeUniforms.range}.x;
  float scale = extent != 0.0 ? 1.0 / extent : 0.0;
  return $heatmap;
}
''';
}

String _mainFunction(String output) =>
    '''

void main() {
  _dbg_main();
  $output = _dbg_encode(_dbg_value);
}
''';

final _includeLine = RegExp(
  r'^[ \t]*#[ \t]*include[ \t]*<flutter/runtime_effect\.glsl>[^\n]*',
  multiLine: true,
);
final _versionLine = RegExp(r'^[ \t]*#[ \t]*version\b[^\n]*', multiLine: true);

/// The offset after the `runtime_effect.glsl` include, or else after
/// `#version`, or else 0. The probe's declarations go there, ahead of any
/// user code that refers to them.
int _headerEnd(String text) =>
    (_includeLine.firstMatch(text) ?? _versionLine.firstMatch(text))?.end ?? 0;

/// Identifiers in [text] from offset [from], skipping comments and numbers.
///
/// Stands in for the tokenizer until the M1 parser exists.
Iterable<(int, String)> _identifiers(String text, {required int from}) sync* {
  var i = from;
  while (i < text.length) {
    final c = text.codeUnitAt(i);
    final next = i + 1 < text.length ? text.codeUnitAt(i + 1) : 0;
    if (c == 0x2F && next == 0x2F) {
      final newline = text.indexOf('\n', i);
      i = newline < 0 ? text.length : newline;
    } else if (c == 0x2F && next == 0x2A) {
      final close = text.indexOf('*/', i + 2);
      i = close < 0 ? text.length : close + 2;
    } else if (_isIdentifierStart(c)) {
      final start = i;
      while (i < text.length && _isIdentifierPart(text.codeUnitAt(i))) {
        i++;
      }
      yield (start, text.substring(start, i));
    } else if (_isDigit(c)) {
      // Skip a number with its exponent or suffix, such as 1.5e3 or 0x1Fu.
      while (i < text.length &&
          (_isIdentifierPart(text.codeUnitAt(i)) ||
              text.codeUnitAt(i) == 0x2E)) {
        i++;
      }
    } else {
      i++;
    }
  }
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isIdentifierStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;

bool _isIdentifierPart(int c) => _isIdentifierStart(c) || _isDigit(c);

/// A replacement of `[start, end)` with [replacement]; an insertion when
/// `start == end`.
final class _Edit {
  _Edit(this.start, this.end, this.replacement);

  _Edit.insert(int offset, this.replacement) : start = offset, end = offset;

  final int start;
  final int end;
  final String replacement;
}

String _apply(String text, List<_Edit> edits) {
  final ordered = edits.indexed.toList()
    ..sort((a, b) {
      final (indexA, editA) = a;
      final (indexB, editB) = b;
      if (editA.start != editB.start) return editA.start - editB.start;
      if (editA.end != editB.end) return editA.end - editB.end;
      return indexA - indexB;
    });
  final out = StringBuffer();
  var cursor = 0;
  for (final (_, edit) in ordered) {
    if (edit.start < cursor) {
      throw StateError('Overlapping probe edits at offset ${edit.start}.');
    }
    out
      ..write(text.substring(cursor, edit.start))
      ..write(edit.replacement);
    cursor = edit.end;
  }
  return (out..write(text.substring(cursor))).toString();
}
