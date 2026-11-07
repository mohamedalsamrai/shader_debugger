/// Splits GLSL source into [Token]s.
///
/// Comments and whitespace are dropped, but the tokens remember whether a
/// newline or a space came before them, which is what the preprocessor needs.
/// Preprocessor directives are tokenized like any other line.
library;

import 'token.dart';

/// A problem found while tokenizing, at `[offset, end)`.
typedef LexError = ({int offset, int end, String message});

/// The tokens of [text], and the problems found.
({List<Token> tokens, List<LexError> errors}) tokenize(String text) {
  final lexer = _Lexer(text)..run();
  return (tokens: lexer.tokens, errors: lexer.errors);
}

/// Punctuators, longest first, so the longest match wins.
const _punctuators = [
  '<<=', '>>=', //
  '++', '--', '<<', '>>', '<=', '>=', '==', '!=', '&&', '||', '^^', //
  '+=', '-=', '*=', '/=', '%=', '&=', '^=', '|=', '##', //
  '(', ')', '[', ']', '{', '}', '.', ',', ':', ';', '?', //
  '+', '-', '*', '/', '%', '<', '>', '=', '!', '~', '&', '|', '^', '#',
];

final class _Lexer {
  _Lexer(this.text);

  final String text;
  final tokens = <Token>[];
  final errors = <LexError>[];

  int _i = 0;
  bool _newline = true;
  bool _space = true;

  int _at(int i) => i < text.length ? text.codeUnitAt(i) : -1;

  void run() {
    while (true) {
      _skipTrivia();
      if (_i >= text.length) return;
      final start = _i;
      final c = _at(_i);
      final TokenKind kind;
      if (_isIdentifierStart(c)) {
        while (_isIdentifierPart(_at(_i))) {
          _i++;
        }
        kind = TokenKind.identifier;
      } else if (_isDigit(c) || (c == _dot && _isDigit(_at(_i + 1)))) {
        kind = _number();
      } else if (c == _quote) {
        kind = _string();
      } else {
        final punctuator = _punctuators.firstWhere(
          (p) => text.startsWith(p, _i),
          orElse: () => '',
        );
        if (punctuator.isEmpty) {
          _i++;
          errors.add((offset: start, end: _i, message: 'Unexpected character "${text[start]}".'));
          kind = TokenKind.unknown;
        } else {
          _i += punctuator.length;
          kind = TokenKind.punctuation;
        }
      }
      tokens.add(
        Token(
          kind,
          text.substring(start, _i),
          start,
          _i,
          firstOnLine: _newline,
          spaceBefore: _space,
        ),
      );
      _newline = false;
      _space = false;
    }
  }

  void _skipTrivia() {
    while (_i < text.length) {
      final c = _at(_i);
      if (c == _newlineChar) {
        _newline = true;
        _space = true;
        _i++;
      } else if (c == _spaceChar || c == _tab || c == _cr || c == 0x0B || c == 0x0C) {
        _space = true;
        _i++;
      } else if (c == _backslash && _at(_i + 1) == _newlineChar) {
        _i += 2; // Line continuation.
      } else if (c == _backslash && _at(_i + 1) == _cr && _at(_i + 2) == _newlineChar) {
        _i += 3;
      } else if (c == _slash && _at(_i + 1) == _slash) {
        final newline = text.indexOf('\n', _i);
        _i = newline < 0 ? text.length : newline;
        _space = true;
      } else if (c == _slash && _at(_i + 1) == _star) {
        final close = text.indexOf('*/', _i + 2);
        if (close < 0) {
          errors.add((offset: _i, end: text.length, message: 'Unterminated comment.'));
          _i = text.length;
        } else {
          _i = close + 2;
        }
        _space = true;
      } else {
        return;
      }
    }
  }

  TokenKind _number() {
    if (_at(_i) == _zero && (_at(_i + 1) | 0x20) == _x) {
      _i += 2;
      while (_isHexDigit(_at(_i))) {
        _i++;
      }
      if ((_at(_i) | 0x20) == _u) _i++;
      return TokenKind.intLiteral;
    }
    var isFloat = false;
    while (_isDigit(_at(_i))) {
      _i++;
    }
    if (_at(_i) == _dot) {
      isFloat = true;
      _i++;
      while (_isDigit(_at(_i))) {
        _i++;
      }
    }
    if ((_at(_i) | 0x20) == _e) {
      final sign = _at(_i + 1) == _plus || _at(_i + 1) == _minus ? 1 : 0;
      if (_isDigit(_at(_i + 1 + sign))) {
        isFloat = true;
        _i += 1 + sign;
        while (_isDigit(_at(_i))) {
          _i++;
        }
      }
    }
    final suffix = _at(_i) | 0x20;
    if (suffix == _f) {
      _i++;
      return TokenKind.floatLiteral;
    }
    if (suffix == _l && (_at(_i + 1) | 0x20) == _f) {
      _i += 2;
      return TokenKind.floatLiteral;
    }
    if (!isFloat && suffix == _u) _i++;
    return isFloat ? TokenKind.floatLiteral : TokenKind.intLiteral;
  }

  /// A `"..."` header name, which only `#include` uses.
  TokenKind _string() {
    final start = _i++;
    while (_i < text.length && _at(_i) != _quote && _at(_i) != _newlineChar) {
      _i++;
    }
    if (_at(_i) == _quote) {
      _i++;
    } else {
      errors.add((offset: start, end: _i, message: 'Unterminated string.'));
    }
    return TokenKind.string;
  }
}

const _newlineChar = 0x0A;
const _cr = 0x0D;
const _tab = 0x09;
const _spaceChar = 0x20;
const _backslash = 0x5C;
const _slash = 0x2F;
const _star = 0x2A;
const _dot = 0x2E;
const _quote = 0x22;
const _plus = 0x2B;
const _minus = 0x2D;
const _zero = 0x30;
const _e = 0x65;
const _f = 0x66;
const _l = 0x6C;
const _u = 0x75;
const _x = 0x78;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isHexDigit(int c) => _isDigit(c) || ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x66);

bool _isIdentifierStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;

bool _isIdentifierPart(int c) => _isIdentifierStart(c) || _isDigit(c);
