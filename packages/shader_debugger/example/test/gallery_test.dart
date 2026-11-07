// The example app: every shader of the gallery loads, compiles and paints
// through its DebugShader.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_debugger/shader_debugger.dart';
import 'package:shader_debugger_example/main.dart';

void main() {
  testWidgets('the gallery draws every shader through DebugShader', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1700, 1000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shaders = (await tester.runAsync(ExampleShader.loadAll))!;
    addTearDown(() {
      for (final shader in shaders) {
        shader.shader.dispose();
      }
    });
    await tester.pumpWidget(ExampleApp(shaders: shaders));
    await tester.pump();

    expect(shaders.first.asset, 'shaders/gradient.frag');
    for (final shader in shaders) {
      expect(find.text(shader.asset), findsOneWidget);
      final painted = find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter is ShaderPainter &&
            (widget.painter! as ShaderPainter).shader == shader,
      );
      // The debugger finds the shader where its card paints it.
      expect(
        ShaderDebugger.instance.pickAt(
          shader.asset,
          tester.getCenter(painted),
        )['instance'],
        shader.shader.debugId,
        reason: shader.asset,
      );
    }

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(find.byTooltip('Play'), findsOneWidget);
  });
}
