// Purpose: reveal/copy the proxy secret and regenerate the Telegram link.
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/proxy/proxy_repository.dart';
import '../../../core/ui/app_toast.dart';

class SecretDialog extends StatefulWidget {
  const SecretDialog({super.key, required this.proxy});

  final ProxyRepository proxy;

  @override
  State<SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends State<SecretDialog> {
  late String _secret = widget.proxy.secret;
  late String _link = widget.proxy.link;
  bool _revealed = false;
  bool _busy = false;

  Future<void> _copyLink() async {
    final link = _link.isEmpty ? await widget.proxy.getProxyLink() : _link;
    if (link.isEmpty) {
      AppToast.showError('Ссылка ещё не готова');
      return;
    }
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) AppToast.showMessage('Ссылка для Telegram скопирована');
  }

  Future<void> _copySecret() async {
    if (_secret.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _secret));
    if (mounted) AppToast.showMessage('Секрет скопирован');
  }

  Future<void> _regenerate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Новый секрет?'),
        content: const Text(
          'Старая ссылка перестанет работать. Telegram попросит добавить '
          'прокси заново.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сгенерировать'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    await widget.proxy.regenerateSecret();
    _secret = widget.proxy.secret;
    _link = await widget.proxy.getProxyLink();
    if (mounted) {
      setState(() {
        _busy = false;
        _revealed = true;
      });
      AppToast.showMessage('Секрет обновлён');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final masked = _secret.isEmpty
        ? '—'
        : _revealed
        ? _secret
        : List.filled(_secret.length, '•').join();

    return AlertDialog(
      title: const Text('Секрет прокси'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'MTProto-секрет. В ссылке Telegram он идёт с префиксом dd.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              masked,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _revealed = !_revealed),
                icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
                label: Text(_revealed ? 'Скрыть' : 'Показать'),
              ),
              TextButton.icon(
                onPressed: _copySecret,
                icon: const Icon(Icons.copy),
                label: const Text('Копировать'),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _regenerate,
          child: const Text('Новый секрет'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _copyLink,
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send),
          label: const Text('Ссылка'),
        ),
      ],
    );
  }
}
