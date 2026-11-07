/// The result of analyzing one `.frag` file.
library;

import 'package:source_span/source_span.dart';

import 'statement_info.dart';
import 'symbols.dart';

/// How serious a [Diagnostic] is.
enum DiagnosticSeverity { info, warning, error }

/// A problem the analyzer found.
///
/// impellerc decides whether a shader is valid. Diagnostics explain why the
/// debugger understands less of a file than impellerc does, for example why
/// picking is disabled on a line.
final class Diagnostic {
  const Diagnostic(this.severity, this.message, {this.span});

  final DiagnosticSeverity severity;
  final String message;

  /// Where the problem is, or null if it concerns the whole file.
  final FileSpan? span;

  @override
  String toString() {
    final span = this.span;
    if (span == null) return '${severity.name}: $message';
    final file = span.sourceUrl?.pathSegments.lastOrNull ?? 'shader';
    final where = '$file:${span.start.line + 1}:${span.start.column + 1}';
    return '$where: ${severity.name}: $message';
  }
}

/// Everything the variable picker needs from one `.frag` file: its symbol
/// table, the facts about each statement, and the problems found.
final class ShaderAnalysis {
  ShaderAnalysis({
    required this.source,
    required this.symbols,
    Iterable<StatementInfo> statements = const [],
    Iterable<Diagnostic> diagnostics = const [],
  }) : statements = List.unmodifiable(
         statements.toList()..sort(
           (a, b) => a.span.start.offset != b.span.start.offset
               ? a.span.start.offset.compareTo(b.span.start.offset)
               : a.id.compareTo(b.id),
         ),
       ),
       diagnostics = List.unmodifiable(diagnostics) {
    assert(
      this.statements.every((statement) => identical(statement.span.file, source)),
      'Every statement must point into the analyzed source file.',
    );
  }

  /// The analyzed file, as written (before preprocessing).
  final SourceFile source;

  final SymbolTable symbols;

  /// The statements in the file, in source order.
  final List<StatementInfo> statements;

  final List<Diagnostic> diagnostics;

  late final Map<int, List<StatementInfo>> _byLine = () {
    final byLine = <int, List<StatementInfo>>{};
    for (final statement in statements) {
      (byLine[statement.line] ??= []).add(statement);
    }
    return byLine;
  }();

  late final Map<int, StatementInfo> _byId = {
    for (final statement in statements) statement.id: statement,
  };

  /// The uniforms, in declaration order.
  List<VariableSymbol> get uniforms => symbols.uniforms.toList();

  /// The `void main()` definition, or null if the file has none.
  FunctionSymbol? get mainFunction => symbols.functions
      .where((function) => function.isMain && function.isDefined)
      .firstOrNull;

  /// The statements that start on 0-based [line], in source order.
  List<StatementInfo> statementsOnLine(int line) => _byLine[line] ?? const [];

  /// The statement with [id], or null if there is none.
  StatementInfo? statementById(int id) => _byId[id];
}
