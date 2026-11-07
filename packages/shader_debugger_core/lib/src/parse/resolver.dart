/// Turns the syntax tree into a [ShaderAnalysis]: the symbol table and the
/// facts about each statement ("The analyzer" in
/// docs/architecture.md).
library;

import 'package:source_span/source_span.dart';

import '../model/glsl_type.dart';
import '../model/shader_analysis.dart';
import '../model/statement_info.dart';
import '../model/symbols.dart';
import 'ast.dart';
import 'preprocessor.dart' show parseIntLiteral;
import 'token.dart';

/// Built-in functions that write some of their arguments, by argument index.
const _builtinOutArguments = {
  'modf': [1],
  'frexp': [1],
  'uaddCarry': [2],
  'usubBorrow': [2],
  'umulExtended': [2, 3],
  'imulExtended': [2, 3],
};

/// Resolves one parsed file. Create one per file.
final class Resolver {
  Resolver(this.source, this.unit);

  final SourceFile source;
  final TranslationUnit unit;

  final _table = SymbolTable();
  final _statements = <StatementInfo>[];
  final _diagnostics = <Diagnostic>[];

  /// Values of `const int` variables with a foldable initializer, for array
  /// sizes such as `float weights[N]`.
  final _constants = <VariableSymbol, int>{};

  /// Builds the analysis. [earlier] are diagnostics from the preprocessor and
  /// the parser; they come first in the result.
  ShaderAnalysis resolve({Iterable<Diagnostic> earlier = const []}) {
    for (final declaration in unit.declarations) {
      switch (declaration) {
        case VariableDeclaration():
          _declaration(declaration, _table.global);
        case FunctionDeclaration():
          _function(declaration);
        case SkippedDeclaration(:final reason):
          _warn(reason, declaration.first, declaration.last);
      }
    }
    return ShaderAnalysis(
      source: source,
      symbols: _table,
      statements: _statements,
      diagnostics: [...earlier, ..._diagnostics],
    );
  }

  // Declarations.

  /// Declares [declaration]'s names in [scope]. Returns what it writes:
  /// each variable with an initializer, then any writes inside that
  /// initializer.
  List<VariableSymbol> _declaration(
    VariableDeclaration declaration,
    Scope scope,
  ) {
    final qualifiers = declaration.qualifiers;
    final base = _baseType(declaration.type, scope);
    if (base == null) return const [];
    final kind = scope.kind != ScopeKind.global
        ? VariableKind.local
        : qualifiers.contains('uniform')
        ? VariableKind.uniform
        : qualifiers.contains('out')
        ? VariableKind.output
        : VariableKind.global;
    final writes = <VariableSymbol>[];
    for (final declarator in declaration.declarators) {
      final type = _withDimensions(base, [
        ...declarator.dimensions,
        ...declaration.type.dimensions,
      ], scope);
      final variable = scope.declareVariable(
        declarator.name.text,
        type,
        kind: kind,
        span: _nameSpan(declarator.name),
        visibleFrom: declarator.last.end,
        isConst: qualifiers.contains('const'),
      );
      final initializer = declarator.initializer;
      if (initializer == null) continue;
      writes
        ..add(variable)
        ..addAll(_writes(initializer, scope));
      if (variable.isConst && type == GlslType.intType) {
        final value = _constantInt(initializer, scope);
        if (value != null) _constants[variable] = value;
      }
    }
    return writes;
  }

  void _function(FunctionDeclaration function) {
    final global = _table.global;
    final returnType = _baseType(function.returnType, global);
    final parameters = <FunctionParameter>[];
    final parameterTypes = <GlslType>[];
    for (final parameter in function.parameters) {
      final base = _baseType(parameter.type, global);
      if (returnType == null || base == null) return;
      final type = _withDimensions(base, [
        ...parameter.dimensions,
        ...parameter.type.dimensions,
      ], global);
      parameterTypes.add(type);
      parameters.add(
        FunctionParameter(
          type,
          name: parameter.name?.text,
          direction: _direction(parameter.qualifiers),
          isConst: parameter.qualifiers.contains('const'),
        ),
      );
    }
    if (returnType == null) return;

    // A definition after a prototype completes the prototype's symbol.
    var symbol = global
        .lookupFunctions(function.name.text)
        .where(
          (existing) => _sameTypes([
            for (final p in existing.parameters) p.type,
          ], parameterTypes),
        )
        .firstOrNull;
    symbol ??= global.declareFunction(
      function.name.text,
      returnType,
      parameters: parameters,
      span: _nameSpan(function.name),
      visibleFrom: function.name.end,
    );

    final body = function.body;
    if (body == null) return;
    if (symbol.isDefined) {
      _warn(
        '${function.name.text} is defined twice.',
        function.name,
        function.name,
      );
      return;
    }
    final scope = global.openFunction(
      symbol,
      span: _span(function.openParen, function.last),
    );
    for (final (index, parameter) in function.parameters.indexed) {
      final name = parameter.name;
      if (name == null) continue;
      scope.declareVariable(
        name.text,
        parameterTypes[index],
        kind: VariableKind.parameter,
        span: _nameSpan(name),
        visibleFrom: name.end,
        isConst: parameters[index].isConst,
        direction: parameters[index].direction,
      );
    }
    _statementList(body.statements, scope);
  }

  /// The type [spec] names, without array dimensions. Declares an inline
  /// struct in [scope]. Reports and returns null for an unknown name.
  GlslType? _baseType(TypeSpec spec, Scope scope) {
    final struct = spec.struct;
    if (struct != null) return _struct(struct, scope);
    final name = spec.name;
    final type =
        GlslType.fromKeyword(name.text) ??
        switch (scope.lookup(name.text, at: name.offset)) {
          StructSymbol(:final type) => type,
          _ => null,
        };
    if (type == null) _warn('Unknown type "${name.text}".', name, name);
    return type;
  }

  StructType _struct(StructDefinition definition, Scope scope) {
    final fields = <StructField>[];
    for (final field in definition.fields) {
      final base = _baseType(field.type, scope);
      if (base == null) continue;
      for (final declarator in field.declarators) {
        fields.add(
          StructField(
            declarator.name.text,
            _withDimensions(base, [
              ...declarator.dimensions,
              ...field.type.dimensions,
            ], scope),
          ),
        );
      }
    }
    final name = definition.name;
    final type = StructType(name?.text ?? '', fields);
    if (name != null) {
      scope.declareStruct(
        type,
        span: _nameSpan(name),
        visibleFrom: definition.last.end,
      );
    }
    return type;
  }

  /// Wraps [base] in arrays, outermost dimension first.
  GlslType _withDimensions(
    GlslType base,
    List<Expression?> dimensions,
    Scope scope,
  ) {
    var type = base;
    for (final size in dimensions.reversed) {
      final length = size == null ? null : _constantInt(size, scope);
      type = ArrayType(type, length != null && length > 0 ? length : null);
    }
    return type;
  }

  // Statements.

  void _statementList(List<Statement> statements, Scope scope) {
    for (final statement in statements) {
      _statement(statement, scope);
    }
  }

  void _statement(Statement statement, Scope scope) {
    switch (statement) {
      case VariableDeclaration():
        final writes = _declaration(statement, scope);
        _record(statement, StatementKind.declaration, scope, writes);
      case ExpressionStatement(:final expression):
        _record(
          statement,
          StatementKind.expression,
          scope,
          _writes(expression, scope),
        );
      case Block(:final statements):
        _record(statement, StatementKind.control, scope, const []);
        _statementList(
          statements,
          scope.openBlock(span: _span(statement.first, statement.last)),
        );
      case IfStatement(:final condition, :final then, :final otherwise):
        _record(
          statement,
          StatementKind.control,
          scope,
          _writes(condition, scope),
        );
        _branch(then, scope);
        if (otherwise != null) _branch(otherwise, scope);
      case ForStatement(
        :final initializer,
        :final condition,
        :final step,
        :final body,
      ):
        // The header's declarations are visible in the body, which shares
        // the header's scope.
        final header = scope.openBlock(
          span: _span(statement.first, statement.last),
        );
        final writes = [
          ...switch (initializer) {
            VariableDeclaration() => _declaration(initializer, header),
            ExpressionStatement(:final expression) => _writes(
              expression,
              header,
            ),
            _ => const <VariableSymbol>[],
          },
          ..._writes(condition, header),
          ..._writes(step, header),
        ];
        _record(statement, StatementKind.control, scope, writes);
        if (body is Block) {
          _statementList(body.statements, header);
        } else {
          _statement(body, header);
        }
      case WhileStatement(:final condition, :final body):
        _record(
          statement,
          StatementKind.control,
          scope,
          _writes(condition, scope),
        );
        _branch(body, scope);
      case DoStatement(:final body, :final condition):
        _record(
          statement,
          StatementKind.control,
          scope,
          _writes(condition, scope),
        );
        _branch(body, scope);
      case SwitchStatement(:final value, :final body):
        _record(statement, StatementKind.control, scope, _writes(value, scope));
        final inner = scope.openBlock(span: _span(body.first, body.last));
        _statementList([
          for (final s in body.statements)
            if (s is! CaseLabel) s,
        ], inner);
      case ReturnStatement(:final value):
        _record(statement, StatementKind.jump, scope, _writes(value, scope));
      case JumpStatement():
        _record(statement, StatementKind.jump, scope, const []);
      case ErrorStatement():
        _record(
          statement,
          StatementKind.expression,
          scope,
          const [],
          unsupportedReason: 'it could not be parsed',
        );
      case CaseLabel() || EmptyStatement():
        break;
    }
  }

  /// The body of an `if`, `while` or `do`, which gets its own scope.
  void _branch(Statement body, Scope scope) {
    if (body is Block) {
      _statementList(
        body.statements,
        scope.openBlock(span: _span(body.first, body.last)),
      );
    } else {
      _statement(body, scope.openBlock(span: _span(body.first, body.last)));
    }
  }

  void _record(
    Statement statement,
    StatementKind kind,
    Scope scope,
    List<VariableSymbol> writes, {
    String? unsupportedReason,
  }) {
    final first = statement.first;
    final last = statement.last;
    // Code from an included file is not in the user's file: nothing to pick.
    if (first.origin == TokenOrigin.include) return;
    final reason =
        unsupportedReason ??
        (first.origin == TokenOrigin.macro || last.origin == TokenOrigin.macro
            ? 'it comes from a macro expansion'
            : last.origin == TokenOrigin.include
            ? 'it ends in an included file'
            : null);
    _statements.add(
      StatementInfo(
        id: _statements.length,
        kind: kind,
        span: _span(first, last),
        scope: scope,
        writes: writes,
        unsupportedReason: reason,
      ),
    );
  }

  // Expressions.

  /// The variables [expression] writes, in source order: assignment targets,
  /// `++`/`--` operands, and arguments passed to `out`/`inout` parameters.
  List<VariableSymbol> _writes(Expression? expression, Scope scope) {
    if (expression == null) return const [];
    final writes = <VariableSymbol>[];
    void add(Expression target) {
      final variable = _root(target, scope);
      if (variable != null) writes.add(variable);
    }

    for (final node in subexpressions(expression)) {
      switch (node) {
        case AssignmentExpression(:final target):
          add(target);
        case UnaryExpression(:final operator, :final operand)
            when operator.text == '++' || operator.text == '--':
          add(operand);
        case CallExpression(:final callee, :final arguments):
          for (final index in _writtenArguments(
            callee,
            arguments.length,
            scope,
          )) {
            add(arguments[index]);
          }
        default:
          break;
      }
    }
    return writes;
  }

  /// The variable an assignment target writes: `v` for `v`, `v[i]`, `v.x`
  /// and `v.a[2].b`.
  static VariableSymbol? _root(Expression target, Scope scope) {
    var current = target;
    while (true) {
      switch (current) {
        case IndexExpression(:final target) || FieldExpression(:final target):
          current = target;
        case NameExpression(:final name):
          final symbol = scope.lookup(name.text, at: name.offset);
          return symbol is VariableSymbol ? symbol : null;
        default:
          return null;
      }
    }
  }

  /// The indices of the arguments a call to [callee] with [count] arguments
  /// writes.
  static Iterable<int> _writtenArguments(Token callee, int count, Scope scope) {
    final overloads = scope
        .lookupFunctions(callee.text, at: callee.offset)
        .where((function) => function.parameters.length == count);
    if (overloads.isNotEmpty) {
      return {
        for (final function in overloads)
          for (final (index, parameter) in function.parameters.indexed)
            if (parameter.direction.writesArgument) index,
      };
    }
    // A variable or struct with the built-in's name hides it.
    if (scope.lookup(callee.text, at: callee.offset) != null) return const [];
    return (_builtinOutArguments[callee.text] ?? const <int>[]).where(
      (index) => index < count,
    );
  }

  /// The value of a constant integer expression, or null if it is not one
  /// the analyzer can fold.
  int? _constantInt(Expression expression, Scope scope) {
    switch (expression) {
      case LiteralExpression(:final first)
          when first.kind == TokenKind.intLiteral:
        return parseIntLiteral(first.text);
      case NameExpression(:final name):
        final symbol = scope.lookup(name.text, at: name.offset);
        return symbol is VariableSymbol ? _constants[symbol] : null;
      case UnaryExpression(:final operator, :final operand, isPostfix: false):
        final value = _constantInt(operand, scope);
        if (value == null) return null;
        return switch (operator.text) {
          '-' => -value,
          '+' => value,
          _ => null,
        };
      case BinaryExpression(:final left, :final operator, :final right):
        final a = _constantInt(left, scope);
        final b = _constantInt(right, scope);
        if (a == null || b == null) return null;
        return switch (operator.text) {
          '+' => a + b,
          '-' => a - b,
          '*' => a * b,
          '/' when b != 0 => a ~/ b,
          '%' when b != 0 => a.remainder(b),
          _ => null,
        };
      default:
        return null;
    }
  }

  // Helpers.

  static ParameterDirection _direction(Set<String> qualifiers) =>
      qualifiers.contains('inout')
      ? ParameterDirection.inputOutput
      : qualifiers.contains('out')
      ? ParameterDirection.output
      : ParameterDirection.input;

  static bool _sameTypes(List<GlslType> a, List<GlslType> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  FileSpan _span(Token first, Token last) {
    final start = first.offset < last.end ? first.offset : last.end;
    final end = first.offset < last.end ? last.end : first.offset;
    return source.span(start, end);
  }

  /// The span of a declared name, or null when the name is not written in
  /// the analyzed file (it comes from a macro or an include).
  FileSpan? _nameSpan(Token name) =>
      name.fromSource ? source.span(name.offset, name.end) : null;

  void _warn(String message, Token first, Token last) => _diagnostics.add(
    Diagnostic(DiagnosticSeverity.warning, message, span: _span(first, last)),
  );
}
