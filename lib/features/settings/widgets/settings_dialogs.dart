// Purpose: small dialogs for settings export/import and diagnostics.
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/proxy/proxy_repository.dart';
import '../../../core/ui/app_toast.dart';

Future<String?> showImportSettingsDialog(BuildContext context) async {
  final raw = await showDialog<String>(
    context: context,
    builder: (_) => const _ImportSettingsDialog(),
  );
  return raw;
}

Future<void> showExportSettingsDialog(BuildContext context, String json) async {
  await Clipboard.setData(ClipboardData(text: json));
  if (!context.mounted) return;
  AppToast.showMessage('Настройки скопированы в буфер');
}

Future<void> showDiagnosticsDialog(
  BuildContext context,
  ProxyRepository proxy,
) async {
  final data = await proxy.getDiagnostics();
  if (!context.mounted) return;
  final lines = data.entries
      .map((entry) => '${entry.key}: ${entry.value}')
      .join('\n');
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Диагностика'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(
            lines.isEmpty ? 'Нет данных' : lines,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: lines));
            if (context.mounted) {
              AppToast.showMessage('Диагностика скопирована');
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('Копировать'),
        ),
      ],
    ),
  );
}

class _ImportSettingsDialog extends StatefulWidget {
  const _ImportSettingsDialog();

  @override
  State<_ImportSettingsDialog> createState() => _ImportSettingsDialogState();
}

class _ImportSettingsDialogState extends State<_ImportSettingsDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text case final text?) {
      _controller.text = text;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Импорт настроек'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Вставьте JSON, полученный из экспорта. Секрет не входит '
              'в настройки и не меняется.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              maxLines: 6,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '{"port":1443,...}',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _paste, child: const Text('Вставить')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Импортировать'),
        ),
      ],
    );
  }
}
