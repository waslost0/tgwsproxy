// Purpose: Connection status capsule.
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_colors.dart';
import '../connection_wm.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.status});

  final ProxyStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ProxyStatus.stopped => ('Остановлен', AppColors.outline),
      ProxyStatus.starting => ('Запуск', AppColors.tertiary),
      ProxyStatus.running => ('Активен', AppColors.primary),
      ProxyStatus.stopping => ('Остановка', AppColors.tertiary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
