/// The overlay of pixel select mode ([ShaderDebugger.setPixelSelectMode]),
/// modeled on the widget inspector's select mode: it covers the app and takes
/// its clicks, highlights the pixel under the pointer, and reports each click
/// to DevTools until it is turned off.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'shader_debugger.dart';

/// What the overlay shows while select mode is on. Inserted into the app's
/// root Overlay by [ShaderDebugger].
@internal
class PixelSelectLayer extends StatefulWidget {
  const PixelSelectLayer({super.key, required this.debugger});

  final ShaderDebugger debugger;

  @override
  State<PixelSelectLayer> createState() => _PixelSelectLayerState();
}

class _PixelSelectLayerState extends State<PixelSelectLayer> {
  PixelTarget? _hovered;
  PixelTarget? _selected;

  /// Where this layer is, globally; targets are in global coordinates.
  Offset _origin = Offset.zero;

  int get _viewId => View.of(context).viewId;

  void _updateOrigin() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _origin = box.localToGlobal(Offset.zero);
    }
  }

  void _hover(PointerHoverEvent event) {
    final asset = widget.debugger.pixelSelectAsset;
    if (asset == null) return;
    _updateOrigin();
    setState(
      () => _hovered = widget.debugger.pixelTargetAt(
        asset,
        event.position,
        viewId: _viewId,
      ),
    );
  }

  void _click(TapUpDetails details) {
    _updateOrigin();
    final target = widget.debugger.selectPixel(
      details.globalPosition,
      viewId: _viewId,
    );
    if (target != null) setState(() => _selected = target);
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.debugger.pixelSelectAsset ?? '';
    return _HiddenFromPixelHitTest(
      debugger: widget.debugger,
      child: Directionality(
        textDirection: TextDirection.ltr,
        // The app's own text style may be missing or meant for errors (a
        // MaterialApp outside any Material).
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 12,
            decoration: TextDecoration.none,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.precise,
                onHover: _hover,
                onExit: (_) => setState(() => _hovered = null),
                child: GestureDetector(
                  // Takes every click, tap, drag and scroll from the app.
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _click,
                  child: CustomPaint(
                    painter: _PixelSelectPainter(
                      hovered: _hovered,
                      selected: _selected,
                      origin: _origin,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 24,
                child: Center(
                  child: _Banner(
                    asset: asset,
                    onDone: widget.debugger.leavePixelSelectMode,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says what select mode does, with a way out that does not need DevTools.
class _Banner extends StatelessWidget {
  const _Banner({required this.asset, required this.onDone});

  final String asset;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xE6202124),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  'Shader Debugger: click a pixel of $asset',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onDone,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Text(
                      'Done',
                      style: TextStyle(
                        color: _PixelSelectPainter.hoverColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The shader's area, and a crosshair on the device pixel: blue under the
/// pointer, amber where last clicked.
class _PixelSelectPainter extends CustomPainter {
  _PixelSelectPainter({
    required this.hovered,
    required this.selected,
    required this.origin,
  });

  static const hoverColor = Color(0xFF42A5F5);
  static const selectedColor = Color(0xFFFFB300);

  final PixelTarget? hovered;
  final PixelTarget? selected;
  final Offset origin;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.translate(-origin.dx, -origin.dy);
    final visible = origin & size;
    if (selected case final target?) {
      _paintTarget(
        canvas,
        target,
        selectedColor,
        visible,
        label: hovered == null,
      );
    }
    if (hovered case final target?) {
      _paintTarget(canvas, target, hoverColor, visible, label: true);
    }
  }

  void _paintTarget(
    Canvas canvas,
    PixelTarget target,
    Color color,
    Rect visible, {
    required bool label,
  }) {
    final bounds = target.bounds;
    final center = target.center;
    canvas.drawRect(
      bounds.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = color,
    );
    canvas
      ..save()
      ..clipRect(bounds);
    final line = Paint()..color = color.withValues(alpha: 0.6);
    canvas
      ..drawLine(
        Offset(bounds.left, center.dy),
        Offset(bounds.right, center.dy),
        line,
      )
      ..drawLine(
        Offset(center.dx, bounds.top),
        Offset(center.dx, bounds.bottom),
        line,
      )
      ..restore();
    // The device pixel itself is too small to see: frame it.
    final frame = Rect.fromCenter(center: center, width: 9, height: 9);
    canvas
      ..drawRect(
        frame,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0x99000000),
      )
      ..drawRect(
        frame,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = color,
      );
    if (label) _paintLabel(canvas, target, visible);
  }

  void _paintLabel(Canvas canvas, PixelTarget target, Rect visible) {
    final text = TextPainter(
      text: TextSpan(
        text: '${_format(target.coord.dx)}, ${_format(target.coord.dy)}',
        style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final size = Size(text.width + 8, text.height + 4);
    // Below and to the right of the pixel, or flipped to stay visible.
    var left = target.center.dx + 10;
    var top = target.center.dy + 10;
    if (left + size.width > visible.right) {
      left = target.center.dx - 10 - size.width;
    }
    if (top + size.height > visible.bottom) {
      top = target.center.dy - 10 - size.height;
    }
    final box = Offset(left, top) & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(3)),
      Paint()..color = const Color(0xE6202124),
    );
    text
      ..paint(canvas, box.topLeft + const Offset(4, 2))
      ..dispose();
  }

  /// Up to three decimals, without trailing zeros: device pixel centers are
  /// halves, quarters or thirds of a logical pixel.
  static String _format(double value) {
    final text = value.toStringAsFixed(3);
    return text.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  @override
  bool shouldRepaint(_PixelSelectPainter oldDelegate) =>
      oldDelegate.hovered != hovered ||
      oldDelegate.selected != selected ||
      oldDelegate.origin != origin;
}

/// Lets [ShaderDebugger.pixelTargetAt]'s hit test through to the app below,
/// while still taking the app's pointer events.
class _HiddenFromPixelHitTest extends SingleChildRenderObjectWidget {
  const _HiddenFromPixelHitTest({required this.debugger, super.child});

  final ShaderDebugger debugger;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHiddenFromPixelHitTest(debugger);
}

class _RenderHiddenFromPixelHitTest extends RenderProxyBox {
  _RenderHiddenFromPixelHitTest(this.debugger);

  final ShaderDebugger debugger;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !debugger.hitTestingForPixel && super.hitTest(result, position: position);
}
