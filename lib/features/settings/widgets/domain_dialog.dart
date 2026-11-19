// Purpose: reusable editable domain dialog with its own controller lifecycle.
import 'package:material_ui/material_ui.dart';

class DomainDialog extends StatefulWidget {
  const DomainDialog({
    super.key,
    required this.title,
    required this.hint,
    required this.helper,
    required this.initial,
  });

  final String title;
  final String hint;
  final String helper;
  final String initial;

  /// Opens the dialog and saves the edited value when it is not cancelled.
  static Future<void> edit(
    BuildContext context, {
    required String title,
    required String hint,
    required String helper,
    required String initial,
    required Future<void> Function(String) onSave,
  }) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => DomainDialog(
        title: title,
        hint: hint,
        helper: helper,
        initial: initial,
      ),
    );
    if (value != null) await onSave(value);
  }

  @override
  State<DomainDialog> createState() => _DomainDialogState();
}

class _DomainDialogState extends State<DomainDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: widget.hint,
          helperText: widget.helper,
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
