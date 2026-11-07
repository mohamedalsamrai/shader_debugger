/// GLSL tokens, placed in the analyzed file.
library;

/// The lexical class of a [Token]. Keywords are [identifier]s; the parser
/// tells them apart by text.
enum TokenKind {
  identifier,
  intLiteral,
  floatLiteral,
  string,
  punctuation,
  unknown,
}

/// Where a token came from.
enum TokenOrigin {
  /// Written in the analyzed file, at [Token.offset].
  source,

  /// Produced by a macro expansion. Its offsets are those of the macro use.
  macro,

  /// Read from an included file. Its offsets are those of the `#include`.
  include,
}

/// A token, with offsets into the analyzed (original) file.
final class Token {
  const Token(
    this.kind,
    this.text,
    this.offset,
    this.end, {
    this.origin = TokenOrigin.source,
    this.firstOnLine = false,
    this.spaceBefore = false,
  });

  final TokenKind kind;
  final String text;

  /// Start offset in the analyzed file. For a token that is not from the
  /// source, the start of the macro use or `#include` it came from.
  final int offset;

  /// End offset in the analyzed file; see [offset].
  final int end;

  final TokenOrigin origin;

  /// Whether a newline (outside comments) precedes the token. A `#` that is
  /// first on its line starts a preprocessor directive.
  final bool firstOnLine;

  /// Whether whitespace or a comment precedes the token. `#define F(x)` is a
  /// function-like macro only when no space separates `F` and `(`.
  final bool spaceBefore;

  bool get fromSource => origin == TokenOrigin.source;

  bool isPunctuation(String value) =>
      kind == TokenKind.punctuation && text == value;

  bool isWord(String value) => kind == TokenKind.identifier && text == value;

  /// This token moved to `[offset, end)` with [origin], as when it is
  /// produced by a macro expansion or an include.
  Token relocated(int offset, int end, TokenOrigin origin) =>
      Token(kind, text, offset, end, origin: origin, spaceBefore: spaceBefore);

  @override
  String toString() =>
      '$kind "$text" @$offset${fromSource ? '' : ' (${origin.name})'}';
}
