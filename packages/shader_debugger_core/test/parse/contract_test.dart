/// The fixtures in test/support/fixtures.dart are the resolver's contract:
/// analyzing the same source must produce the same symbols, scopes and
/// statements.
library;

import 'package:shader_debugger_core/shader_debugger_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

String describeSymbol(GlslSymbol symbol) {
  final common =
      '${symbol.name} span=${symbol.span?.text} visibleFrom=${symbol.visibleFrom} '
      'depth=${symbol.scope.depth}';
  return switch (symbol) {
    VariableSymbol() =>
      'variable ${symbol.kind.name} ${symbol.type} $common const=${symbol.isConst}',
    FunctionSymbol() =>
      'function ${symbol.returnType} (${symbol.parameters.join(', ')}) $common '
          'defined=${symbol.isDefined}',
    StructSymbol() => 'struct $common',
  };
}

String describeScope(Scope scope) {
  final span = scope.span;
  final where = span == null ? '' : ' ${span.start.offset}-${span.end.offset}';
  return '${scope.kind.name}$where [${scope.children.map(describeScope).join(', ')}]';
}

String describeStatement(StatementInfo statement) {
  List<String> names(Iterable<GlslSymbol> symbols) => [
    for (final s in symbols) s.name,
  ];
  return '${statement.kind.name} "${statement.span.text}" '
      'scope=${statement.scope.kind.name}@${statement.scope.depth} '
      'function=${statement.function.name} writes=${names(statement.writes)} '
      'inScope=${names(statement.inScope)} pick=${statement.defaultPick?.name} '
      'parts=${{for (final MapEntry(:key, :value) in statement.writtenParts.entries) key.name: value.join()}} '
      'pickable=${statement.isPickable}';
}

void expectSameAnalysis(ShaderAnalysis actual, ShaderAnalysis expected) {
  expect(actual.diagnostics, isEmpty);
  expect(
    actual.symbols.symbols.map(describeSymbol),
    expected.symbols.symbols.map(describeSymbol),
  );
  expect(
    describeScope(actual.symbols.global),
    describeScope(expected.symbols.global),
  );
  expect(
    actual.statements.map(describeStatement),
    expected.statements.map(describeStatement),
  );
}

void main() {
  test('gradient.frag parses to the hand-built analysis', () {
    expectSameAnalysis(
      analyzeShader(gradientSource, url: Uri.parse('shaders/gradient.frag')),
      GradientFixture().analysis,
    );
  });

  test('branchy.frag parses to the hand-built analysis', () {
    expectSameAnalysis(
      analyzeShader(branchySource, url: Uri.parse('shaders/branchy.frag')),
      BranchyFixture().analysis,
    );
  });

  test('instrumenting the parsed analysis gives the golden probe', () {
    final analysis = analyzeShader(gradientSource);
    final d = analysis.statements
        .firstWhere((s) => s.span.text.startsWith('float d'))
        .defaultPick!;
    final fromParsed = instrument(
      analysis,
      CaptureRequest(
        statement: analysis.statementsOnLine(d.span!.start.line).single,
        variable: d,
      ),
      stamp: 1,
    );
    final f = GradientFixture();
    final fromFixture = instrument(
      f.analysis,
      CaptureRequest(statement: f.dStatement, variable: f.d),
      stamp: 1,
    );
    expect(fromParsed.source, fromFixture.source);
  });
}
