import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Draws `shaders/gradient.frag` full screen.
///
/// Run it in debug mode, open DevTools and look for the shader_debugger tab.
/// The app depends on package:shader_debugger, which is what makes DevTools
/// offer the extension.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final program = await ui.FragmentProgram.fromAsset('shaders/gradient.frag');
  runApp(ExampleApp(program: program));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.program});

  final ui.FragmentProgram program;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shader Debugger example',
      home: Scaffold(body: GradientView(program: program)),
    );
  }
}

class GradientView extends StatefulWidget {
  const GradientView({super.key, required this.program});

  final ui.FragmentProgram program;

  @override
  State<GradientView> createState() => _GradientViewState();
}

class _GradientViewState extends State<GradientView> {
  // Created once. On hot reload the engine swaps the recompiled program in
  // place and rebinds named uniform slots, so this shader stays valid.
  late final ui.FragmentShader _shader = widget.program.fragmentShader();

  @override
  void dispose() {
    _shader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _GradientPainter(_shader),
      child: const SizedBox.expand(),
    );
  }
}

class _GradientPainter extends CustomPainter {
  _GradientPainter(this.shader)
    : _size = shader.getUniformVec2('uSize'),
      _colorA = shader.getUniformVec4('uA'),
      _colorB = shader.getUniformVec4('uB');

  final ui.FragmentShader shader;
  final ui.UniformVec2Slot _size;
  final ui.UniformVec4Slot _colorA;
  final ui.UniformVec4Slot _colorB;

  @override
  void paint(Canvas canvas, Size size) {
    // Uniforms are set on every paint: a hot reload that changes the shader
    // resets its uniform values to zero.
    _size.set(size.width, size.height);
    _colorA.set(0.10, 0.20, 0.90, 1.0);
    _colorB.set(1.00, 0.60, 0.10, 1.0);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_GradientPainter oldDelegate) =>
      oldDelegate.shader != shader;
}
