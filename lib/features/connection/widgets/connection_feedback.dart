// Purpose: Connection error banner and setup steps.
import '../../../core/theme/app_colors.dart';

import 'package:material_ui/material_ui.dart';

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.errorContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: AppColors.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: AppColors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class StepsCard extends StatelessWidget {
  const StepsCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceLow.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: const Column(
        children: [
          StepItem(
            number: '01',
            title: 'Запустите туннель',
            text: 'Локальный прокси слушает только 127.0.0.1.',
          ),
          Divider(height: 1, indent: 18, endIndent: 18),
          StepItem(
            number: '02',
            title: 'Откройте ссылку',
            text: 'Telegram добавит прокси автоматически.',
          ),
          Divider(height: 1, indent: 18, endIndent: 18),
          StepItem(
            number: '03',
            title: 'Проверьте маршрут',
            text: 'Cloudflare Worker или домен, затем DC Telegram.',
          ),
        ],
      ),
    );
  }
}

class StepItem extends StatelessWidget {
  const StepItem({
    super.key,
    required this.number,
    required this.title,
    required this.text,
  });

  final String number;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            number,
            style: TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyle(
                    color: AppColors.onSurfaceVariant,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
