/// Hand-built analyses of small shaders.
///
/// They describe what the parser and resolver must produce for these sources;
/// once the parser exists, the same assertions should hold for parsed
/// analyses. The instrumenter tests use them as input.
library;

import 'package:shader_debugger_core/shader_debugger_core.dart';

/// The example shader from docs/architecture.md, as a full file. It
/// matches `example/shaders/gradient.frag` in package:shader_debugger, minus
/// that file's header comment.
const gradientSource = '''
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform vec4 uA;
uniform vec4 uB;

out vec4 fragColor;

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float d = length(uv - 0.5);
  vec3 col = mix(uA.rgb, uB.rgb, d);
  fragColor = vec4(col, 1.0);
}
''';

/// A shader with a nested block, an early return and a compound assignment.
const branchySource = '''
#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;

out vec4 fragColor;

void main() {
  float a = FlutterFragCoord().x / uSize.x;
  if (a > 0.5) {
    fragColor = vec4(a);
    return;
  }
  float b = a * 2.0;
  a += b;
  fragColor = vec4(a, b, 0.0, 1.0);
}
''';

/// Builds a [ShaderAnalysis] by hand, the way the resolver will.
class AnalysisBuilder {
  AnalysisBuilder(String source, String url)
    : file = SourceFile.fromString(source, url: Uri.parse(url));

  final SourceFile file;
  final table = SymbolTable();
  final statements = <StatementInfo>[];

  String get _text => file.getText(0);

  /// The only occurrence of [text] in the source.
  FileSpan span(String text) {
    final start = _text.indexOf(text);
    if (start < 0 || _text.indexOf(text, start + 1) >= 0) {
      throw ArgumentError('"$text" must occur exactly once');
    }
    return file.span(start, start + text.length);
  }

  /// The 0-based line of the only occurrence of [text].
  int lineOf(String text) => span(text).start.line;

  /// Declares `vec2 FlutterFragCoord()`, as the runtime_effect.glsl stub
  /// will, visible after the `#include`.
  void declareFlutterFragCoord() => table.global.declareFunction(
    'FlutterFragCoord',
    GlslType.vec2,
    visibleFrom: span('#include <flutter/runtime_effect.glsl>').end.offset,
  );

  /// Declares [name], whose declaration statement is [statement]. The
  /// variable becomes visible at the end of its declarator, before the `;`.
  VariableSymbol declare(
    Scope scope,
    String name,
    GlslType type,
    VariableKind kind,
    String statement,
  ) {
    final declaration = span(statement);
    final nameStart =
        declaration.start.offset + statement.indexOf(' $name') + 1;
    return scope.declareVariable(
      name,
      type,
      kind: kind,
      span: file.span(nameStart, nameStart + name.length),
      visibleFrom: declaration.end.offset - 1,
    );
  }

  /// Opens the definition of a `void` function called [name]. Its scope runs
  /// from the parameter list to the last `}` in the file.
  Scope defineVoidFunction(String name) {
    final header = span('void $name(');
    final function = table.global.declareFunction(
      name,
      GlslType.voidType,
      span: file.span(header.start.offset + 5, header.end.offset - 1),
    );
    return table.global.openFunction(
      function,
      span: file.span(header.end.offset - 1, _text.lastIndexOf('}') + 1),
    );
  }

  StatementInfo statement(
    StatementKind kind,
    String text,
    Scope scope, {
    List<VariableSymbol> writes = const [],
    String? unsupportedReason,
  }) {
    final info = StatementInfo(
      id: statements.length,
      kind: kind,
      span: span(text),
      scope: scope,
      writes: writes,
      unsupportedReason: unsupportedReason,
    );
    statements.add(info);
    return info;
  }

  ShaderAnalysis build() =>
      ShaderAnalysis(source: file, symbols: table, statements: statements);
}

/// [gradientSource], analyzed.
class GradientFixture {
  factory GradientFixture() {
    final b = AnalysisBuilder(gradientSource, 'shaders/gradient.frag');
    final global = b.table.global;
    b.declareFlutterFragCoord();
    const uniforms = {
      'uSize': (GlslType.vec2, 'uniform vec2 uSize;'),
      'uA': (GlslType.vec4, 'uniform vec4 uA;'),
      'uB': (GlslType.vec4, 'uniform vec4 uB;'),
    };
    for (final MapEntry(key: name, value: (type, line)) in uniforms.entries) {
      b.declare(global, name, type, VariableKind.uniform, line);
    }
    final fragColor = b.declare(
      global,
      'fragColor',
      GlslType.vec4,
      VariableKind.output,
      'out vec4 fragColor;',
    );

    final main = b.defineVoidFunction('main');
    const uvLine = 'vec2 uv = FlutterFragCoord().xy / uSize;';
    const dLine = 'float d = length(uv - 0.5);';
    const colLine = 'vec3 col = mix(uA.rgb, uB.rgb, d);';
    final uv = b.declare(main, 'uv', GlslType.vec2, VariableKind.local, uvLine);
    final uvStatement = b.statement(
      StatementKind.declaration,
      uvLine,
      main,
      writes: [uv],
    );
    final d = b.declare(
      main,
      'd',
      GlslType.floatType,
      VariableKind.local,
      dLine,
    );
    final dStatement = b.statement(
      StatementKind.declaration,
      dLine,
      main,
      writes: [d],
    );
    final col = b.declare(
      main,
      'col',
      GlslType.vec3,
      VariableKind.local,
      colLine,
    );
    final colStatement = b.statement(
      StatementKind.declaration,
      colLine,
      main,
      writes: [col],
    );
    final outputStatement = b.statement(
      StatementKind.expression,
      'fragColor = vec4(col, 1.0);',
      main,
      writes: [fragColor],
    );
    return GradientFixture._(
      builder: b,
      analysis: b.build(),
      fragColor: fragColor,
      uv: uv,
      d: d,
      col: col,
      uvStatement: uvStatement,
      dStatement: dStatement,
      colStatement: colStatement,
      outputStatement: outputStatement,
    );
  }

  GradientFixture._({
    required this.builder,
    required this.analysis,
    required this.fragColor,
    required this.uv,
    required this.d,
    required this.col,
    required this.uvStatement,
    required this.dStatement,
    required this.colStatement,
    required this.outputStatement,
  });

  final AnalysisBuilder builder;
  final ShaderAnalysis analysis;
  final VariableSymbol fragColor;
  final VariableSymbol uv;
  final VariableSymbol d;
  final VariableSymbol col;
  final StatementInfo uvStatement;
  final StatementInfo dStatement;
  final StatementInfo colStatement;
  final StatementInfo outputStatement;
}

/// [branchySource], analyzed. Statements are added out of source order on
/// purpose, to check that [ShaderAnalysis] sorts them.
class BranchyFixture {
  factory BranchyFixture() {
    final b = AnalysisBuilder(branchySource, 'shaders/branchy.frag');
    final global = b.table.global;
    b.declareFlutterFragCoord();
    b.declare(
      global,
      'uSize',
      GlslType.vec2,
      VariableKind.uniform,
      'uniform vec2 uSize;',
    );
    final fragColor = b.declare(
      global,
      'fragColor',
      GlslType.vec4,
      VariableKind.output,
      'out vec4 fragColor;',
    );
    final main = b.defineVoidFunction('main');
    const aLine = 'float a = FlutterFragCoord().x / uSize.x;';
    final a = b.declare(
      main,
      'a',
      GlslType.floatType,
      VariableKind.local,
      aLine,
    );
    final aStatement = b.statement(
      StatementKind.declaration,
      aLine,
      main,
      writes: [a],
    );
    final ifSpan = b.span(
      'if (a > 0.5) {\n    fragColor = vec4(a);\n    return;\n  }',
    );
    final block = main.openBlock(
      span: b.file.span(
        ifSpan.start.offset + ifSpan.text.indexOf('{'),
        ifSpan.end.offset,
      ),
    );
    const bLine = 'float b = a * 2.0;';
    final bVar = b.declare(
      main,
      'b',
      GlslType.floatType,
      VariableKind.local,
      bLine,
    );
    final bStatement = b.statement(
      StatementKind.declaration,
      bLine,
      main,
      writes: [bVar],
    );
    final compound = b.statement(
      StatementKind.expression,
      'a += b;',
      main,
      writes: [a, a],
    );
    final returnStatement = b.statement(StatementKind.jump, 'return;', block);
    final earlyWrite = b.statement(
      StatementKind.expression,
      'fragColor = vec4(a);',
      block,
      writes: [fragColor],
    );
    final ifStatement = b.statement(StatementKind.control, ifSpan.text, main);
    final finalWrite = b.statement(
      StatementKind.expression,
      'fragColor = vec4(a, b, 0.0, 1.0);',
      main,
      writes: [fragColor],
    );
    return BranchyFixture._(
      builder: b,
      analysis: b.build(),
      a: a,
      b: bVar,
      fragColor: fragColor,
      aStatement: aStatement,
      ifStatement: ifStatement,
      earlyWrite: earlyWrite,
      returnStatement: returnStatement,
      bStatement: bStatement,
      compound: compound,
      finalWrite: finalWrite,
    );
  }

  BranchyFixture._({
    required this.builder,
    required this.analysis,
    required this.a,
    required this.b,
    required this.fragColor,
    required this.aStatement,
    required this.ifStatement,
    required this.earlyWrite,
    required this.returnStatement,
    required this.bStatement,
    required this.compound,
    required this.finalWrite,
  });

  final AnalysisBuilder builder;
  final ShaderAnalysis analysis;
  final VariableSymbol a;
  final VariableSymbol b;
  final VariableSymbol fragColor;
  final StatementInfo aStatement;
  final StatementInfo ifStatement;
  final StatementInfo earlyWrite;
  final StatementInfo returnStatement;
  final StatementInfo bStatement;
  final StatementInfo compound;
  final StatementInfo finalWrite;
}
