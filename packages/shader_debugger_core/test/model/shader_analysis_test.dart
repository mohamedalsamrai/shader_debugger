import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

/// The design doc's example shader (§4), completed into a full file. It is
/// the same as `example/shaders/gradient.frag` in package:shader_debugger.
const _gradient = '''
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

/// A shader with a nested block and an early return.
const _branchy = '''
out vec4 fragColor;

void main() {
  float a = 1.0;
  if (a > 0.5) {
    fragColor = vec4(a);
    return;
  }
  float b = a * 2.0;
  a += b;
}
''';

/// Builds a [ShaderAnalysis] by hand, the way the analyzer will: the tests
/// below pin down what the parser and resolver have to produce.
class _Builder {
  _Builder(String source, String url)
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
    final nameStart = declaration.start.offset + statement.indexOf(' $name') + 1;
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

  int lineOf(String text) => span(text).start.line;

  ShaderAnalysis build() =>
      ShaderAnalysis(source: file, symbols: table, statements: statements);
}

void main() {
  group('the design doc example', () {
    late _Builder b;
    late ShaderAnalysis analysis;

    setUp(() {
      b = _Builder(_gradient, 'shaders/gradient.frag');
      final global = b.table.global;
      // Declared by the runtime_effect.glsl stub, visible after the #include.
      global.declareFunction(
        'FlutterFragCoord',
        GlslType.vec2,
        visibleFrom: b.span('#include <flutter/runtime_effect.glsl>').end.offset,
      );
      final uSize = b.declare(global, 'uSize', GlslType.vec2, VariableKind.uniform, 'uniform vec2 uSize;');
      final uA = b.declare(global, 'uA', GlslType.vec4, VariableKind.uniform, 'uniform vec4 uA;');
      final uB = b.declare(global, 'uB', GlslType.vec4, VariableKind.uniform, 'uniform vec4 uB;');
      final fragColor = b.declare(global, 'fragColor', GlslType.vec4, VariableKind.output, 'out vec4 fragColor;');
      expect([uSize, uA, uB, fragColor], hasLength(4));

      final main = b.defineVoidFunction('main');
      const uvLine = 'vec2 uv = FlutterFragCoord().xy / uSize;';
      const dLine = 'float d = length(uv - 0.5);';
      const colLine = 'vec3 col = mix(uA.rgb, uB.rgb, d);';
      final uv = b.declare(main, 'uv', GlslType.vec2, VariableKind.local, uvLine);
      b.statement(StatementKind.declaration, uvLine, main, writes: [uv]);
      final d = b.declare(main, 'd', GlslType.floatType, VariableKind.local, dLine);
      b.statement(StatementKind.declaration, dLine, main, writes: [d]);
      final col = b.declare(main, 'col', GlslType.vec3, VariableKind.local, colLine);
      b.statement(StatementKind.declaration, colLine, main, writes: [col]);
      b.statement(StatementKind.expression, 'fragColor = vec4(col, 1.0);', main, writes: [fragColor]);

      analysis = b.build();
    });

    List<String> names(Iterable<GlslSymbol> symbols) => [for (final s in symbols) s.name];

    test('lists the uniforms in declaration order, with their types', () {
      expect(names(analysis.uniforms), ['uSize', 'uA', 'uB']);
      expect(analysis.uniforms.map((u) => u.type), [GlslType.vec2, GlslType.vec4, GlslType.vec4]);
    });

    test('finds main', () {
      expect(analysis.mainFunction?.name, 'main');
      expect(analysis.mainFunction?.span?.text, 'main');
    });

    test('maps a line to the statement that starts on it', () {
      final statements = analysis.statementsOnLine(b.lineOf('float d = length(uv - 0.5);'));
      expect(statements, hasLength(1));
      expect(names(statements.single.writes), ['d']);
      expect(statements.single.defaultPick?.name, 'd');
      expect(statements.single.function.name, 'main');
      expect(statements.single.isPickable, isTrue);
    });

    test('reports what is in scope after each statement (§5)', () {
      List<String> inScopeAfter(String text) =>
          names(analysis.statementsOnLine(b.lineOf(text)).single.inScope);

      const globals = ['uSize', 'uA', 'uB', 'fragColor'];
      expect(inScopeAfter('vec2 uv ='), ['uv', ...globals]);
      expect(inScopeAfter('float d ='), ['uv', 'd', ...globals]);
      expect(inScopeAfter('vec3 col ='), ['uv', 'd', 'col', ...globals]);
    });

    test('writing the output picks it by default', () {
      final statement = analysis.statementsOnLine(b.lineOf('fragColor = vec4(col, 1.0);')).single;
      expect(statement.kind, StatementKind.expression);
      expect(statement.defaultPick?.name, 'fragColor');
      expect(statement.defaultPick?.kind, VariableKind.output);
    });

    test('lines without a statement have nothing to pick', () {
      expect(analysis.statementsOnLine(b.lineOf('void main() {')), isEmpty);
      expect(analysis.statementsOnLine(b.lineOf('uniform vec2 uSize;')), isEmpty);
      expect(analysis.statementsOnLine(1), isEmpty, reason: 'blank line');
    });

    test('finds statements by id, in source order', () {
      expect(analysis.statements.map((s) => s.id), [0, 1, 2, 3]);
      expect(analysis.statementById(2)?.span.text, startsWith('vec3 col'));
      expect(analysis.statementById(9), isNull);
    });
  });

  group('control flow', () {
    late _Builder b;
    late ShaderAnalysis analysis;
    late VariableSymbol a;
    late VariableSymbol fragColor;

    setUp(() {
      b = _Builder(_branchy, 'branchy.frag');
      fragColor = b.declare(b.table.global, 'fragColor', GlslType.vec4, VariableKind.output, 'out vec4 fragColor;');
      final main = b.defineVoidFunction('main');
      a = b.declare(main, 'a', GlslType.floatType, VariableKind.local, 'float a = 1.0;');
      // Statements are added out of source order on purpose.
      b.statement(StatementKind.declaration, 'float a = 1.0;', main, writes: [a]);
      final ifSpan = b.span('if (a > 0.5) {\n    fragColor = vec4(a);\n    return;\n  }');
      final block = main.openBlock(span: b.file.span(ifSpan.text.indexOf('{') + ifSpan.start.offset, ifSpan.end.offset));
      final bVar = b.declare(main, 'b', GlslType.floatType, VariableKind.local, 'float b = a * 2.0;');
      b.statement(StatementKind.declaration, 'float b = a * 2.0;', main, writes: [bVar]);
      b.statement(StatementKind.expression, 'a += b;', main, writes: [a, a]);
      b.statement(StatementKind.jump, 'return;', block);
      b.statement(StatementKind.expression, 'fragColor = vec4(a);', block, writes: [fragColor]);
      b.statement(StatementKind.control, ifSpan.text, main);
      analysis = b.build();
    });

    test('sorts statements into source order', () {
      expect(analysis.statements.map((s) => s.span.text.split('\n').first), [
        'float a = 1.0;',
        'if (a > 0.5) {',
        'fragColor = vec4(a);',
        'return;',
        'float b = a * 2.0;',
        'a += b;',
      ]);
    });

    test('captures before a jump, so later declarations are not in scope', () {
      final ret = analysis.statementsOnLine(b.lineOf('return;')).single;
      expect(ret.kind.capturesBefore, isTrue);
      expect(ret.captureOffset, ret.span.start.offset);
      expect(ret.inScope.map((v) => v.name), ['a', 'fragColor']);
      expect(ret.defaultPick, isNull);
    });

    test('a control statement offers its scope but picks nothing by default', () {
      final ifStatement = analysis.statementsOnLine(b.lineOf('if (a > 0.5) {')).single;
      expect(ifStatement.kind, StatementKind.control);
      expect(ifStatement.defaultPick, isNull);
      expect(ifStatement.inScope, contains(a));
    });

    test('writes are de-duplicated', () {
      final statement = analysis.statementsOnLine(b.lineOf('a += b;')).single;
      expect(statement.writes, [a]);
      expect(statement.defaultPick, same(a));
    });

    test('a statement the parser does not understand cannot be picked', () {
      final file = SourceFile.fromString('void main() { WEIRD_MACRO; }');
      final table = SymbolTable();
      final main = table.global.openFunction(table.global.declareFunction('main', GlslType.voidType));
      final statement = StatementInfo(
        id: 0,
        kind: StatementKind.expression,
        span: file.span(14, 26),
        scope: main,
        unsupportedReason: 'comes from a macro expansion',
      );
      final analysis = ShaderAnalysis(
        source: file,
        symbols: table,
        statements: [statement],
        diagnostics: [
          Diagnostic(DiagnosticSeverity.warning, 'Picking disabled: macro expansion', span: statement.span),
        ],
      );

      expect(statement.isPickable, isFalse);
      expect(analysis.diagnostics.single.toString(), 'shader:1:15: warning: Picking disabled: macro expansion');
    });
  });
}
