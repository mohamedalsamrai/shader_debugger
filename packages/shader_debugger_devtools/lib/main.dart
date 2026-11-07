import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/material.dart';

import 'src/controller.dart';
import 'src/devtools_ports.dart';
import 'src/screen.dart';

void main() {
  runApp(const ShaderDebuggerDevToolsExtension());
}

class ShaderDebuggerDevToolsExtension extends StatelessWidget {
  const ShaderDebuggerDevToolsExtension({super.key});

  @override
  Widget build(BuildContext context) {
    return const DevToolsExtension(child: _Home());
  }
}

/// Creates the controller under [DevToolsExtension], which sets up the
/// `serviceManager` and `dtdManager` globals the DevTools ports use.
class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late final _controller = ShaderDebuggerController(
    app: DevToolsDebuggedApp(),
    workspace: DtdWorkspace(),
  )..start();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ShaderDebuggerScreen(controller: _controller);
}
