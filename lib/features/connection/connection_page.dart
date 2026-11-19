// Purpose: Connection screen: start/stop, status, stats.
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/base/base_page.dart';
import '../../core/base/base_page_model_mixin.dart';
import '../../core/proxy/proxy_repository.dart';
import 'connection_wm.dart';
import 'widgets/connection_feedback.dart';
import 'widgets/connection_metrics.dart';
import 'widgets/connection_style.dart';
import 'widgets/hero_card.dart';
import 'widgets/status_chip.dart';

class ConnectionPage extends BasePage {
  const ConnectionPage({super.key}) : super(title: 'TG WS Proxy');

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends BasePageState<ConnectionPage>
    with BasePageModelMixin<ConnectionPage, ConnectionWM> {
  @override
  bool get extendBodyBehindAppBar => true;

  @override
  ConnectionWM createModel() => ConnectionWM(context.read<ProxyRepository>());

  @override
  PreferredSizeWidget? buildAppBar() {
    return AppBar(
      backgroundColor: Colors.transparent,
      title: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: LinearGradient(
                colors: [AppColors.primary, AppColors.secondary],
              ),
            ),
            child: Icon(
              Icons.bolt_rounded,
              size: 19,
              color: AppColors.onPrimary,
            ),
          ),
          const SizedBox(width: 10),
          const Text('TG WS Proxy'),
        ],
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(child: StatusChip(status: model.status)),
        ),
      ],
    );
  }

  @override
  Widget buildBody() {
    final running = model.status == ProxyStatus.running;
    final busy =
        model.status == ProxyStatus.starting ||
        model.status == ProxyStatus.stopping;

    return Stack(
      children: [
        const Positioned.fill(child: AuroraGlow()),
        ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            MediaQuery.paddingOf(context).top + 84,
            20,
            32,
          ),
          children: [
            if (model.secretMigrated) ...[
              Card(
                color: AppColors.surfaceLow,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Секрет прокси обновлён',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Старая ссылка больше не работает. '
                        'Добавьте прокси в Telegram заново.',
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          FilledButton(
                            onPressed: () => context
                                .read<ProxyRepository>()
                                .openInTelegram(),
                            child: const Text('Открыть в Telegram'),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: model.acknowledgeSecretMigration,
                            child: const Text('Понятно'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            HeroCard(
              running: running,
              busy: busy,
              status: model.status,
              onToggle: model.toggle,
            ),
            if (running) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () =>
                          context.read<ProxyRepository>().openInTelegram(),
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Открыть в Telegram'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    tooltip: 'Скопировать ссылку',
                    onPressed: () async {
                      final link = context.read<ProxyRepository>().link;
                      await Clipboard.setData(ClipboardData(text: link));
                      if (mounted) showMessage('Ссылка скопирована');
                    },
                    icon: const Icon(Icons.link_rounded),
                  ),
                ],
              ),
            ],
            if (model.error != null) ...[
              const SizedBox(height: 12),
              ErrorBanner(text: model.error!),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: MetricTile(
                    label: 'СОЕДИНЕНИЯ',
                    value: '${model.connections}',
                    icon: Icons.hub_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: MetricTile(
                    label: 'МАРШРУТ',
                    value: model.route,
                    icon: Icons.route_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: MetricTile(
                    label: 'ПРИНЯТО',
                    value: formatBytes(model.bytesUp),
                    icon: Icons.south_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: MetricTile(
                    label: 'ОТДАНО',
                    value: formatBytes(model.bytesDown),
                    icon: Icons.north_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AddressPill(address: model.address),
            const SizedBox(height: 14),
            Text('КАК ПОДКЛЮЧИТЬ', style: eyebrowTextStyle()),
            const SizedBox(height: 10),
            const StepsCard(),
          ],
        ),
      ],
    );
  }
}
