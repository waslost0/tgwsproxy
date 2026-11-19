// Purpose: Settings screen for UI and proxy options.
import 'dart:io';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/base/base_page.dart';
import '../../core/base/base_page_model_mixin.dart';
import '../../core/model/app_model.dart';
import '../../core/proxy/proxy_repository.dart';
import '../../core/ui/app_toast.dart';
import 'settings_wm.dart';
import 'widgets/address_dialog.dart';
import 'widgets/domain_dialog.dart';
import 'widgets/port_dialog.dart';
import 'widgets/section_title.dart';
import 'widgets/secret_dialog.dart';
import 'widgets/settings_dialogs.dart';

class SettingsPage extends BasePage {
  const SettingsPage({super.key}) : super(title: 'Настройки');

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends BasePageState<SettingsPage>
    with BasePageModelMixin<SettingsPage, SettingsWM> {
  @override
  SettingsWM createModel() =>
      SettingsWM(context.read<AppModel>().db, context.read<ProxyRepository>())
        ..load();

  @override
  Widget buildBody() {
    final app = context.watch<AppModel>();
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        SectionTitle('Оформление'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Тема', style: theme.textTheme.titleSmall),
                const SizedBox(height: 12),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('Система'),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      label: Text('Светлая'),
                    ),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Тёмная')),
                  ],
                  selected: {app.themeMode},
                  onSelectionChanged: (value) => app.setThemeMode(value.first),
                  showSelectedIcon: false,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        SectionTitle('Приложение'),
        Card(
          child: Column(
            children: [
              if (!Platform.isMacOS) ...[
                SwitchListTile(
                  value: model.autoStart,
                  onChanged: model.setAutoStart,
                  secondary: const Icon(Icons.power_settings_new),
                  title: const Text('Запускать при загрузке'),
                  subtitle: const Text('После первой разблокировки устройства'),
                ),
                const Divider(height: 1),
              ],
              SwitchListTile(
                value: model.checkUpdates,
                onChanged: model.setCheckUpdates,
                secondary: const Icon(Icons.system_update),
                title: const Text('Проверять обновления'),
                subtitle: const Text('Раз в сутки, через GitHub Releases'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionTitle('Прокси'),
        Card(
          color: AppColors.surfaceLow,
          child: Column(
            children: [
              SwitchListTile(
                value: model.noSecure,
                onChanged: model.setNoSecure,
                secondary: const Icon(Icons.lock_open_outlined),
                title: const Text('Без TLS (порт 80)'),
                subtitle: const Text(
                  'Если провайдер блокирует Cloudflare по TLS. '
                  'Соединение остаётся внутри MTProto.',
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('Секрет прокси'),
                subtitle: Text(
                  model.proxy.secret.isEmpty
                      ? 'Скрыт'
                      : '${'•' * 8}  '
                            '${model.proxy.secret.length >= 4 ? model.proxy.secret.substring(model.proxy.secret.length - 4) : model.proxy.secret}',
                ),
                trailing: const Icon(Icons.visibility_outlined),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => SecretDialog(proxy: model.proxy),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: const Text('DC → IP'),
                subtitle: Text(
                  model.dcRedirects.isEmpty
                      ? 'Стандартные адреса Telegram'
                      : model.dcRedirects.entries
                            .map((entry) => 'DC${entry.key}')
                            .join(', '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await context.push('/settings/dc');
                  await model.load();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.wifi_tethering),
                title: const Text('Локальный адрес'),
                subtitle: Text('${model.host}:${model.port}'),
                trailing: const Icon(Icons.tune),
                onTap: () => AddressDialog.edit(
                  context,
                  host: model.host,
                  port: model.port,
                  onSave: model.setAddress,
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('Свой домен Cloudflare'),
                subtitle: Text(
                  model.cfDomain.isEmpty
                      ? 'По умолчанию (может быть недоступен)'
                      : model.cfDomain,
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => DomainDialog.edit(
                  context,
                  title: 'Домен Cloudflare',
                  hint: 'example.com',
                  helper: 'Без kws2. и без https://',
                  initial: model.cfDomain,
                  onSave: model.setCfDomain,
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Свои Cloudflare Workers'),
                subtitle: Text(
                  model.workerDomains.isEmpty
                      ? 'Не заданы (рекомендуется)'
                      : model.workerDomains,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await context.push('/settings/workers');
                  await model.load();
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: model.cfWorkerEnabled,
                onChanged: model.setCfWorkerEnabled,
                secondary: const Icon(Icons.alt_route),
                title: const Text('Использовать свои Workers'),
                subtitle: const Text(
                  'Выключено — общий CF proxy, как в AndMTProto. '
                  'Включайте, только если Worker быстрее.',
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Сбросить на shared CF'),
                subtitle: const Text(
                  'Общий Cloudflare по порту 80, без своих доменов и Workers — как в AndMTProto.',
                ),
                trailing: const Icon(Icons.restart_alt),
                onTap: model.useSharedRoute,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.hub_outlined),
                title: const Text('WebSocket pool'),
                subtitle: Text('Размер пула: ${model.poolSize}'),
                trailing: const Icon(Icons.tune),
                onTap: () => PortDialog.edit(
                  context,
                  title: 'WebSocket pool',
                  initial: model.poolSize,
                  max: 16,
                  helper: '1–16. По умолчанию 4.',
                  onSave: model.setPoolSize,
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.theater_comedy_outlined),
                title: const Text('Fake TLS домен'),
                subtitle: Text(
                  model.fakeTlsDomain.isEmpty
                      ? 'Не задан'
                      : model.fakeTlsDomain,
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => DomainDialog.edit(
                  context,
                  title: 'Fake TLS домен',
                  hint: 'example.com',
                  helper: 'Маскировка MTProto под TLS. Без https://',
                  initial: model.fakeTlsDomain,
                  onSave: model.setFakeTlsDomain,
                ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: model.forceTestDc,
                onChanged: model.setForceTestDc,
                secondary: const Icon(Icons.science_outlined),
                title: const Text('Force test DC'),
                subtitle: const Text(
                  'Только для отладки: тестовые DC Telegram',
                ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: model.proxyProtocol,
                onChanged: model.setProxyProtocol,
                secondary: const Icon(Icons.swap_vert),
                title: const Text('PROXY protocol'),
                subtitle: const Text(
                  'Принимать строку PROXY от внешнего балансировщика',
                ),
              ),
              if (model.botApiSupported) ...[
                const Divider(height: 1),
                SwitchListTile(
                  value: model.botApiEnabled,
                  onChanged: model.setBotApiEnabled,
                  secondary: const Icon(Icons.smart_toy_outlined),
                  title: const Text('Bot API'),
                  subtitle: Text(
                    'Локальный туннель для api.telegram.org · '
                    '127.0.0.1:${model.botApiPort}',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.numbers),
                  title: const Text('Порт Bot API'),
                  subtitle: Text('${model.botApiPort}'),
                  trailing: const Icon(Icons.tune),
                  onTap: () => PortDialog.edit(
                    context,
                    title: 'Порт Bot API',
                    initial: model.botApiPort,
                    max: 65535,
                    helper: 'Локальный порт, по умолчанию 8081.',
                    onSave: model.setBotApiPort,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionTitle('Сервис'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.monitor_heart_outlined),
                title: const Text('Диагностика'),
                subtitle: Text(
                  Platform.isMacOS
                      ? 'Версия, macOS и состояние'
                      : 'Версия, Android, ABI и состояние',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showDiagnosticsDialog(context, model.proxy),
              ),
              const Divider(height: 1),
              if (!Platform.isMacOS) ...[
                ListTile(
                  leading: const Icon(Icons.battery_saver_outlined),
                  title: const Text('Энергосбережение'),
                  subtitle: const Text('Разрешить работу в фоне'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: model.proxy.openBatterySettings,
                ),
                const Divider(height: 1),
              ],
              ListTile(
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Экспорт настроек'),
                subtitle: const Text('Скопировать JSON в буфер'),
                onTap: () async {
                  final json = await model.proxy.exportSettings();
                  if (!mounted) return;
                  await showExportSettingsDialog(context, json);
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Импорт настроек'),
                subtitle: const Text('Вставить JSON из экспорта'),
                onTap: () async {
                  final raw = await showImportSettingsDialog(context);
                  if (raw == null || raw.trim().isEmpty) return;
                  final ok = await model.proxy.importSettings(raw);
                  if (!mounted) return;
                  if (ok) {
                    await model.load();
                    if (!mounted) return;
                    AppToast.showMessage('Настройки импортированы');
                  } else {
                    AppToast.showError('Не удалось импортировать настройки');
                  }
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.construction, color: AppColors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Встроенные домены Cloudflare больше не отвечают. '
                    'Разверните свой Worker по CfWorker.md и укажите его '
                    'домен — это самый надёжный маршрут.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
