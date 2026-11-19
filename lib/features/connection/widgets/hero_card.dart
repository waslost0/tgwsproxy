// Purpose: Connection hero card with the animated tunnel orb.
import '../../../core/theme/app_colors.dart';

import 'package:material_ui/material_ui.dart';

import '../connection_wm.dart';
import 'tunnel_orb.dart';
import 'connection_style.dart';

class HeroCard extends StatelessWidget {
  const HeroCard({
    super.key,
    required this.running,
    required this.busy,
    required this.status,
    required this.onToggle,
  });

  final bool running;
  final bool busy;
  final ProxyStatus status;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = busy
        ? 'Подключаемся…'
        : running
        ? 'Туннель активен'
        : 'Туннель выключен';
    final subtitle = running
        ? 'Трафик Telegram идёт через защищённый WebSocket.'
        : 'Запустите локальный прокси и откройте ссылку в Telegram.';

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withValues(alpha: running ? 0.18 : 0.07),
            AppColors.secondary.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: running ? 0.35 : 0.16),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text('MT PROTO RELAY', style: eyebrowTextStyle()),
              const Spacer(),
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: running ? AppColors.primary : AppColors.outline,
                  boxShadow: running
                      ? [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.6),
                            blurRadius: 10,
                          ),
                        ]
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TunnelOrb(active: running, busy: busy, status: status),
          const SizedBox(height: 6),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : onToggle,
              style: FilledButton.styleFrom(
                backgroundColor: running
                    ? AppColors.secondary
                    : AppColors.primary,
                foregroundColor: running
                    ? AppColors.onSecondary
                    : AppColors.onPrimary,
              ),
              icon: busy
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.onPrimary,
                      ),
                    )
                  : Icon(
                      running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    ),
              label: Text(
                busy
                    ? 'Подождите…'
                    : running
                    ? 'Остановить'
                    : 'Запустить',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AuroraGlow extends StatelessWidget {
  const AuroraGlow({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: -110,
            right: -90,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.18),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 80,
            left: -120,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.secondary.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
