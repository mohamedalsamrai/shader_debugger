/// The overlay of pixel select mode ([ShaderDebugger.setPixelSelectMode]),
/// modeled on the widget inspector's select mode: it covers the app and takes
/// its clicks and taps, highlights the pixel under the pointer or finger, and
/// reports each pick to DevTools until it is turned off.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
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
  /// The pixel under the pointer: the mouse's, or a finger's while it is down.
  PixelTarget? _hovered;
  PixelTarget? _selected;

  /// The pointer pressed on the overlay, which picks where it lifts.
  int? _pressed;

  /// Whether [_hovered] is under a finger, which would hide a label beside it.
  bool _underFinger = false;

  /// Where this layer is, globally; targets are in global coordinates.
  Offset _origin = Offset.zero;

  int get _viewId => View.of(context).viewId;

  static const _fingers = {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  };

  void _updateOrigin() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _origin = box.localToGlobal(Offset.zero);
    }
  }

  /// Shows the pixel under [event]'s position, without picking it.
  void _aim(PointerEvent event) {
    final asset = widget.debugger.pixelSelectAsset;
    if (asset == null) return;
    _updateOrigin();
    setState(() {
      _hovered = widget.debugger.pixelTargetAt(
        asset,
        event.position,
        viewId: _viewId,
      );
      _underFinger = _fingers.contains(event.kind);
    });
  }

  void _down(PointerDownEvent event) {
    if (_pressed != null || event.buttons & kPrimaryButton == 0) return;
    _pressed = event.pointer;
    _aim(event);
  }

  /// A finger, or a mouse with its button down, aims until it lifts.
  void _move(PointerMoveEvent event) {
    if (event.pointer == _pressed) _aim(event);
  }

  /// Picks the pixel where the pressed pointer lifts: a click or a tap, or
  /// the end of a drag that aimed at it.
  void _up(PointerUpEvent event) {
    if (event.pointer != _pressed) return;
    _pressed = null;
    _updateOrigin();
    final target = widget.debugger.selectPixel(event.position, viewId: _viewId);
    setState(() {
      if (target != null) _selected = target;
      // A lifted finger points at nothing; a mouse goes on hovering.
      if (_fingers.contains(event.kind)) _hovered = null;
    });
  }

  void _cancel(PointerCancelEvent event) {
    if (event.pointer != _pressed) return;
    _pressed = null;
    if (_fingers.contains(event.kind)) setState(() => _hovered = null);
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.debugger.pixelSelectAsset ?? '';
    // Keeps the banner clear of notches and the home indicator.
    final safe = MediaQuery.maybePaddingOf(context) ?? EdgeInsets.zero;
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
                onHover: _aim,
                onExit: (_) => setState(() => _hovered = null),
                child: Listener(
                  // Takes every click, tap, drag and scroll from the app.
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerUp: _up,
                  onPointerCancel: _cancel,
                  child: CustomPaint(
                    painter: _PixelSelectPainter(
                      hovered: _hovered,
                      selected: _selected,
                      origin: _origin,
                      underFinger: _underFinger,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16 + safe.left,
                right: 16 + safe.right,
                bottom: 24 + safe.bottom,
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

  /// What picks a pixel on this platform.
  static String get _verb => switch (defaultTargetPlatform) {
    TargetPlatform.iOS ||
    TargetPlatform.android ||
    TargetPlatform.fuchsia => 'tap',
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => 'click',
  };

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
                  'Shader Debugger: $_verb a pixel of $asset',
                  // A phone is too narrow for one line with the asset.
                  maxLines: 2,
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
/// pointer or finger, amber where last picked.
class _PixelSelectPainter extends CustomPainter {
  _PixelSelectPainter({
    required this.hovered,
    required this.selected,
    required this.origin,
    required this.underFinger,
  });

  static const hoverColor = Color(0xFF42A5F5);
  static const selectedColor = Color(0xFFFFB300);

  /// How far a label stays from a finger's contact point: about a
  /// fingertip, the size of a minimum touch target on iOS.
  static const fingerClearance = 44.0;

  final PixelTarget? hovered;
  final PixelTarget? selected;
  final Offset origin;

  /// Whether [hovered] is under a finger: its label then goes above it.
  final bool underFinger;

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
        aboveFinger: false,
      );
    }
    if (hovered case final target?) {
      _paintTarget(
        canvas,
        target,
        hoverColor,
        visible,
        label: true,
        aboveFinger: underFinger,
      );
    }
  }

  void _paintTarget(
    Canvas canvas,
    PixelTarget target,
    Color color,
    Rect visible, {
    required bool label,
    required bool aboveFinger,
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
    if (label) {
      _paintLabel(canvas, target, visible, aboveFinger: aboveFinger);
    }
  }

  void _paintLabel(
    Canvas canvas,
    PixelTarget target,
    Rect visible, {
    required bool aboveFinger,
  }) {
    final text = TextPainter(
      text: TextSpan(
        text: '${_format(target.coord.dx)}, ${_format(target.coord.dy)}',
        style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final size = Size(text.width + 8, text.height + 4);
    final center = target.center;
    double left;
    double top;
    if (aboveFinger) {
      // Centered above the finger, which hides what is below and beside it;
      // below only when there is no room above.
      left = center.dx - size.width / 2;
      if (left + size.width > visible.right) left = visible.right - size.width;
      if (left < visible.left) left = visible.left;
      top = center.dy - fingerClearance - size.height;
      if (top < visible.top) top = center.dy + fingerClearance;
    } else {
      // Below and to the right of the pixel, or flipped to stay visible.
      left = center.dx + 10;
      top = center.dy + 10;
      if (left + size.width > visible.right) {
        left = center.dx - 10 - size.width;
      }
      if (top + size.height > visible.bottom) {
        top = center.dy - 10 - size.height;
      }
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
      oldDelegate.origin != origin ||
      oldDelegate.underFinger != underFinger;
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
