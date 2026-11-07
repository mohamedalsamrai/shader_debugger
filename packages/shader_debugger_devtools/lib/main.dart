import 'package:devtools_app_shared/service.dart';
import 'package:devtools_extensions/devtools_extensions.dart';
import 'package:flutter/material.dart';
import 'package:shader_debugger_core/shader_debugger_core.dart';

void main() {
  runApp(const ShaderDebuggerDevToolsExtension());
}

class ShaderDebuggerDevToolsExtension extends StatelessWidget {
  const ShaderDebuggerDevToolsExtension({super.key});

  @override
  Widget build(BuildContext context) {
    return const DevToolsExtension(child: ShaderDebuggerScreen());
  }
}

/// Placeholder until M2 brings the variable picker, heatmap and pixel
/// inspector. It shows that DevTools loaded the extension and handed it a
/// connection to the app.
class ShaderDebuggerScreen extends StatelessWidget {
  const ShaderDebuggerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Shader Debugger', style: textTheme.titleLarge),
          const SizedBox(height: 8),
          const _ConnectionStatus(),
          const SizedBox(height: 24),
          Text('How captured values are shown', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          const _VisualizationTable(),
        ],
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ConnectedState>(
      valueListenable: serviceManager.connectedState,
      builder: (context, state, _) {
        if (!state.connected) return const Text('Not connected to an app.');
        return ValueListenableBuilder(
          valueListenable: serviceManager.isolateManager.mainIsolate,
          builder: (context, isolate, _) =>
              Text('Connected to ${isolate?.name ?? 'the app'}.'),
        );
      },
    );
  }
}

/// Design doc §5, "Type → visualization", straight from the core's model.
class _VisualizationTable extends StatelessWidget {
  const _VisualizationTable();

  static final List<GlslType> _examples = [
    GlslType.floatType,
    GlslType.intType,
    GlslType.vec2,
    GlslType.vec3,
    GlslType.vec4,
    GlslType.mat3,
    const ArrayType(GlslType.floatType, 4),
    StructType('Light', const []),
  ];

  @override
  Widget build(BuildContext context) {
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        for (final type in _examples)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 24, bottom: 4),
                child: Text(type.name),
              ),
              Text(_describe(type)),
            ],
          ),
      ],
    );
  }

  static String _describe(GlslType type) => switch (type.visualization) {
    Visualization.scalar => 'grayscale or colormap',
    Visualization.rg => 'RG',
    Visualization.rgb => 'RGB',
    Visualization.rgba => 'RGBA',
    null => switch (type.selectorKind) {
      SelectorKind.column => 'pick a column',
      SelectorKind.element => 'pick an element',
      SelectorKind.field => 'pick a field',
      null => 'cannot be captured',
    },
  };
}
