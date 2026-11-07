/// Parses preprocessed tokens into a [TranslationUnit]: recursive descent for
/// declarations and statements, precedence climbing for expressions.
///
/// It is not a validator. On a syntax error it reports a [Diagnostic], skips
/// to the end of the statement or declaration, and goes on, so one bad line
/// does not hide the rest of the file.
library;

import 'package:source_span/source_span.dart';

import '../model/shader_analysis.dart';
import 'ast.dart';
import 'token.dart';

/// Parses one file's preprocessed tokens.
final class Parser {
  Parser(this.tokens, this.source)
    : _eof = Token(TokenKind.unknown, '', source.length, source.length);

  final List<Token> tokens;
  final SourceFile source;

  /// Syntax errors, in the order they were found.
  final diagnostics = <Diagnostic>[];

  final Token _eof;
  int _i = 0;

  static const _qualifierWords = {
    'const', 'uniform', 'in', 'out', 'inout', 'attribute', 'varying', //
    'buffer', 'shared', 'centroid', 'flat', 'smooth', 'noperspective', //
    'invariant', 'precise', 'highp', 'mediump', 'lowp', 'coherent', //
    'volatile', 'restrict', 'readonly', 'writeonly', 'patch', 'sample',
  };

  static const _assignmentOperators = {
    '=',
    '+=',
    '-=',
    '*=',
    '/=',
    '%=',
    '<<=',
    '>>=',
    '&=',
    '^=',
    '|=',
  };

  static const _binaryPrecedence = {
    '||': 1, '^^': 2, '&&': 3, '|': 4, '^': 5, '&': 6, //
    '==': 7, '!=': 7, '<': 8, '>': 8, '<=': 8, '>=': 8, //
    '<<': 9, '>>': 9, '+': 10, '-': 10, '*': 11, '/': 11, '%': 11,
  };

  static const _prefixOperators = {'+', '-', '!', '~', '++', '--'};

  TranslationUnit parse() {
    final declarations = <ExternalDeclaration>[];
    while (!_atEnd) {
      final start = _i;
      try {
        final declaration = _external();
        if (declaration != null) declarations.add(declaration);
      } on _ParseError catch (error) {
        _report(error);
        _skipDeclaration(start);
      }
    }
    return TranslationUnit(declarations);
  }

  // Global declarations.

  ExternalDeclaration? _external() {
    final first = _peek();
    if (_accept(';')) return null;
    if (first.isWord('precision')) {
      _skipPast(';');
      return null;
    }
    final qualifiers = _qualifiers();
    final next = _peek();
    if (next.kind == TokenKind.identifier &&
        !next.isWord('struct') &&
        _peek(1).isPunctuation('{')) {
      _i++;
      _skipBalanced();
      _skipPast(';');
      return SkippedDeclaration(
        first,
        _previous,
        'Interface blocks are not supported in Flutter shaders.',
      );
    }
    final type = _typeSpec();
    if (_accept(';')) {
      return VariableDeclaration(
        first,
        _previous,
        qualifiers: qualifiers,
        type: type,
        declarators: const [],
      );
    }
    final name = _identifier();
    if (_peek().isPunctuation('(')) return _function(first, type, name);
    final declarators = _declarators(name);
    _expect(';');
    return VariableDeclaration(
      first,
      _previous,
      qualifiers: qualifiers,
      type: type,
      declarators: declarators,
    );
  }

  FunctionDeclaration _function(Token first, TypeSpec returnType, Token name) {
    final openParen = _expect('(');
    final parameters = <Parameter>[];
    if (_peek().isWord('void') && _peek(1).isPunctuation(')')) _i++;
    if (!_peek().isPunctuation(')')) {
      do {
        final parameterFirst = _peek();
        final qualifiers = _qualifiers();
        final type = _typeSpec();
        final parameterName = _peek().kind == TokenKind.identifier
            ? _advance()
            : null;
        final dimensions = parameterName == null
            ? const <Expression?>[]
            : _dimensions();
        parameters.add(
          Parameter(
            parameterFirst,
            _previous,
            qualifiers: qualifiers,
            type: type,
            name: parameterName,
            dimensions: dimensions,
          ),
        );
      } while (_accept(','));
    }
    _expect(')');
    final body = _accept(';') ? null : _block();
    return FunctionDeclaration(
      first,
      _previous,
      returnType: returnType,
      name: name,
      openParen: openParen,
      parameters: parameters,
      body: body,
    );
  }

  Set<String> _qualifiers() {
    final words = <String>{};
    while (true) {
      final token = _peek();
      if (token.isWord('layout') && _peek(1).isPunctuation('(')) {
        _i++;
        _skipBalanced();
      } else if (token.kind == TokenKind.identifier &&
          _qualifierWords.contains(token.text)) {
        words.add(token.text);
        _i++;
      } else {
        return words;
      }
    }
  }

  TypeSpec _typeSpec() {
    final first = _peek();
    if (first.isWord('struct')) {
      final struct = _structDefinition();
      final dimensions = _dimensions();
      return TypeSpec(
        first,
        _previous,
        name: struct.name ?? first,
        struct: struct,
        dimensions: dimensions,
      );
    }
    final name = _identifier(what: 'a type');
    final dimensions = _dimensions();
    return TypeSpec(first, _previous, name: name, dimensions: dimensions);
  }

  StructDefinition _structDefinition() {
    final first = _advance();
    final name = _peek().kind == TokenKind.identifier ? _advance() : null;
    _expect('{');
    final fields = <VariableDeclaration>[];
    while (!_peek().isPunctuation('}') && !_atEnd) {
      final fieldFirst = _peek();
      final qualifiers = _qualifiers();
      final type = _typeSpec();
      final declarators = _declarators(_identifier(what: 'a field name'));
      _expect(';');
      fields.add(
        VariableDeclaration(
          fieldFirst,
          _previous,
          qualifiers: qualifiers,
          type: type,
          declarators: declarators,
        ),
      );
    }
    _expect('}');
    return StructDefinition(first, _previous, name: name, fields: fields);
  }

  List<Expression?> _dimensions() {
    final dimensions = <Expression?>[];
    while (_accept('[')) {
      if (_accept(']')) {
        dimensions.add(null);
        continue;
      }
      dimensions.add(_conditional());
      _expect(']');
    }
    return dimensions;
  }

  List<Declarator> _declarators(Token firstName) {
    final declarators = [_declarator(firstName)];
    while (_accept(',')) {
      declarators.add(_declarator(_identifier()));
    }
    return declarators;
  }

  Declarator _declarator(Token name) {
    final dimensions = _dimensions();
    final initializer = _accept('=') ? _initializer() : null;
    return Declarator(
      name,
      _previous,
      name: name,
      dimensions: dimensions,
      initializer: initializer,
    );
  }

  Expression _initializer() {
    if (!_peek().isPunctuation('{')) return _assignment();
    final first = _advance();
    final elements = <Expression>[];
    while (!_peek().isPunctuation('}') && !_atEnd) {
      elements.add(_initializer());
      if (!_accept(',')) break;
    }
    _expect('}');
    return InitializerList(first, _previous, elements);
  }

  // Statements.

  Block _block() {
    final first = _expect('{');
    final statements = <Statement>[];
    while (!_peek().isPunctuation('}') && !_atEnd) {
      statements.add(_statementOrError());
    }
    _expect('}');
    return Block(first, _previous, statements);
  }

  Statement _statementOrError() {
    final start = _i;
    try {
      return _statement();
    } on _ParseError catch (error) {
      _report(error);
      _i = start;
      _skipStatement();
      if (_i == start) _i++;
      return ErrorStatement(tokens[start], _previous, error.message);
    }
  }

  Statement _statement() {
    final first = _peek();
    if (first.isPunctuation('{')) return _block();
    if (_accept(';')) return EmptyStatement(first, first);
    if (first.kind == TokenKind.identifier) {
      switch (first.text) {
        case 'if':
          _i++;
          _expect('(');
          final condition = _expression();
          _expect(')');
          final then = _statement();
          final otherwise = _acceptWord('else') ? _statement() : null;
          return IfStatement(
            first,
            _previous,
            condition: condition,
            then: then,
            otherwise: otherwise,
          );
        case 'for':
          _i++;
          _expect('(');
          final Statement? initializer;
          if (_accept(';')) {
            initializer = null;
          } else if (_isDeclarationStart()) {
            initializer = _declarationStatement();
          } else {
            final expression = _expression();
            _expect(';');
            initializer = ExpressionStatement(
              expression.first,
              _previous,
              expression,
            );
          }
          final condition = _peek().isPunctuation(';') ? null : _expression();
          _expect(';');
          final step = _peek().isPunctuation(')') ? null : _expression();
          _expect(')');
          final body = _statement();
          return ForStatement(
            first,
            _previous,
            initializer: initializer,
            condition: condition,
            step: step,
            body: body,
          );
        case 'while':
          _i++;
          _expect('(');
          final condition = _expression();
          _expect(')');
          final body = _statement();
          return WhileStatement(
            first,
            _previous,
            condition: condition,
            body: body,
          );
        case 'do':
          _i++;
          final body = _statement();
          _expectWord('while');
          _expect('(');
          final condition = _expression();
          _expect(')');
          _expect(';');
          return DoStatement(
            first,
            _previous,
            body: body,
            condition: condition,
          );
        case 'switch':
          _i++;
          _expect('(');
          final value = _expression();
          _expect(')');
          final body = _block();
          return SwitchStatement(first, _previous, value: value, body: body);
        case 'case':
          _i++;
          final value = _expression();
          _expect(':');
          return CaseLabel(first, _previous, value);
        case 'default':
          _i++;
          _expect(':');
          return CaseLabel(first, _previous, null);
        case 'return':
          _i++;
          final value = _peek().isPunctuation(';') ? null : _expression();
          _expect(';');
          return ReturnStatement(first, _previous, value);
        case 'break' || 'continue' || 'discard':
          _i++;
          _expect(';');
          return JumpStatement(first, _previous);
        case 'precision':
          _skipPast(';');
          return EmptyStatement(first, _previous);
      }
    }
    if (_isDeclarationStart()) return _declarationStatement();
    final expression = _expression();
    _expect(';');
    return ExpressionStatement(first, _previous, expression);
  }

  /// Whether a declaration starts here: a qualifier, `struct`, or a type name
  /// (with optional `[...]`) followed by a declared name.
  bool _isDeclarationStart() {
    final token = _peek();
    if (token.kind != TokenKind.identifier) return false;
    if (token.text == 'struct' || _qualifierWords.contains(token.text)) {
      return true;
    }
    var k = 1;
    while (_peek(k).isPunctuation('[')) {
      var depth = 0;
      do {
        if (_peek(k).isPunctuation('[')) depth++;
        if (_peek(k).isPunctuation(']')) depth--;
        k++;
      } while (depth > 0 && _i + k < tokens.length);
    }
    return _peek(k).kind == TokenKind.identifier;
  }

  VariableDeclaration _declarationStatement() {
    final first = _peek();
    final qualifiers = _qualifiers();
    final type = _typeSpec();
    final declarators = _peek().isPunctuation(';')
        ? const <Declarator>[]
        : _declarators(_identifier());
    _expect(';');
    return VariableDeclaration(
      first,
      _previous,
      qualifiers: qualifiers,
      type: type,
      declarators: declarators,
    );
  }

  // Expressions.

  Expression _expression() {
    final first = _assignment();
    if (!_peek().isPunctuation(',')) return first;
    final expressions = [first];
    while (_accept(',')) {
      expressions.add(_assignment());
    }
    return SequenceExpression(expressions);
  }

  Expression _assignment() {
    final target = _conditional();
    final operator = _peek();
    if (operator.kind == TokenKind.punctuation &&
        _assignmentOperators.contains(operator.text)) {
      _i++;
      return AssignmentExpression(target, operator, _assignment());
    }
    return target;
  }

  Expression _conditional() {
    final condition = _binary(1);
    if (!_accept('?')) return condition;
    final then = _expression();
    _expect(':');
    return ConditionalExpression(condition, then, _assignment());
  }

  Expression _binary(int minimum) {
    var left = _unary();
    while (true) {
      final operator = _peek();
      final precedence = operator.kind == TokenKind.punctuation
          ? _binaryPrecedence[operator.text]
          : null;
      if (precedence == null || precedence < minimum) return left;
      _i++;
      left = BinaryExpression(left, operator, _binary(precedence + 1));
    }
  }

  Expression _unary() {
    final operator = _peek();
    if (operator.kind == TokenKind.punctuation &&
        _prefixOperators.contains(operator.text)) {
      _i++;
      final operand = _unary();
      return UnaryExpression(
        operator,
        operand.last,
        operator: operator,
        operand: operand,
        isPostfix: false,
      );
    }
    return _postfix(_primary());
  }

  Expression _postfix(Expression expression) {
    var result = expression;
    while (true) {
      final token = _peek();
      if (_accept('[')) {
        final index = _expression();
        _expect(']');
        result = IndexExpression(
          result.first,
          _previous,
          target: result,
          index: index,
        );
      } else if (_accept('.')) {
        result = FieldExpression(result, _identifier(what: 'a field name'));
      } else if (token.isPunctuation('++') || token.isPunctuation('--')) {
        _i++;
        result = UnaryExpression(
          result.first,
          token,
          operator: token,
          operand: result,
          isPostfix: true,
        );
      } else {
        return result;
      }
    }
  }

  Expression _primary() {
    final token = _peek();
    switch (token.kind) {
      case TokenKind.intLiteral || TokenKind.floatLiteral:
        _i++;
        return LiteralExpression(token);
      case TokenKind.identifier:
        _i++;
        if (token.text == 'true' || token.text == 'false') {
          return LiteralExpression(token);
        }
        if (_peek().isPunctuation('[') && _arrayConstructorFollows()) {
          _dimensions();
        }
        if (_peek().isPunctuation('(')) return _call(token);
        return NameExpression(token);
      case TokenKind.punctuation when token.text == '(':
        _i++;
        final inner = _expression();
        _expect(')');
        return inner;
      default:
        throw _ParseError(
          token == _eof
              ? 'Expected an expression at the end of the file.'
              : 'Expected an expression, found "${token.text}".',
          token,
        );
    }
  }

  /// Whether `[...]` at the current token is followed by `(`, as in
  /// `float[2](a, b)`.
  bool _arrayConstructorFollows() {
    var k = 0;
    var depth = 0;
    do {
      if (_peek(k).isPunctuation('[')) depth++;
      if (_peek(k).isPunctuation(']')) depth--;
      k++;
    } while ((depth > 0 || _peek(k).isPunctuation('[')) &&
        _i + k < tokens.length);
    return _peek(k).isPunctuation('(');
  }

  CallExpression _call(Token callee) {
    _expect('(');
    final arguments = <Expression>[];
    if (_peek().isWord('void') && _peek(1).isPunctuation(')')) _i++;
    if (!_peek().isPunctuation(')')) {
      do {
        arguments.add(_assignment());
      } while (_accept(','));
    }
    _expect(')');
    return CallExpression(
      callee,
      _previous,
      callee: callee,
      arguments: arguments,
    );
  }

  // Token helpers.

  bool get _atEnd => _i >= tokens.length;

  Token _peek([int ahead = 0]) =>
      _i + ahead < tokens.length ? tokens[_i + ahead] : _eof;

  Token get _previous => _i > 0 ? tokens[_i - 1] : _eof;

  Token _advance() {
    final token = _peek();
    if (!_atEnd) _i++;
    return token;
  }

  bool _accept(String punctuation) {
    if (!_peek().isPunctuation(punctuation)) return false;
    _i++;
    return true;
  }

  bool _acceptWord(String word) {
    if (!_peek().isWord(word)) return false;
    _i++;
    return true;
  }

  Token _expect(String punctuation) {
    final token = _peek();
    if (!token.isPunctuation(punctuation)) {
      throw _ParseError(
        'Expected "$punctuation", found ${_describe(token)}.',
        token,
      );
    }
    _i++;
    return token;
  }

  void _expectWord(String word) {
    final token = _peek();
    if (!token.isWord(word)) {
      throw _ParseError('Expected "$word", found ${_describe(token)}.', token);
    }
    _i++;
  }

  Token _identifier({String what = 'a name'}) {
    final token = _peek();
    if (token.kind != TokenKind.identifier) {
      throw _ParseError('Expected $what, found ${_describe(token)}.', token);
    }
    _i++;
    return token;
  }

  String _describe(Token token) =>
      token == _eof ? 'the end of the file' : '"${token.text}"';

  /// Skips a balanced `(...)`, `[...]` or `{...}` starting at the current
  /// token.
  void _skipBalanced() {
    var depth = 0;
    do {
      final token = _advance();
      if (token.kind != TokenKind.punctuation) continue;
      switch (token.text) {
        case '(' || '[' || '{':
          depth++;
        case ')' || ']' || '}':
          depth--;
      }
    } while (depth > 0 && !_atEnd);
  }

  void _skipPast(String punctuation) {
    while (!_atEnd && !_advance().isPunctuation(punctuation)) {}
  }

  /// Skips the rest of a statement: through a `;` or a balanced `{...}` at
  /// depth 0, stopping before a `}` that closes the enclosing block.
  void _skipStatement() {
    var depth = 0;
    while (!_atEnd) {
      final token = _peek();
      if (token.kind == TokenKind.punctuation) {
        switch (token.text) {
          case '(' || '[' || '{':
            depth++;
          case ')' || ']' || '}':
            if (depth == 0) return;
            depth--;
            if (depth == 0 && token.text == '}') {
              _i++;
              return;
            }
          case ';' when depth == 0:
            _i++;
            return;
        }
      }
      _i++;
    }
  }

  /// Skips from [start] to the end of a global declaration: through a `;` at
  /// depth 0 or a balanced `{...}` (and a `;` right after it).
  void _skipDeclaration(int start) {
    _i = start;
    var depth = 0;
    while (!_atEnd) {
      final token = _advance();
      if (token.isPunctuation('{')) {
        depth++;
      } else if (token.isPunctuation('}')) {
        depth--;
        if (depth <= 0) {
          _accept(';');
          return;
        }
      } else if (token.isPunctuation(';') && depth == 0) {
        return;
      }
    }
  }

  void _report(_ParseError error) {
    final token = error.token;
    diagnostics.add(
      Diagnostic(
        DiagnosticSeverity.error,
        error.message,
        span: source.span(token.offset, token.end),
      ),
    );
  }
}

final class _ParseError implements Exception {
  _ParseError(this.message, this.token);

  final String message;
  final Token token;
}
