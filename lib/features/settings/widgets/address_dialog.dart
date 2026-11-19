// Purpose: editable loopback/port dialog, including input validation.
import 'package:material_ui/material_ui.dart';

class AddressDialog extends StatefulWidget {
  const AddressDialog({super.key, required this.host, required this.port});

  final String host;
  final int port;

  static Future<void> edit(
    BuildContext context, {
    required String host,
    required int port,
    required Future<void> Function(String host, int port) onSave,
  }) async {
    final value = await showDialog<(String, int)>(
      context: context,
      builder: (_) => AddressDialog(host: host, port: port),
    );
    if (value != null) await onSave(value.$1, value.$2);
  }

  @override
  State<AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<AddressDialog> {
  late final TextEditingController _host;
  late final TextEditingController _port;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.host);
    _port = TextEditingController(text: '${widget.port}');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  bool _isIpv4(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0 || number > 255) return false;
    }
    return true;
  }

  void _save() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (!_isIpv4(host) && host != 'localhost') return;
    if (port == null || port < 1 || port > 65535) return;
    Navigator.pop(context, (host, port));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Локальный адрес'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _host,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Адрес прослушивания',
              hintText: '127.0.0.1',
              helperText:
                  '127.0.0.1 — только этот телефон. '
                  '0.0.0.0 — вся локальная сеть.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Порт',
              hintText: '1443',
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Text(
            '0.0.0.0 открывает прокси другим устройствам в сети. '
            'Доступ всё равно защищён MTProto-секретом.',
            style: theme.textTheme.bodySmall,
          ),
        ],
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
