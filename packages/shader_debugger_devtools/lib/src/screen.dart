/// The Shader Debugger page.
library;

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shader_debugger_core/shader_debugger_core.dart';

import 'controller.dart';

class ShaderDebuggerScreen extends StatelessWidget {
  const ShaderDebuggerScreen({super.key, required this.controller});

  final ShaderDebuggerController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => switch (controller.connection) {
          AppConnection.waiting => const _Notice(
            icon: Icons.hourglass_empty,
            title: 'Waiting for the app',
            body:
                'Draw a shader through DebugShader (package:shader_debugger) '
                'and run the app in debug mode. This page connects as soon as '
                'the app creates its first DebugShader.',
          ),
          AppConnection.connecting => const Center(
            child: CircularProgressIndicator(),
          ),
          AppConnection.failed => _Notice(
            icon: Icons.error_outline,
            title: 'Cannot connect to the app',
            body: controller.connectionError ?? '',
            action: TextButton(
              onPressed: controller.connect,
              child: const Text('Retry'),
            ),
          ),
          AppConnection.ready => _Debugger(controller: controller),
        },
      ),
    );
  }
}

class _Debugger extends StatelessWidget {
  const _Debugger({required this.controller});

  final ShaderDebuggerController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(controller: controller),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _SourcePane(controller: controller)),
              const VerticalDivider(width: 1),
              SizedBox(width: 360, child: _SidePanel(controller: controller)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.controller});

  final ShaderDebuggerController controller;

  @override
  Widget build(BuildContext context) {
    final shaders = controller.info?.shaders ?? const <String>[];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          const Text('Shader'),
          const SizedBox(width: 12),
          if (shaders.isEmpty)
            const Text('The app draws no DebugShader right now.')
          else
            DropdownButton<String>(
              value: shaders.contains(controller.asset)
                  ? controller.asset
                  : null,
              hint: const Text('Pick a shader'),
              underline: const SizedBox(),
              items: [
                for (final shader in shaders)
                  DropdownMenuItem(value: shader, child: Text(shader)),
              ],
              onChanged: (shader) {
                if (shader != null) controller.selectShader(shader);
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Read the shader file again',
            onPressed: controller.asset == null
                ? null
                : controller.reloadSource,
          ),
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Ask the app which shaders it draws',
            onPressed: controller.connect,
          ),
        ],
      ),
    );
  }
}

class _SourcePane extends StatelessWidget {
  const _SourcePane({required this.controller});

  final ShaderDebuggerController controller;

  @override
  Widget build(BuildContext context) {
    final error = controller.sourceError;
    if (error != null) {
      return _Notice(
        icon: Icons.folder_off_outlined,
        title: 'Cannot read the shader',
        body: error,
      );
    }
    final analysis = controller.analysis;
    if (analysis == null) {
      return controller.asset == null
          ? const SizedBox()
          : const Center(child: CircularProgressIndicator());
    }
    final lines = analysis.source.getText(0).split('\n');
    final pickable = controller.pickableLines;
    final notes = <int, List<String>>{};
    for (final diagnostic in analysis.diagnostics) {
      final span = diagnostic.span;
      if (span != null) {
        (notes[span.start.line] ??= []).add(diagnostic.message);
      }
    }
    final selected = controller.statement?.span;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: lines.length,
      itemBuilder: (context, index) => _SourceLine(
        number: index + 1,
        text: lines[index].replaceAll('\t', '  '),
        pickable: pickable.contains(index),
        selected:
            selected != null &&
            index >= selected.start.line &&
            index <= selected.end.line,
        notes: notes[index],
        onTap: () => controller.selectLine(index),
      ),
    );
  }
}

class _SourceLine extends StatelessWidget {
  const _SourceLine({
    required this.number,
    required this.text,
    required this.pickable,
    required this.selected,
    required this.notes,
    required this.onTap,
  });

  final int number;
  final String text;
  final bool pickable;
  final bool selected;
  final List<String>? notes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final code = theme.fixedFontStyle;
    final notes = this.notes;
    final row = Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            '$number',
            textAlign: TextAlign.right,
            style: code.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
        SizedBox(
          width: 24,
          child: notes != null
              ? Tooltip(
                  message: notes.join('\n'),
                  child: Icon(
                    Icons.warning_amber,
                    size: 14,
                    color: colors.error,
                  ),
                )
              : pickable
              ? Icon(Icons.circle, size: 6, color: colors.primary)
              : null,
        ),
        Expanded(
          child: Text(
            text,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: pickable
                ? code
                : code.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
    return Container(
      color: selected ? colors.primaryContainer.withValues(alpha: 0.6) : null,
      child: pickable
          ? InkWell(
              onTap: onTap,
              child: Tooltip(
                message: 'Pick a value at line $number',
                waitDuration: const Duration(seconds: 1),
                child: row,
              ),
            )
          : row,
    );
  }
}

class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.controller});

  final ShaderDebuggerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statement = controller.statement;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (statement == null)
          Text(
            controller.analysis == null
                ? ''
                : 'Click a marked line to pick a statement.',
          )
        else ...[
          Text('Line ${statement.line + 1}', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            statement.span.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.fixedFontStyle,
          ),
          const SizedBox(height: 12),
          Text('Value', style: theme.textTheme.titleSmall),
          for (final variable in statement.inScope)
            _VariableTile(
              variable: variable,
              written: statement.writes.contains(variable),
              selected: variable == controller.variable,
              onTap: () => controller.selectVariable(variable),
            ),
          if (controller.path.isNotEmpty) ...[
            const SizedBox(height: 12),
            _PartPicker(controller: controller),
          ],
        ],
        const SizedBox(height: 12),
        _RangeEditor(controller: controller),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.gradient),
              label: const Text('Show heatmap'),
              onPressed: controller.canShow ? controller.showHeatmap : null,
            ),
            OutlinedButton(
              onPressed: controller.status == HeatmapStatus.off
                  ? null
                  : controller.hideHeatmap,
              child: const Text('Hide'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _Status(controller: controller),
        if (controller.analysis?.diagnostics case final diagnostics?
            when diagnostics.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Notes on this shader', style: theme.textTheme.titleSmall),
          for (final diagnostic in diagnostics)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('$diagnostic', style: theme.textTheme.bodySmall),
            ),
        ],
      ],
    );
  }
}

class _VariableTile extends StatelessWidget {
  const _VariableTile({
    required this.variable,
    required this.written,
    required this.selected,
    required this.onTap,
  });

  final VariableSymbol variable;
  final bool written;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final type = variable.type;
    final capturable = ShaderDebuggerController.isCapturable(variable);
    final details = [
      '$type',
      variable.kind.name,
      if (written) 'written here',
      if (!capturable) 'cannot be shown',
    ];
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      enabled: capturable,
      selected: selected,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 18,
      ),
      title: Text(variable.name, style: Theme.of(context).fixedFontStyle),
      subtitle: Text(details.join(' · ')),
      onTap: onTap,
    );
  }
}

/// Picks the part of a composite value to show: a column, element or field
/// at each step, down to a part the probe can draw.
class _PartPicker extends StatelessWidget {
  const _PartPicker({required this.controller});

  final ShaderDebuggerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = theme.fixedFontStyle;
    final variable = controller.variable!;
    final path = controller.path;
    final steps = <Widget>[];
    for (final (depth, step) in path.indexed) {
      final type = controller.typeAt(depth)!;
      final choices = type.selectorChoices;
      steps.add(
        choices.isNotEmpty
            ? DropdownButton<Selector>(
                value: step,
                isDense: true,
                style: code,
                items: [
                  for (final choice in choices)
                    DropdownMenuItem(value: choice, child: Text('$choice')),
                ],
                onChanged: (choice) {
                  if (choice != null) controller.selectStep(depth, choice);
                },
              )
            // An array of unknown length: any index.
            : _IndexField(
                key: ValueKey((variable, path.take(depth + 1).join())),
                index: (step as IndexSelector).index,
                onSubmitted: (index) =>
                    controller.selectStep(depth, IndexSelector(index)),
              ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Part', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(variable.name, style: code),
            ...steps,
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${controller.expression} · ${controller.valueType}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// An index typed by hand, for an array whose length the analyzer could not
/// work out.
class _IndexField extends StatefulWidget {
  const _IndexField({
    super.key,
    required this.index,
    required this.onSubmitted,
  });

  final int index;
  final ValueChanged<int> onSubmitted;

  @override
  State<_IndexField> createState() => _IndexFieldState();
}

class _IndexFieldState extends State<_IndexField> {
  late final _text = TextEditingController(text: '${widget.index}');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: TextField(
        controller: _text,
        decoration: const InputDecoration(
          isDense: true,
          prefixText: '[',
          suffixText: ']',
        ),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onSubmitted: (text) {
          final index = int.tryParse(text);
          if (index != null) widget.onSubmitted(index);
        },
      ),
    );
  }
}

class _RangeEditor extends StatefulWidget {
  const _RangeEditor({required this.controller});

  final ShaderDebuggerController controller;

  @override
  State<_RangeEditor> createState() => _RangeEditorState();
}

class _RangeEditorState extends State<_RangeEditor> {
  late final _min = TextEditingController(text: _format(widget.controller.min));
  late final _max = TextEditingController(text: _format(widget.controller.max));
  String? _error;

  static String _format(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(1) : '$value';

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _apply() {
    final min = double.tryParse(_min.text.trim());
    final max = double.tryParse(_max.text.trim());
    setState(
      () => _error = min == null || max == null ? 'Enter two numbers.' : null,
    );
    if (min != null && max != null) widget.controller.setRange(min, max);
  }

  @override
  Widget build(BuildContext context) {
    Widget field(String label, TextEditingController controller) => Expanded(
      child: TextField(
        controller: controller,
        decoration: InputDecoration(labelText: label, isDense: true),
        keyboardType: const TextInputType.numberWithOptions(
          signed: true,
          decimal: true,
        ),
        onSubmitted: (_) => _apply(),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Range', style: Theme.of(context).textTheme.titleSmall),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            field('Min', _min),
            const SizedBox(width: 8),
            field('Max', _max),
            const SizedBox(width: 8),
            TextButton(onPressed: _apply, child: const Text('Apply')),
          ],
        ),
        if (_error case final error?)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.controller});

  final ShaderDebuggerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = controller.statusMessage ?? '';
    switch (controller.status) {
      case HeatmapStatus.off:
        return const SizedBox();
      case HeatmapStatus.writing ||
          HeatmapStatus.reloading ||
          HeatmapStatus.loading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 4),
            Text(message),
          ],
        );
      case HeatmapStatus.shown:
        final probe = controller.shownProbe!;
        return Text(
          'Showing ${probe.request.expression} '
          '(${probe.valueType}, ${probe.visualization.name}) after line '
          '${probe.request.statement.line + 1}, in the app.',
        );
      case HeatmapStatus.failed:
        final probe = controller.manualProbe;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: TextStyle(color: theme.colorScheme.error)),
            if (probe != null) ...[
              const SizedBox(height: 8),
              Text(
                controller.probeFile?.toFilePath() ?? '',
                style: theme.fixedFontStyle,
              ),
              Wrap(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy probe'),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: probe.source)),
                  ),
                  TextButton(
                    onPressed: controller.checkManualProbe,
                    child: const Text('Check'),
                  ),
                ],
              ),
            ],
          ],
        );
    }
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}
