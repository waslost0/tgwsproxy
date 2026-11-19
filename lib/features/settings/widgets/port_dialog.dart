// Purpose: validated numeric dialog for local port settings.
import 'package:material_ui/material_ui.dart';

class PortDialog extends StatefulWidget {
  const PortDialog({
    super.key,
    required this.title,
    required this.initial,
    required this.max,
    required this.helper,
  });

  final String title;
  final int initial;
  final int max;
  final String helper;

  static Future<void> edit(
    BuildContext context, {
    required String title,
    required int initial,
    required int max,
    required String helper,
    required Future<void> Function(int) onSave,
  }) async {
    final value = await showDialog<int>(
      context: context,
      builder: (_) =>
          PortDialog(title: title, initial: initial, max: max, helper: helper),
    );
    if (value != null) await onSave(value);
  }

  @override
  State<PortDialog> createState() => _PortDialogState();
}

class _PortDialogState extends State<PortDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.initial}');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null || value < 1 || value > widget.max) return;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: 'Значение',
          helperText: widget.helper,
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _save, child: const Text('Сохранить')),
      ],
    );
  }
}
