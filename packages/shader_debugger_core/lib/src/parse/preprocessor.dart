/// The GLSL preprocessor: conditionals, macros and includes.
///
/// It runs on tokens, so every token it outputs keeps an offset in the
/// analyzed file: its own for source tokens, the macro use's for macro
/// output, and the `#include` line's for included tokens. That is the source
/// map back to the original lines (design doc §5, step 1).
library;

import 'package:source_span/source_span.dart';

import '../model/shader_analysis.dart';
import 'lexer.dart';
import 'token.dart';

/// Returns the text of the file an `#include` names, or null if it cannot.
///
/// [path] is the name between `<>` or `""`. The core reads no files itself.
typedef IncludeResolver = String? Function(String path);

/// The include every Flutter fragment shader starts with.
const runtimeEffectInclude = 'flutter/runtime_effect.glsl';

/// What the analyzer reads in place of [runtimeEffectInclude]. The engine's
/// file defines `FlutterFragCoord` per backend; every version returns the
/// fragment's local coordinate as a `vec2`.
const runtimeEffectStub = 'vec2 FlutterFragCoord();\n';

/// Macros the analyzer assumes, as impellerc compiling for Impeller does.
const _predefined = {'IMPELLER_GRAPHICS_BACKEND': '1'};

const _maxIncludeDepth = 16;

typedef _Site = ({int offset, int end});

/// Preprocesses one file. Create one per run.
final class Preprocessor {
  Preprocessor(
    this.source, {
    this.resolveInclude,
    Map<String, String> defines = const {},
  }) {
    for (final MapEntry(:key, :value) in {..._predefined, ...defines}.entries) {
      _macros[key] = _Macro(key, null, tokenize(value).tokens);
    }
  }

  final SourceFile source;

  /// Reads included files other than [runtimeEffectInclude].
  final IncludeResolver? resolveInclude;
  final _macros = <String, _Macro>{};

  /// Problems found, in the order they were found.
  final diagnostics = <Diagnostic>[];

  /// The file's tokens after preprocessing.
  List<Token> run() {
    final lexed = tokenize(source.getText(0));
    for (final error in lexed.errors) {
      _report(
        DiagnosticSeverity.error,
        error.message,
        error.offset,
        error.end,
        null,
      );
    }
    return _process(lexed.tokens, site: null, depth: 0);
  }

  /// Processes the tokens of one file. For an included file, [site] is the
  /// `#include` line: output tokens and diagnostics are placed there.
  List<Token> _process(
    List<Token> tokens, {
    required _Site? site,
    required int depth,
  }) {
    final out = <Token>[];
    final pending = <Token>[];
    final conditions = <_Condition>[];

    void flush() {
      if (pending.isEmpty) return;
      final expanded = _expand(pending, const {}, null, site);
      out.addAll(
        site == null
            ? expanded
            : [
                for (final token in expanded)
                  token.relocated(site.offset, site.end, TokenOrigin.include),
              ],
      );
      pending.clear();
    }

    var i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      if (token.isPunctuation('#') && token.firstOnLine) {
        var j = i + 1;
        while (j < tokens.length && !tokens[j].firstOnLine) {
          j++;
        }
        flush();
        final words = tokens.sublist(i + 1, j);
        final at = (offset: token.offset, end: tokens[j - 1].end);
        _directive(words, at, conditions, out, site, depth);
        i = j;
        continue;
      }
      if (conditions.isEmpty || conditions.last.active) pending.add(token);
      i++;
    }
    flush();
    if (conditions.isNotEmpty) {
      final end = tokens.isEmpty ? 0 : tokens.last.end;
      _report(DiagnosticSeverity.warning, 'Missing #endif.', end, end, site);
    }
    return out;
  }

  void _directive(
    List<Token> words,
    _Site at,
    List<_Condition> conditions,
    List<Token> out,
    _Site? site,
    int depth,
  ) {
    if (words.isEmpty) return; // The null directive.
    final active = conditions.isEmpty || conditions.last.active;
    final name = words.first.text;
    final args = words.sublist(1);
    void warn(String message) =>
        _report(DiagnosticSeverity.warning, message, at.offset, at.end, site);

    switch (name) {
      case 'ifdef' || 'ifndef':
        final defined = args.isNotEmpty && _macros.containsKey(args.first.text);
        conditions.add(
          _Condition(active, name == 'ifdef' ? defined : !defined),
        );
      case 'if':
        conditions.add(
          _Condition(active, active && _evaluate(args, at, site) != 0),
        );
      case 'elif':
        if (conditions.isEmpty) return warn('#elif without #if.');
        conditions.last.elseIf(() => _evaluate(args, at, site) != 0);
      case 'else':
        if (conditions.isEmpty) return warn('#else without #if.');
        conditions.last.otherwise();
      case 'endif':
        if (conditions.isEmpty) return warn('#endif without #if.');
        conditions.removeLast();
      case _ when !active:
        return;
      case 'define':
        _define(args, at, site);
      case 'undef':
        if (args.isNotEmpty) _macros.remove(args.first.text);
      case 'include':
        out.addAll(_include(args, at, site, depth));
      case 'error':
        _report(
          DiagnosticSeverity.error,
          '#error ${args.map((token) => token.text).join(' ')}',
          at.offset,
          at.end,
          site,
        );
      case 'version' || 'extension' || 'pragma' || 'line':
        return;
      default:
        warn('Unknown directive #$name.');
    }
  }

  void _define(List<Token> args, _Site at, _Site? site) {
    if (args.isEmpty || args.first.kind != TokenKind.identifier) {
      _report(
        DiagnosticSeverity.warning,
        '#define needs a name.',
        at.offset,
        at.end,
        site,
      );
      return;
    }
    List<String>? params;
    var bodyStart = 1;
    if (args.length > 1 && args[1].isPunctuation('(') && !args[1].spaceBefore) {
      params = [];
      var k = 2;
      while (k < args.length && !args[k].isPunctuation(')')) {
        if (args[k].kind == TokenKind.identifier) params.add(args[k].text);
        k++;
      }
      if (k == args.length) {
        _report(
          DiagnosticSeverity.warning,
          'Unterminated macro parameter list.',
          at.offset,
          at.end,
          site,
        );
        return;
      }
      bodyStart = k + 1;
    }
    final name = args.first.text;
    _macros[name] = _Macro(name, params, args.sublist(bodyStart));
  }

  List<Token> _include(List<Token> args, _Site at, _Site? site, int depth) {
    final path = _headerName(args);
    void warn(String message) =>
        _report(DiagnosticSeverity.warning, message, at.offset, at.end, site);
    if (path == null) {
      warn('Malformed #include.');
      return const [];
    }
    final text = path == runtimeEffectInclude
        ? runtimeEffectStub
        : resolveInclude?.call(path);
    if (text == null) {
      warn("Cannot read '$path'; what it declares is unknown to the debugger.");
      return const [];
    }
    if (depth >= _maxIncludeDepth) {
      warn('Includes nested deeper than $_maxIncludeDepth levels.');
      return const [];
    }
    return _process(tokenize(text).tokens, site: site ?? at, depth: depth + 1);
  }

  static String? _headerName(List<Token> args) {
    if (args.length == 1 && args.single.kind == TokenKind.string) {
      final text = args.single.text;
      return text.length >= 2 ? text.substring(1, text.length - 1) : null;
    }
    if (args.length >= 3 &&
        args.first.isPunctuation('<') &&
        args.last.isPunctuation('>')) {
      return args.sublist(1, args.length - 1).map((token) => token.text).join();
    }
    return null;
  }

  /// Expands the macros in [input]. [use] is the outermost macro use being
  /// expanded, where output tokens are placed; null at the top level.
  List<Token> _expand(
    List<Token> input,
    Set<String> disabled,
    _Site? use,
    _Site? site,
  ) {
    final out = <Token>[];
    Token place(Token token) => use == null
        ? token
        : token.relocated(use.offset, use.end, TokenOrigin.macro);

    var i = 0;
    while (i < input.length) {
      final token = input[i];
      final macro =
          token.kind == TokenKind.identifier && !disabled.contains(token.text)
          ? _macros[token.text]
          : null;
      final params = macro?.params;
      if (macro == null) {
        out.add(place(token));
        i++;
        continue;
      }
      if (params == null) {
        final here = use ?? (offset: token.offset, end: token.end);
        out.addAll(_expand(macro.body, {...disabled, macro.name}, here, site));
        i++;
        continue;
      }
      // A function-like macro name not followed by '(' is an ordinary name.
      if (i + 1 >= input.length || !input[i + 1].isPunctuation('(')) {
        out.add(place(token));
        i++;
        continue;
      }
      final args = <List<Token>>[[]];
      var nesting = 0;
      var close = i + 2;
      for (; close < input.length; close++) {
        final t = input[close];
        if (t.isPunctuation(')') && nesting == 0) break;
        if (t.isPunctuation(',') && nesting == 0) {
          args.add([]);
          continue;
        }
        if (t.isPunctuation('(')) nesting++;
        if (t.isPunctuation(')')) nesting--;
        args.last.add(t);
      }
      if (close >= input.length) {
        _report(
          DiagnosticSeverity.warning,
          'Unterminated use of macro ${macro.name}.',
          token.offset,
          token.end,
          site,
        );
        out.add(place(token));
        i++;
        continue;
      }
      if (params.isEmpty && args.length == 1 && args.single.isEmpty) {
        args.clear();
      }
      if (args.length != params.length) {
        _report(
          DiagnosticSeverity.warning,
          'Macro ${macro.name} takes ${params.length} argument(s), not ${args.length}.',
          token.offset,
          input[close].end,
          site,
        );
        out.addAll(input.sublist(i, close + 1).map(place));
        i = close + 1;
        continue;
      }
      final here = use ?? (offset: token.offset, end: input[close].end);
      final expandedArgs = [
        for (final arg in args) _expand(arg, disabled, null, site),
      ];
      final body = _substitute(macro, args, expandedArgs);
      out.addAll(_expand(body, {...disabled, macro.name}, here, site));
      i = close + 1;
    }
    return out;
  }

  /// [macro]'s body with its parameters replaced. Operands of `##` take the
  /// unexpanded argument, as in C.
  static List<Token> _substitute(
    _Macro macro,
    List<List<Token>> raw,
    List<List<Token>> expanded,
  ) {
    final params = macro.params!;
    final body = macro.body;
    int param(Token token) =>
        token.kind == TokenKind.identifier ? params.indexOf(token.text) : -1;

    final out = <Token>[];
    for (var b = 0; b < body.length; b++) {
      final token = body[b];
      if (token.isPunctuation('##') && out.isNotEmpty && b + 1 < body.length) {
        final next = body[++b];
        final right = param(next) >= 0 ? raw[param(next)] : [next];
        if (right.isEmpty) continue;
        final left = out.removeLast();
        final pasted = tokenize(left.text + right.first.text).tokens;
        if (pasted.length == 1) {
          out.add(
            Token(
              pasted.single.kind,
              pasted.single.text,
              left.offset,
              left.end,
            ),
          );
        } else {
          out
            ..add(left)
            ..add(right.first);
        }
        out.addAll(right.skip(1));
        continue;
      }
      final index = param(token);
      if (index < 0) {
        out.add(token);
      } else {
        final pastedNext =
            b + 1 < body.length && body[b + 1].isPunctuation('##');
        out.addAll(pastedNext ? raw[index] : expanded[index]);
      }
    }
    return out;
  }

  int _evaluate(List<Token> tokens, _Site at, _Site? site) {
    // `defined X` and `defined(X)` are resolved before macros expand.
    final resolved = <Token>[];
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (!token.isWord('defined')) {
        resolved.add(token);
        continue;
      }
      final parenthesized =
          i + 1 < tokens.length && tokens[i + 1].isPunctuation('(');
      final nameIndex = parenthesized ? i + 2 : i + 1;
      final name = nameIndex < tokens.length ? tokens[nameIndex].text : '';
      i = parenthesized ? nameIndex + 1 : nameIndex;
      resolved.add(
        Token(
          TokenKind.intLiteral,
          _macros.containsKey(name) ? '1' : '0',
          token.offset,
          token.end,
        ),
      );
    }
    final evaluator = _ConditionEvaluator(
      _expand(resolved, const {}, null, site),
    );
    final value = evaluator.evaluate();
    if (evaluator.error case final error?) {
      _report(
        DiagnosticSeverity.warning,
        'In #if: $error',
        at.offset,
        at.end,
        site,
      );
    }
    return value;
  }

  void _report(
    DiagnosticSeverity severity,
    String message,
    int start,
    int end,
    _Site? site,
  ) {
    final span = site == null
        ? source.span(start, end)
        : source.span(site.offset, site.end);
    diagnostics.add(Diagnostic(severity, message, span: span));
  }
}

final class _Macro {
  _Macro(this.name, this.params, this.body);

  final String name;

  /// The parameter names of a function-like macro; null for an object-like
  /// one.
  final List<String>? params;

  final List<Token> body;
}

/// One `#if` … `#endif` group.
final class _Condition {
  _Condition(this.parentActive, bool value)
    : active = parentActive && value,
      _taken = value;

  final bool parentActive;

  /// Whether the current branch is being compiled.
  bool active;

  /// Whether some branch of the group has been taken.
  bool _taken;

  void elseIf(bool Function() test) {
    if (!parentActive || _taken) {
      active = false;
      return;
    }
    active = _taken = test();
  }

  void otherwise() {
    active = parentActive && !_taken;
    _taken = true;
  }
}

/// Evaluates a `#if` expression on integers. Unknown names are 0, as in C.
final class _ConditionEvaluator {
  _ConditionEvaluator(this.tokens);

  final List<Token> tokens;
  int _i = 0;
  String? error;

  static const _precedence = {
    '||': 1, '&&': 2, '|': 3, '^': 4, '&': 5, //
    '==': 6, '!=': 6, '<': 7, '>': 7, '<=': 7, '>=': 7, //
    '<<': 8, '>>': 8, '+': 9, '-': 9, '*': 10, '/': 10, '%': 10,
  };

  int evaluate() {
    try {
      final value = _ternary();
      if (_i < tokens.length) {
        throw FormatException('unexpected "${tokens[_i].text}".');
      }
      return value;
    } on FormatException catch (e) {
      error = e.message;
      return 0;
    }
  }

  Token _next() => _i < tokens.length
      ? tokens[_i++]
      : throw const FormatException('expression ends early.');

  bool _accept(String punctuation) {
    if (_i < tokens.length && tokens[_i].isPunctuation(punctuation)) {
      _i++;
      return true;
    }
    return false;
  }

  int _ternary() {
    final condition = _binary(1);
    if (!_accept('?')) return condition;
    final then = _ternary();
    if (!_accept(':')) throw const FormatException('expected ":".');
    final otherwise = _ternary();
    return condition != 0 ? then : otherwise;
  }

  int _binary(int minimum) {
    var left = _unary();
    while (_i < tokens.length) {
      final op = tokens[_i];
      final precedence = op.kind == TokenKind.punctuation
          ? _precedence[op.text]
          : null;
      if (precedence == null || precedence < minimum) break;
      _i++;
      final right = _binary(precedence + 1);
      left = switch (op.text) {
        '||' => (left != 0 || right != 0) ? 1 : 0,
        '&&' => (left != 0 && right != 0) ? 1 : 0,
        '|' => left | right,
        '^' => left ^ right,
        '&' => left & right,
        '==' => left == right ? 1 : 0,
        '!=' => left != right ? 1 : 0,
        '<' => left < right ? 1 : 0,
        '>' => left > right ? 1 : 0,
        '<=' => left <= right ? 1 : 0,
        '>=' => left >= right ? 1 : 0,
        '<<' => left << right,
        '>>' => left >> right,
        '+' => left + right,
        '-' => left - right,
        '*' => left * right,
        _ when right == 0 => throw const FormatException('division by zero.'),
        '/' => left ~/ right,
        _ => left.remainder(right),
      };
    }
    return left;
  }

  int _unary() {
    final token = _next();
    if (token.isPunctuation('-')) return -_unary();
    if (token.isPunctuation('+')) return _unary();
    if (token.isPunctuation('!')) return _unary() == 0 ? 1 : 0;
    if (token.isPunctuation('~')) return ~_unary();
    if (token.isPunctuation('(')) {
      final value = _ternary();
      if (!_accept(')')) throw const FormatException('expected ")".');
      return value;
    }
    if (token.kind == TokenKind.intLiteral) {
      return parseIntLiteral(token.text) ??
          (throw FormatException('bad number "${token.text}".'));
    }
    if (token.kind == TokenKind.identifier) return token.text == 'true' ? 1 : 0;
    throw FormatException('unexpected "${token.text}".');
  }
}

/// The value of a GLSL integer literal (decimal, octal or hex, with an
/// optional `u` suffix), or null if [text] is not one.
int? parseIntLiteral(String text) {
  var digits = text;
  if (digits.endsWith('u') || digits.endsWith('U')) {
    digits = digits.substring(0, digits.length - 1);
  }
  if (digits.startsWith('0x') || digits.startsWith('0X')) {
    return int.tryParse(digits.substring(2), radix: 16);
  }
  if (digits.length > 1 && digits.startsWith('0')) {
    return int.tryParse(digits.substring(1), radix: 8);
  }
  return int.tryParse(digits);
}
