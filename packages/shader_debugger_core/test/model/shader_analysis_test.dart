import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

List<String> names(Iterable<GlslSymbol> symbols) => [
  for (final symbol in symbols) symbol.name,
];

void main() {
  group('the example shader', () {
    late GradientFixture f;
    late ShaderAnalysis analysis;

    setUp(() {
      f = GradientFixture();
      analysis = f.analysis;
    });

    test('lists the uniforms in declaration order, with their types', () {
      expect(names(analysis.uniforms), ['uSize', 'uA', 'uB']);
      expect(analysis.uniforms.map((u) => u.type), [
        GlslType.vec2,
        GlslType.vec4,
        GlslType.vec4,
      ]);
    });

    test('finds main', () {
      expect(analysis.mainFunction?.name, 'main');
      expect(analysis.mainFunction?.span?.text, 'main');
    });

    test('maps a line to the statement that starts on it', () {
      final statements = analysis.statementsOnLine(
        f.builder.lineOf('float d = length(uv - 0.5);'),
      );
      expect(statements, [f.dStatement]);
      expect(names(f.dStatement.writes), ['d']);
      expect(f.dStatement.defaultPick, same(f.d));
      expect(f.dStatement.function.name, 'main');
      expect(f.dStatement.isPickable, isTrue);
    });

    test('reports what is in scope after each statement (§5)', () {
      const globals = ['uSize', 'uA', 'uB', 'fragColor'];
      expect(names(f.uvStatement.inScope), ['uv', ...globals]);
      expect(names(f.dStatement.inScope), ['uv', 'd', ...globals]);
      expect(names(f.colStatement.inScope), ['uv', 'd', 'col', ...globals]);
    });

    test('writing the output picks it by default', () {
      expect(f.outputStatement.kind, StatementKind.expression);
      expect(f.outputStatement.defaultPick, same(f.fragColor));
      expect(f.fragColor.kind, VariableKind.output);
    });

    test('lines without a statement have nothing to pick', () {
      final b = f.builder;
      expect(analysis.statementsOnLine(b.lineOf('void main() {')), isEmpty);
      expect(
        analysis.statementsOnLine(b.lineOf('uniform vec2 uSize;')),
        isEmpty,
      );
      expect(analysis.statementsOnLine(1), isEmpty, reason: 'blank line');
    });

    test('finds statements by id, in source order', () {
      expect(analysis.statements.map((s) => s.id), [0, 1, 2, 3]);
      expect(analysis.statementById(2), same(f.colStatement));
      expect(analysis.statementById(9), isNull);
    });
  });

  group('control flow', () {
    late BranchyFixture f;

    setUp(() => f = BranchyFixture());

    test('sorts statements into source order', () {
      expect(f.analysis.statements, [
        f.aStatement,
        f.ifStatement,
        f.earlyWrite,
        f.returnStatement,
        f.bStatement,
        f.compound,
        f.finalWrite,
      ]);
    });

    test('captures before a jump, so later declarations are not in scope', () {
      final ret = f.returnStatement;
      expect(ret.kind.capturesBefore, isTrue);
      expect(ret.captureOffset, ret.span.start.offset);
      expect(names(ret.inScope), ['a', 'uSize', 'fragColor']);
      expect(ret.defaultPick, isNull);
    });

    test('a control statement offers its scope but picks nothing', () {
      expect(f.ifStatement.kind, StatementKind.control);
      expect(f.ifStatement.defaultPick, isNull);
      expect(f.ifStatement.inScope, contains(f.a));
    });

    test('writes are de-duplicated', () {
      expect(f.compound.writes, [f.a]);
      expect(f.compound.defaultPick, same(f.a));
    });

    test('a statement the parser does not understand cannot be picked', () {
      final file = SourceFile.fromString('void main() { WEIRD_MACRO; }');
      final table = SymbolTable();
      final main = table.global.openFunction(
        table.global.declareFunction('main', GlslType.voidType),
      );
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
          Diagnostic(
            DiagnosticSeverity.warning,
            'Picking disabled: macro expansion',
            span: statement.span,
          ),
        ],
      );

      expect(statement.isPickable, isFalse);
      expect(
        analysis.diagnostics.single.toString(),
        'shader:1:15: warning: Picking disabled: macro expansion',
      );
    });
  });
}
