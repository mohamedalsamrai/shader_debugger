import 'package:flutter/material.dart';
import 'package:shader_debugger/shader_debugger.dart';

/// Draws `shaders/gradient.frag` full screen through a [DebugShader].
///
/// Run it in debug mode, open DevTools and find the shader_debugger tab.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final shader = await DebugShader.fromAsset('shaders/gradient.frag');
  runApp(ExampleApp(shader: shader));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.shader});

  final DebugShader shader;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shader Debugger example',
      home: Scaffold(
        body: CustomPaint(
          painter: GradientPainter(shader),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class GradientPainter extends CustomPainter {
  GradientPainter(this.shader)
    : _size = shader.getUniformVec2('uSize'),
      _colorA = shader.getUniformVec4('uA'),
      _colorB = shader.getUniformVec4('uB');

  final DebugShader shader;
  final DebugUniformVec2 _size;
  final DebugUniformVec4 _colorA;
  final DebugUniformVec4 _colorB;

  @override
  void paint(Canvas canvas, Size size) {
    _size.set(size.width, size.height);
    _colorA.set(0.10, 0.20, 0.90, 1.0);
    _colorB.set(1.00, 0.60, 0.10, 1.0);
    // Read shader.shader after setting the uniforms: while the debugger shows
    // a heatmap it is the probe, with these uniforms copied onto it.
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader.shader);
  }

  @override
  bool shouldRepaint(GradientPainter oldDelegate) =>
      oldDelegate.shader != shader;
}
