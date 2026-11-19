// Purpose: edit per-DC Telegram IP overrides used by the relay.
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/base/base_page.dart';
import '../../core/proxy/proxy_repository.dart';
import '../../core/ui/app_toast.dart';

/// Telegram DCs that can be overridden. Media DCs reuse the same IP because
/// the engine only looks up the positive data-center number.
const _dcs = <int>[1, 2, 3, 4, 5, 203];

class DcPage extends BasePage {
  const DcPage({super.key}) : super(title: 'DC → IP');

  @override
  State<DcPage> createState() => _DcPageState();
}

class _DcPageState extends BasePageState<DcPage> {
  final Map<int, TextEditingController> _controllers = {};
  ProxyRepository? _proxy;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _proxy ??= context.read<ProxyRepository>();
    if (_controllers.isNotEmpty) return;

    final raw = _proxy!.settings['dcRedirects'];
    final saved = <int, String>{
      if (raw is Map)
        for (final entry in raw.entries)
          if (int.tryParse('${entry.key}') case final dc?)
            if (entry.value?.toString().isNotEmpty == true)
              dc: entry.value.toString(),
    };
    for (final dc in _dcs) {
      _controllers[dc] = TextEditingController(text: saved[dc] ?? '');
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
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

  Future<void> _save() async {
    final next = <int, String>{};
    for (final entry in _controllers.entries) {
      final value = entry.value.text.trim();
      if (value.isEmpty) continue;
      if (!_isIpv4(value)) {
        AppToast.showError('DC${entry.key}: нужен IPv4-адрес');
        return;
      }
      next[entry.key] = value;
    }

    await _proxy!.updateSettings({
      'dcRedirects': next.map((dc, ip) => MapEntry('$dc', ip)),
    });
    if (!mounted) return;
    AppToast.showMessage('Маршруты DC сохранены');
    Navigator.of(context).pop();
  }

  @override
  List<Widget>? buildAppBarActions() => [
    IconButton(
      onPressed: _save,
      tooltip: 'Сохранить',
      icon: const Icon(Icons.check),
    ),
  ];

  @override
  Widget buildBody() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'IP-адреса Telegram DC',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Прокси подключается к этому IP, а WebSocket Host остаётся '
                  'kwsN.web.telegram.org. Пустое поле — стандартный адрес.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < _dcs.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: TextField(
                    controller: _controllers[_dcs[i]],
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'DC ${_dcs[i]}',
                      hintText: _hintFor(_dcs[i]),
                      prefixIcon: const Icon(Icons.dns_outlined),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: () {
            for (final controller in _controllers.values) {
              controller.clear();
            }
            AppToast.showMessage('Поля очищены — сохраните для сброса');
          },
          icon: const Icon(Icons.restart_alt),
          label: const Text('Сбросить на стандартные IP'),
        ),
      ],
    );
  }

  String _hintFor(int dc) => switch (dc) {
    1 => '149.154.175.50',
    2 => '149.154.167.51',
    3 => '149.154.175.100',
    4 => '149.154.167.91',
    5 => '149.154.171.5',
    _ => '91.105.192.100',
  };
}
