// Purpose: manage the list of user-owned Cloudflare Worker domains.
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:tg_proxy_core/tg_proxy_core.dart';

import '../../core/base/base_page.dart';
import '../../core/proxy/proxy_repository.dart';
import '../../core/ui/app_toast.dart';

class WorkersPage extends BasePage {
  const WorkersPage({super.key}) : super(title: 'Cloudflare Workers');

  @override
  State<WorkersPage> createState() => _WorkersPageState();
}

class _WorkersPageState extends BasePageState<WorkersPage> {
  ProxyRepository? _proxy;
  List<String> _domains = const [];
  final Map<String, String> _status = {};
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _proxy ??= context.read<ProxyRepository>();
    if (!_loaded) {
      final saved = _proxy!.settings['cfWorkerDomains'];
      if (saved is List) {
        _domains = saved.map((value) => value.toString()).toList();
      }
      _loaded = true;
    }
  }

  Future<void> _save(List<String> next) async {
    setState(() => _domains = next);
    try {
      await _proxy!.updateSettings({'cfWorkerDomains': next});
    } catch (error) {
      if (mounted) AppToast.showError('Не удалось сохранить: $error');
    }
  }

  Future<void> _add() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => const _AddWorkerDialog(),
    );
    final domain = _normalize(value);
    if (domain == null || _domains.contains(domain)) return;
    await _save([..._domains, domain]);
  }

  Future<void> _remove(String domain) async {
    _status.remove(domain);
    await _save(_domains.where((item) => item != domain).toList());
  }

  Future<void> _test(String domain) async {
    setState(() => _status[domain] = 'Проверка…');
    final secure = _proxy!.settings['noSecure'] != true;
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await RawWebSocket.connect(
        domain,
        domain,
        secure: secure,
        path: '/apiws?dst=149.154.167.51&dc=2',
        timeout: const Duration(seconds: 8),
      );
      await socket.close();
      if (mounted) {
        setState(
          () => _status[domain] =
              'WebSocket открыт · ${stopwatch.elapsedMilliseconds} мс',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status[domain] = 'Ошибка: $error');
      }
    }
  }

  @override
  Widget? buildFloatingActionButton() => FloatingActionButton.extended(
    onPressed: _add,
    icon: const Icon(Icons.add),
    label: const Text('Добавить'),
  );

  @override
  Widget buildBody() {
    return _domains.isEmpty
        ? const _EmptyState()
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: _domains.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final domain = _domains[index];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(domain),
                  subtitle: Text(_status[domain] ?? 'Не проверен'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Проверить',
                        onPressed: () => _test(domain),
                        icon: const Icon(Icons.wifi_tethering),
                      ),
                      IconButton(
                        tooltip: 'Удалить',
                        onPressed: () => _remove(domain),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
  }
}

String? _normalize(String? value) {
  var domain = value?.trim().toLowerCase() ?? '';
  if (domain.isEmpty) return null;
  domain = domain.replaceFirst(RegExp(r'^[a-z]+://'), '');
  domain = domain.split('/').first;
  return domain.isEmpty ? null : domain;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 56),
            const SizedBox(height: 16),
            Text(
              'Добавьте Worker из CfWorker.md',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Домен вида name.account.workers.dev. '
              'Приложение будет переключаться между ними при сбоях.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _AddWorkerDialog extends StatefulWidget {
  const _AddWorkerDialog();

  @override
  State<_AddWorkerDialog> createState() => _AddWorkerDialogState();
}

class _AddWorkerDialogState extends State<_AddWorkerDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Новый Worker'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          hintText: 'name.account.workers.dev',
          helperText: 'Без https:// и пути',
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
          child: const Text('Добавить'),
        ),
      ],
    );
  }
}
