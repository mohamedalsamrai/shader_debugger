import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_debugger_devtools/src/controller.dart';
import 'package:shader_debugger_devtools/src/ports.dart';
import 'package:shader_debugger_devtools/src/screen.dart';

import 'fakes.dart';

void main() {
  late FakeWorkspace workspace;
  late FakeApp app;

  Future<ShaderDebuggerController> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ShaderDebuggerController(
      app: app,
      workspace: workspace,
      retryDelay: Duration.zero,
    )..start();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ShaderDebuggerScreen(controller: controller)),
      ),
    );
    return controller;
  }

  setUp(() {
    workspace = FakeWorkspace();
    app = FakeApp(workspace);
  });

  testWidgets('connects, picks a line and shows its heatmap', (tester) async {
    await pumpScreen(tester);
    expect(find.text('Waiting for the app'), findsOneWidget);

    app.runtime.value = true;
    await tester.pumpAndSettle();
    expect(find.text(gradientAsset), findsOneWidget);

    await tester.tap(find.text('  float d = length(uv - 0.5);'));
    await tester.pumpAndSettle();
    expect(find.text('Line ${lineOf('float d =') + 1}'), findsOneWidget);
    expect(find.textContaining('float · local · written here'), findsOneWidget);

    await tester.tap(find.text('Show heatmap'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Showing d (float, scalar)'), findsOneWidget);
    expect(app.shown?.asset, gradientAsset);

    await tester.enterText(find.widgetWithText(TextField, 'Max'), '0.6');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(app.shown?.max, 0.6);

    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(app.shown, isNull);
    expect(find.textContaining('Showing'), findsNothing);
  });

  testWidgets('offers the probe to copy when it cannot be written', (
    tester,
  ) async {
    app.runtime.value = true;
    await pumpScreen(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('  vec2 uv = FlutterFragCoord().xy / uSize;'));
    await tester.pumpAndSettle();

    workspace.failWith = WorkspaceError.permissionDenied;
    await tester.tap(find.text('Show heatmap'));
    await tester.pumpAndSettle();
    expect(find.textContaining('paste the probe'), findsOneWidget);
    expect(find.text(probeFile.toFilePath()), findsOneWidget);
    expect(find.text('Copy probe'), findsOneWidget);
    expect(find.text('Check'), findsOneWidget);
  });

  testWidgets('composite values are listed but cannot be picked', (
    tester,
  ) async {
    workspace.files[gradientFile] = gradientSource.replaceFirst(
      '  vec3 col',
      '  mat2 m = mat2(1.0);\n  vec3 col',
    );
    app.runtime.value = true;
    await pumpScreen(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('  vec3 col = mix(uA.rgb, uB.rgb, d);'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('pick a column: not supported yet'),
      findsOneWidget,
    );
  });

  testWidgets('a failed connection can be retried', (tester) async {
    app.info = const AppInfo(
      protocolVersion: 99,
      probeAsset: probeAsset,
      shaders: [],
    );
    app.runtime.value = true;
    final controller = await pumpScreen(tester);
    await tester.pumpAndSettle();
    expect(find.text('Cannot connect to the app'), findsOneWidget);

    app.info = const AppInfo(
      protocolVersion: 1,
      probeAsset: probeAsset,
      shaders: [gradientAsset],
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(controller.connection, AppConnection.ready);
  });
}
