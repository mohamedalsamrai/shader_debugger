import 'package:shader_debugger_core/src/parse/lexer.dart';
import 'package:shader_debugger_core/src/parse/token.dart';
import 'package:test/test.dart';

List<String> texts(String source) => [
  for (final token in tokenize(source).tokens) token.text,
];

TokenKind kindOf(String source) => tokenize(source).tokens.single.kind;

void main() {
  test('splits a statement into tokens with their offsets', () {
    const source = 'vec2 uv = FlutterFragCoord().xy / uSize;';
    final tokens = tokenize(source).tokens;
    expect(texts(source), [
      'vec2', 'uv', '=', 'FlutterFragCoord', '(', ')', '.', 'xy', '/', //
      'uSize', ';',
    ]);
    for (final token in tokens) {
      expect(source.substring(token.offset, token.end), token.text);
    }
  });

  test('tells integer and float literals apart', () {
    for (final number in ['1', '017', '0x1F', '0X1fu', '7u']) {
      expect(kindOf(number), TokenKind.intLiteral, reason: number);
    }
    for (final number in [
      '1.0',
      '.5',
      '1.',
      '1e3',
      '1.5e-3',
      '2E+2',
      '2.0f',
      '1.0lf',
    ]) {
      expect(kindOf(number), TokenKind.floatLiteral, reason: number);
    }
    expect(texts('1.5e-3+x'), ['1.5e-3', '+', 'x']);
    expect(texts('2.xy'), ['2.', 'xy'], reason: 'a swizzle after a float');
  });

  test('takes the longest operator', () {
    expect(texts('a<<=b'), ['a', '<<=', 'b']);
    expect(texts('a++ + ++b'), ['a', '++', '+', '++', 'b']);
    expect(texts('a^^b'), ['a', '^^', 'b']);
    expect(texts('x##y'), ['x', '##', 'y']);
  });

  test('drops comments but remembers newlines and spaces', () {
    final tokens = tokenize('a // one\nb /* two\n */ c\n  #d').tokens;
    expect([for (final t in tokens) t.text], ['a', 'b', 'c', '#', 'd']);
    expect(
      [for (final t in tokens) t.firstOnLine],
      [true, true, false, true, false],
    );
    expect(tokens[2].spaceBefore, isTrue);
  });

  test('a line continuation does not start a new line', () {
    final tokens = tokenize('#define A 1 \\\n  + 2\nb').tokens;
    expect(tokens.firstWhere((t) => t.text == '+').firstOnLine, isFalse);
    expect(tokens.last.firstOnLine, isTrue);
  });

  test('sees whether ( follows a macro name directly', () {
    final tokens = tokenize('F(x) G (x)').tokens;
    expect(tokens[1].spaceBefore, isFalse);
    expect(tokens[5].spaceBefore, isTrue);
  });

  test('reads a quoted include name as one token', () {
    expect(
      tokenize('#include "noise.glsl"').tokens.last.kind,
      TokenKind.string,
    );
  });

  test('reports characters GLSL does not use, and unterminated comments', () {
    final result = tokenize('a @ b /* open');
    expect(texts('a @ b'), ['a', '@', 'b']);
    expect(
      [for (final e in result.errors) e.message],
      ['Unexpected character "@".', 'Unterminated comment.'],
    );
  });
}
