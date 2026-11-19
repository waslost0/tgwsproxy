// Purpose: Talker-powered live log viewer for the proxy engine.
// Talker is built on Flutter Material even though the app uses material_ui.
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as fm;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../core/base/base_page.dart';
import '../../core/proxy/proxy_repository.dart';
import '../../core/theme/app_colors.dart';

/// The rest of the app uses `material_ui`; Talker is built on Flutter's
/// Material. This page therefore supplies its own Theme/Localizations so
/// Talker's AppBar does not crash on the fork's different delegates.
class LogsPage extends BasePage {
  const LogsPage({super.key}) : super(title: 'Логи');

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends BasePageState<LogsPage> {
  @override
  bool get shouldBuildScaffold => false;

  @override
  Widget buildBody() {
    final repository = context.read<ProxyRepository>();
    return Scaffold(
      body: fm.Theme(
        data: fm.ThemeData(
          useMaterial3: true,
          brightness: fm.Brightness.dark,
          colorSchemeSeed: AppColors.telegram,
        ),
        child: TalkerView(
          talker: repository.talker,
          appBarTitle: 'Логи',
          theme: const TalkerScreenTheme(),
          isLogsExpanded: false,
          isLogOrderReversed: true,
        ),
      ),
    );
  }
}
