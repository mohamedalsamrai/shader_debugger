import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:shader_debugger/shader_debugger.dart';

/// A gallery of shaders drawn through [DebugShader], each with something to
/// try in the debugger.
///
/// Run it in debug mode, open DevTools and find the shader_debugger tab.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ExampleApp(shaders: await ExampleShader.loadAll()));
}

/// A shader of the gallery: the [DebugShader], what to try with it, and how
/// to set its uniforms for a frame.
class ExampleShader {
  ExampleShader({
    required this.shader,
    required this.hint,
    required this.setUniforms,
  });

  final DebugShader shader;

  /// What to try with it in the debugger.
  final String hint;

  /// Sets this frame's uniforms, for the painted [Size] and the time in
  /// seconds.
  final void Function(Size size, double time) setUniforms;

  String get asset => shader.asset;

  /// Loads every shader of the gallery. gradient.frag comes first: DevTools
  /// opens the first shader the app draws, and the docs use it.
  static Future<List<ExampleShader>> loadAll() async {
    final gradient = await DebugShader.fromAsset('shaders/gradient.frag');
    final lights = await DebugShader.fromAsset('shaders/lights.frag');
    final checkerboard = await DebugShader.fromAsset(
      'shaders/checkerboard.frag',
    );
    final ripple = await DebugShader.fromAsset('shaders/ripple.frag');
    ripple.getImageSampler('uImage').set(await _pattern());
    // Uniform handles are made once; their values are set every frame, so
    // they survive a hot reload of the shader, which zeroes them.
    final colorA = gradient.getUniformVec4('uA');
    final colorB = gradient.getUniformVec4('uB');
    final cells = checkerboard.getUniformFloat('uCells');

    return [
      ExampleShader(
        shader: gradient,
        hint: 'A scalar: pick `d`, the distance from the center.',
        setUniforms: _uniforms(gradient, (size, time) {
          colorA.set(0.10, 0.20, 0.90, 1.0);
          colorB.set(1.00, 0.60, 0.10, 1.0);
        }),
      ),
      ExampleShader(
        shader: lights,
        hint:
            'An array of structs summed in a loop: pick `lights`, then an '
            'element and a field. Inside the loop, values are the last '
            "light's.",
        setUniforms: _uniforms(lights, (size, time) {}),
      ),
      ExampleShader(
        shader: checkerboard,
        hint:
            'A matrix (`spin`: pick a column), an `ivec2` cell and a `bool` '
            '(`dark`, read as true or false).',
        setUniforms: _uniforms(checkerboard, (size, time) => cells.set(8)),
      ),
      ExampleShader(
        shader: ripple,
        hint:
            'Out parameters (`offset`, `shade`) and an image sampled through '
            'them (`texel`).',
        setUniforms: _uniforms(ripple, (size, time) {}),
      ),
    ];
  }

  /// Sets `uSize` and, if the shader has it, `uTime`, then the rest.
  static void Function(Size, double) _uniforms(
    DebugShader shader,
    void Function(Size size, double time) rest,
  ) {
    final size = shader.getUniformVec2('uSize');
    DebugUniformFloat? time;
    try {
      time = shader.getUniformFloat('uTime');
    } on ArgumentError {
      // A shader without time, such as gradient.frag.
    }
    return (painted, seconds) {
      size.set(painted.width, painted.height);
      time?.set(seconds);
      rest(painted, seconds);
    };
  }

  /// The image ripple.frag looks at: stripes and dots, drawn at startup so
  /// the example needs no image asset.
  static Future<ui.Image> _pattern() {
    const side = 256.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, side, side),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          const Offset(side, side),
          const [Color(0xFF283593), Color(0xFF00897B), Color(0xFFF9A825)],
          const [0, 0.5, 1],
        ),
    );
    final stripe = Paint()..color = const Color(0x33FFFFFF);
    for (var x = 0.0; x < side; x += 32) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 16, side), stripe);
    }
    final dot = Paint()..color = const Color(0xCCFFFFFF);
    for (var y = 32.0; y < side; y += 64) {
      for (var x = 32.0; x < side; x += 64) {
        canvas.drawCircle(Offset(x, y), 10, dot);
      }
    }
    return recorder.endRecording().toImage(side.toInt(), side.toInt());
  }
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key, required this.shaders, this.time});

  final List<ExampleShader> shaders;

  /// Seconds of animation, set from outside, for example to record frames
  /// at exact times. By default the app animates on its own, with a pause
  /// button.
  final ValueListenable<double>? time;

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp>
    with SingleTickerProviderStateMixin {
  /// Seconds of animation, for the shaders' `uTime`.
  final _time = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(_tick);
  double _pausedAt = 0;

  ValueListenable<double> get _clock => widget.time ?? _time;

  @override
  void initState() {
    super.initState();
    if (widget.time == null) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) =>
      _time.value = _pausedAt + elapsed.inMicroseconds / 1e6;

  /// Pausing holds every value still while you read pixels.
  void _togglePlaying() {
    setState(() {
      if (_ticker.isActive) {
        _ticker.stop();
        _pausedAt = _time.value;
      } else {
        _ticker.start();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shader Debugger example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Shader Debugger example'),
          actions: [
            if (widget.time == null)
              IconButton(
                icon: Icon(_ticker.isActive ? Icons.pause : Icons.play_arrow),
                tooltip: _ticker.isActive ? 'Pause' : 'Play',
                onPressed: _togglePlaying,
              ),
          ],
        ),
        body: GridView.extent(
          padding: const EdgeInsets.all(12),
          maxCrossAxisExtent: 420,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.9,
          children: [
            for (final shader in widget.shaders)
              _ShaderCard(shader: shader, time: _clock),
          ],
        ),
      ),
    );
  }
}

class _ShaderCard extends StatelessWidget {
  const _ShaderCard({required this.shader, required this.time});

  final ExampleShader shader;
  final ValueListenable<double> time;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(shader.asset, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(shader.hint, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: CustomPaint(
              painter: ShaderPainter(shader, time),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints an [ExampleShader] over its whole size, every frame [time]
/// changes.
class ShaderPainter extends CustomPainter {
  ShaderPainter(this.shader, this.time) : super(repaint: time);

  final ExampleShader shader;
  final ValueListenable<double> time;

  @override
  void paint(Canvas canvas, Size size) {
    shader.setUniforms(size, time.value);
    // Read shader.shader after setting the uniforms: while the debugger shows
    // a heatmap it is the probe, with these uniforms copied onto it.
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader.shader.shader);
  }

  @override
  bool shouldRepaint(ShaderPainter oldDelegate) =>
      oldDelegate.shader != shader || oldDelegate.time != time;
}
