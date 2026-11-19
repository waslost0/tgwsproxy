// Purpose: compact section heading used by the settings screen.
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_colors.dart';

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge
            ?.copyWith(color: AppColors.primary, fontWeight: FontWeight.w700),
      ),
    );
  }
}
