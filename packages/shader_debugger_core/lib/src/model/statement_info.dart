/// Per-statement facts for the variable picker ("The analyzer" in
/// docs/architecture.md).
library;

import 'package:source_span/source_span.dart';

import 'glsl_type.dart';
import 'symbols.dart';

/// The kind of a statement. It decides where a capture is placed.
enum StatementKind {
  /// A declaration, such as `float d = length(uv);`.
  declaration,

  /// An expression statement: an assignment, an increment or a call.
  expression,

  /// `if`, `for`, `while`, `do`, `switch` or a nested block. A capture placed
  /// after it sees the state once the whole construct has run.
  control,

  /// `return`, `discard`, `break` or `continue`. Nothing after it runs, so
  /// the capture is placed before it.
  jump;

  /// Whether the capture goes before the statement instead of after it.
  bool get capturesBefore => this == jump;
}

/// What the variable picker knows about one statement.
///
/// The picker shows [writes] and [inScope] for the line under the cursor and
/// selects [defaultPick] first. The instrumenter then copies the chosen
/// variable into `_dbg_value` at the statement's capture point.
final class StatementInfo {
  StatementInfo({
    required this.id,
    required this.kind,
    required this.span,
    required this.scope,
    Iterable<VariableSymbol> writes = const [],
    Map<VariableSymbol, List<Selector>> writtenParts = const {},
    this.unsupportedReason,
  }) : assert(scope.function != null, 'statements run inside a function'),
       writes = List.unmodifiable(writes.toSet()),
       writtenParts = Map<VariableSymbol, List<Selector>>.unmodifiable({
         for (final MapEntry(:key, :value) in writtenParts.entries)
           key: List<Selector>.unmodifiable(value),
       });

  /// Unique within its `ShaderAnalysis`.
  final int id;

  final StatementKind kind;

  /// The statement in the original source, from its first token through its
  /// closing `;` or `}`.
  final FileSpan span;

  /// The scope the statement runs in.
  final Scope scope;

  /// The variables the statement writes, in source order and without
  /// duplicates.
  ///
  /// These are variables declared with an initializer, targets of `=`,
  /// compound assignments, `++` and `--`, and variables passed to `out` or
  /// `inout` parameters. Writes made inside nested statements belong to
  /// those statements.
  final List<VariableSymbol> writes;

  /// For each of [writes] that the statement writes only in part, as far as
  /// the analyzer can tell, that part: `[1].color` for
  /// `lights[1].color.r = 1.0;`.
  ///
  /// A part stops before an index that is not a constant, and at the first
  /// part the probe can draw whole, so swizzles and vector components are
  /// left out. Variables written whole have no entry; when a statement
  /// writes a variable more than once, its first write counts.
  final Map<VariableSymbol, List<Selector>> writtenParts;

  /// Why the debugger cannot capture at this statement, or null if it can.
  ///
  /// The parser is not a validator (impellerc is). When it meets a construct
  /// it does not understand, it disables picking on that statement instead of
  /// failing the whole file.
  final String? unsupportedReason;

  /// Whether the picker can capture at this statement.
  bool get isPickable => unsupportedReason == null;

  /// The function the statement belongs to.
  FunctionSymbol get function => scope.function!;

  /// The 0-based line the statement starts on.
  int get line => span.start.line;

  /// The source offset where the captured value is read: the end of the
  /// statement, or its start for a [StatementKind.jump].
  int get captureOffset =>
      kind.capturesBefore ? span.start.offset : span.end.offset;

  /// The variables that can be captured at this statement, innermost scope
  /// first.
  late final List<VariableSymbol> inScope = List.unmodifiable(
    scope.visibleVariables(at: captureOffset),
  );

  /// The variable the picker selects first: the first one this statement
  /// writes that is still in scope at the capture point, or null if there is
  /// none.
  VariableSymbol? get defaultPick {
    final visible = inScope.toSet();
    return writes.where(visible.contains).firstOrNull;
  }

  /// The path the picker selects first for [variable]: to the part this
  /// statement writes ([writtenParts]), then on to the first part of it the
  /// probe can draw ([GlslType.firstDrawablePath]). Null when no part of
  /// [variable] can be drawn.
  List<Selector>? defaultPath(VariableSymbol variable) {
    final part = writtenParts[variable] ?? const [];
    final rest = variable.type.selectPath(part)?.firstDrawablePath;
    return rest == null ? variable.type.firstDrawablePath : [...part, ...rest];
  }

  @override
  String toString() =>
      'StatementInfo#$id(${kind.name}, line ${line + 1}: ${span.text})';
}
