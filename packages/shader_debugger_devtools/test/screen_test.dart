import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shader_debugger_devtools/src/controller.dart';
import 'package:shader_debugger_devtools/src/ports.dart';
import 'package:shader_debugger_devtools/src/screen.dart';

import 'fakes.dart';

void main() {
  late FakeWorkspace workspace;
  late FakeApp app;

  Future<ShaderDebuggerController> pumpScreen(
    WidgetTester tester, {
    double height = 800,
  }) async {
    tester.view.physicalSize = Size(1200, height);
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

  testWidgets('picks a part of a composite value and shows it', (tester) async {
    workspace.files[gradientFile] = compositeSource;
    app.runtime.value = true;
    // Tall enough for the side panel to show the status under its buttons.
    await pumpScreen(tester, height: 1100);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('  lights[1] = Light(spin * uv, vec3(weights[2]));'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Part'), findsOneWidget);
    expect(find.text('lights[1].position · vec2'), findsOneWidget);

    // Pick the color field instead.
    await tester.tap(find.text('.position'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('.color').last);
    await tester.pumpAndSettle();
    expect(find.text('lights[1].color · vec3'), findsOneWidget);

    await tester.tap(find.text('Show heatmap'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Showing lights[1].color (vec3, rgb)'),
      findsOneWidget,
    );

    // A matrix: pick its second column.
    await tester.tap(find.text('spin'));
    await tester.pumpAndSettle();
    expect(find.text('spin[0] · vec2'), findsOneWidget);
    await tester.tap(find.text('[0]'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('[1]').last);
    await tester.pumpAndSettle();
    expect(find.text('spin[1] · vec2'), findsOneWidget);
    expect(find.textContaining('Showing spin[1] (vec2, rg)'), findsOneWidget);
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
