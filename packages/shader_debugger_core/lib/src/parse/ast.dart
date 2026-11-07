/// The syntax tree of a GLSL shader. Every node knows its first and last
/// token, which place it in the analyzed file (see docs/architecture.md).
library;

import 'token.dart';

/// A syntax tree node.
sealed class Node {
  Node(this.first, this.last);

  final Token first;
  final Token last;
}

/// The whole file: global declarations and functions, in order.
final class TranslationUnit {
  TranslationUnit(this.declarations);

  final List<ExternalDeclaration> declarations;
}

/// Something at global scope.
sealed class ExternalDeclaration implements Node {}

/// A type as written: a keyword, a struct name, or an inline struct, with
/// optional array dimensions (`float[3]`).
final class TypeSpec extends Node {
  TypeSpec(
    super.first,
    super.last, {
    required this.name,
    this.struct,
    this.dimensions = const [],
  });

  /// The type keyword or struct name; the `struct` keyword for an anonymous
  /// inline struct.
  final Token name;

  /// An inline struct definition, as in `struct Light { ... } light;`.
  final StructDefinition? struct;

  /// Array dimensions written on the type. A null size is `[]`.
  final List<Expression?> dimensions;
}

final class StructDefinition extends Node {
  StructDefinition(
    super.first,
    super.last, {
    required this.name,
    required this.fields,
  });

  /// Null for an anonymous struct.
  final Token? name;
  final List<VariableDeclaration> fields;
}

/// One declared name, with its array dimensions and initializer.
final class Declarator extends Node {
  Declarator(
    super.first,
    super.last, {
    required this.name,
    this.dimensions = const [],
    this.initializer,
  });

  final Token name;
  final List<Expression?> dimensions;
  final Expression? initializer;
}

/// `qualifiers type a = 1.0, b;`, at global scope or as a statement. A
/// struct definition with no names (`struct S { ... };`) has no declarators.
final class VariableDeclaration extends Statement
    implements ExternalDeclaration {
  VariableDeclaration(
    super.first,
    super.last, {
    required this.qualifiers,
    required this.type,
    required this.declarators,
  });

  /// Qualifier keywords, such as `uniform`, `out` or `const`. `layout(...)`
  /// is dropped.
  final Set<String> qualifiers;
  final TypeSpec type;
  final List<Declarator> declarators;
}

final class Parameter extends Node {
  Parameter(
    super.first,
    super.last, {
    required this.qualifiers,
    required this.type,
    this.name,
    this.dimensions = const [],
  });

  final Set<String> qualifiers;
  final TypeSpec type;
  final Token? name;
  final List<Expression?> dimensions;
}

/// A function prototype, or a definition when [body] is set.
final class FunctionDeclaration extends Node implements ExternalDeclaration {
  FunctionDeclaration(
    super.first,
    super.last, {
    required this.returnType,
    required this.name,
    required this.openParen,
    required this.parameters,
    this.body,
  });

  final TypeSpec returnType;
  final Token name;
  final Token openParen;
  final List<Parameter> parameters;
  final Block? body;
}

/// A global construct the debugger skips, such as an interface block.
final class SkippedDeclaration extends Node implements ExternalDeclaration {
  SkippedDeclaration(super.first, super.last, this.reason);

  final String reason;
}

// Statements.

sealed class Statement extends Node {
  Statement(super.first, super.last);
}

final class Block extends Statement {
  Block(super.first, super.last, this.statements);

  final List<Statement> statements;
}

final class ExpressionStatement extends Statement {
  ExpressionStatement(super.first, super.last, this.expression);

  final Expression expression;
}

final class IfStatement extends Statement {
  IfStatement(
    super.first,
    super.last, {
    required this.condition,
    required this.then,
    this.otherwise,
  });

  final Expression condition;
  final Statement then;
  final Statement? otherwise;
}

final class ForStatement extends Statement {
  ForStatement(
    super.first,
    super.last, {
    this.initializer,
    this.condition,
    this.step,
    required this.body,
  });

  /// A [VariableDeclaration] or an [ExpressionStatement].
  final Statement? initializer;
  final Expression? condition;
  final Expression? step;
  final Statement body;
}

final class WhileStatement extends Statement {
  WhileStatement(
    super.first,
    super.last, {
    required this.condition,
    required this.body,
  });

  final Expression condition;
  final Statement body;
}

final class DoStatement extends Statement {
  DoStatement(
    super.first,
    super.last, {
    required this.body,
    required this.condition,
  });

  final Statement body;
  final Expression condition;
}

final class SwitchStatement extends Statement {
  SwitchStatement(
    super.first,
    super.last, {
    required this.value,
    required this.body,
  });

  final Expression value;
  final Block body;
}

/// `case value:` or `default:` inside a switch.
final class CaseLabel extends Statement {
  CaseLabel(super.first, super.last, this.value);

  /// Null for `default`.
  final Expression? value;
}

final class ReturnStatement extends Statement {
  ReturnStatement(super.first, super.last, this.value);

  final Expression? value;
}

/// `break`, `continue` or `discard`.
final class JumpStatement extends Statement {
  JumpStatement(super.first, super.last);
}

/// `;` on its own, or a statement the debugger ignores (`precision ...;`).
final class EmptyStatement extends Statement {
  EmptyStatement(super.first, super.last);
}

/// A statement that could not be parsed; its tokens were skipped.
final class ErrorStatement extends Statement {
  ErrorStatement(super.first, super.last, this.message);

  final String message;
}

// Expressions.

sealed class Expression extends Node {
  Expression(super.first, super.last);
}

final class NameExpression extends Expression {
  NameExpression(Token name) : super(name, name);

  Token get name => first;
}

/// A number or `true` / `false`.
final class LiteralExpression extends Expression {
  LiteralExpression(Token token) : super(token, token);
}

/// A prefix or postfix operator.
final class UnaryExpression extends Expression {
  UnaryExpression(
    super.first,
    super.last, {
    required this.operator,
    required this.operand,
    required this.isPostfix,
  });

  final Token operator;
  final Expression operand;
  final bool isPostfix;
}

final class BinaryExpression extends Expression {
  BinaryExpression(this.left, this.operator, this.right)
    : super(left.first, right.last);

  final Expression left;
  final Token operator;
  final Expression right;
}

/// `=` or a compound assignment such as `+=`.
final class AssignmentExpression extends Expression {
  AssignmentExpression(this.target, this.operator, this.value)
    : super(target.first, value.last);

  final Expression target;
  final Token operator;
  final Expression value;
}

final class ConditionalExpression extends Expression {
  ConditionalExpression(this.condition, this.then, this.otherwise)
    : super(condition.first, otherwise.last);

  final Expression condition;
  final Expression then;
  final Expression otherwise;
}

/// A function call or a constructor such as `vec3(1.0)` or `float[2](a, b)`.
final class CallExpression extends Expression {
  CallExpression(
    super.first,
    super.last, {
    required this.callee,
    required this.arguments,
  });

  /// The function name or constructor type.
  final Token callee;
  final List<Expression> arguments;
}

final class IndexExpression extends Expression {
  IndexExpression(
    super.first,
    super.last, {
    required this.target,
    required this.index,
  });

  final Expression target;
  final Expression index;
}

/// A struct field or a swizzle, such as `light.color` or `uv.xy`.
final class FieldExpression extends Expression {
  FieldExpression(this.target, this.field) : super(target.first, field);

  final Expression target;
  final Token field;
}

/// The comma operator: `a = 1.0, b = 2.0`.
final class SequenceExpression extends Expression {
  SequenceExpression(this.expressions)
    : super(expressions.first.first, expressions.last.last);

  final List<Expression> expressions;
}

/// A brace initializer list: `{1.0, 2.0}`.
final class InitializerList extends Expression {
  InitializerList(super.first, super.last, this.elements);

  final List<Expression> elements;
}

/// Walks [expression] and its subexpressions, depth first.
Iterable<Expression> subexpressions(Expression expression) sync* {
  yield expression;
  final children = switch (expression) {
    NameExpression() || LiteralExpression() => const <Expression>[],
    UnaryExpression(:final operand) => [operand],
    BinaryExpression(:final left, :final right) => [left, right],
    AssignmentExpression(:final target, :final value) => [target, value],
    ConditionalExpression(:final condition, :final then, :final otherwise) => [
      condition,
      then,
      otherwise,
    ],
    CallExpression(:final arguments) => arguments,
    IndexExpression(:final target, :final index) => [target, index],
    FieldExpression(:final target) => [target],
    SequenceExpression(:final expressions) => expressions,
    InitializerList(:final elements) => elements,
  };
  for (final child in children) {
    yield* subexpressions(child);
  }
}
