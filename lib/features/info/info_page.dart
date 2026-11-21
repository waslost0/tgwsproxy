// Purpose: About, version, license and privacy information.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/base/base_page.dart';
import '../../core/platform/windows_updater.dart';
import '../../core/proxy/proxy_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/app_toast.dart';
import '../../core/update/update_checker.dart';

class InfoPage extends BasePage {
  const InfoPage({super.key}) : super(title: 'О приложении');

  @override
  State<InfoPage> createState() => _InfoPageState();
}

class _InfoPageState extends BasePageState<InfoPage> {
  bool _checking = false;

  Future<void> _checkUpdates() async {
    setState(() => _checking = true);
    try {
      final current = await PackageInfo.fromPlatform();
      final release = await UpdateChecker.latest();
      if (!mounted) return;
      if (!UpdateChecker.isNewer(release.version, current.version)) {
        AppToast.showMessage('Установлена последняя версия ${current.version}');
        return;
      }
      final canSelfUpdate =
          Platform.isWindows &&
          !kDebugMode &&
          release.windowsUrl != null &&
          release.sumsUrl != null &&
          UpdateChecker.isOfficialDownload(release.windowsUrl!) &&
          UpdateChecker.isOfficialDownload(release.sumsUrl!);
      if (canSelfUpdate) {
        final shouldUpdate = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Доступно обновление'),
            content: Text(
              'Текущая версия: ${current.version}\n'
              'Новая версия: ${release.version}\n\n'
              'Приложение скачает архив, проверит SHA-256, заменит файлы '
              'и перезапустится. Настройки и секрет сохранятся.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Позже'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Обновить'),
              ),
            ],
          ),
        );
        if (shouldUpdate == true) {
          await _runWindowsUpdate(release);
        }
        return;
      }
      final download = Platform.isAndroid
          ? release.apkUrl != null &&
                    UpdateChecker.isOfficialDownload(release.apkUrl!)
                ? release.apkUrl!
                : release.pageUrl
          : release.pageUrl;
      final shouldOpen = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Доступно обновление'),
          content: Text(
            'Текущая версия: ${current.version}\n'
            'Новая версия: ${release.version}\n\n'
            '${Platform.isAndroid ? 'APK откроется в браузере. После скачивания нажмите «Обновить» — настройки сохранятся.' : 'Откроется страница релизов на GitHub. Скачайте сборку для своей платформы.'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Позже'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Скачать'),
            ),
          ],
        ),
      );
      if (shouldOpen == true) {
        await launchUrl(
          Uri.parse(download),
          mode: LaunchMode.externalApplication,
        );
      }
    } on UpdateCheckException catch (error) {
      if (!mounted) return;
      await _showUpdateError(error.message);
    } catch (error) {
      if (!mounted) return;
      await _showUpdateError('Не удалось проверить обновление: $error');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _runWindowsUpdate(ReleaseInfo release) async {
    final proxy = context.read<ProxyRepository>();
    final status = ValueNotifier<String>('Скачивание…');
    final progress = ValueNotifier<double>(0);
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Обновление'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (context, value, child) => Text(value),
            ),
            const SizedBox(height: 16),
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, value, child) =>
                  LinearProgressIndicator(value: value == 0 ? null : value),
            ),
          ],
        ),
      ),
    );
    try {
      await WindowsUpdater.install(
        zipUrl: release.windowsUrl!,
        sumsUrl: release.sumsUrl!,
        version: release.version,
        resume: proxy.state.running || proxy.state.starting,
        onProgress: (value) {
          progress.value = value;
          status.value = value >= 1
              ? 'Проверка и запуск…'
              : 'Скачивание… ${(value * 100).round()}%';
        },
      );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      await dialog;
    } on WindowsUpdateException catch (error) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      await dialog;
      if (mounted) await _showUpdateError(error.message);
    } catch (error) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      await dialog;
      if (mounted) await _showUpdateError('Не удалось обновить: $error');
    } finally {
      status.dispose();
      progress.dispose();
    }
  }

  Future<void> _showUpdateError(String message) async {
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Проверка не удалась'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Закрыть'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Открыть Releases'),
          ),
        ],
      ),
    );
    if (open == true) {
      await launchUrl(
        Uri.parse(UpdateChecker.releasesPage),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  @override
  Widget buildBody() {
    final context = this.context;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const SizedBox(height: 12),
        Center(
          child: Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.primary, AppColors.tertiary],
              ),
            ),
            child: Icon(Icons.shield, size: 44, color: AppColors.onPrimary),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'TG WS Proxy',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snapshot) {
            final info = snapshot.data;
            return Text(
              info == null
                  ? 'версия …'
                  : '${info.version} (${info.buildNumber})',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            );
          },
        ),
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.system_update_alt),
                title: const Text('Проверить обновление'),
                subtitle: Text(_checking ? 'Проверяем…' : 'GitHub Releases'),
                trailing: _checking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: _checking ? null : _checkUpdates,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.code),
                title: const Text('Лицензия'),
                subtitle: const Text('MIT'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'TG WS Proxy',
                  applicationLegalese: 'MIT · Flowseal / AndMTProto',
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('Архитектура'),
                subtitle: const Text('docs/architecture.md в репозитории'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Приватность', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Text(
                  'Приложение не использует аналитику, Crashlytics, '
                  'рекламу и сторонние backend-сервисы. Настройки хранятся '
                  'локально. Трафик Telegram остаётся зашифрованным '
                  'end-to-end.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Основано на Flowseal/tg-ws-proxy и oruviyex18/AndMTProto. '
          'UI следует конвенциям base-flutter.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.outline),
        ),
      ],
    );
  }
}
