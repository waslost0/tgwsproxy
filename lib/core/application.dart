// Purpose: Root MaterialApp.router, theme, locale, router.
// Talker's Flutter Material widgets need Flutter's own localization
// delegates in addition to the material_ui fork delegates.
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter_localizations/flutter_localizations.dart' as fl;
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart'
    show GlobalCupertinoLocalizations;
import 'package:provider/provider.dart';

import 'model/app_model.dart';
import '../app_router.dart';
import 'theme/app_colors.dart';
import 'theme/theme_builder.dart';

class TgWsProxyApp extends StatelessWidget {
  const TgWsProxyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppModel>(
      builder: (context, app, _) {
        final systemBrightness =
            WidgetsBinding.instance.platformDispatcher.platformBrightness;
        AppColors.useBrightness(switch (app.themeMode) {
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
          ThemeMode.system => systemBrightness,
        });
        return MaterialApp.router(
          title: 'TG WS Proxy',
          debugShowCheckedModeBanner: false,
          theme: ThemeBuilder.light(),
          darkTheme: ThemeBuilder.dark(),
          themeMode: app.themeMode,
          routerConfig: appRouter,
          builder: BotToastInit(),
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            fl.GlobalWidgetsLocalizations.delegate,
            // Talker uses Flutter's Material types, so the fork delegate alone
            // does not satisfy its AppBar.
            // ignore: deprecated_member_use
            fl.GlobalMaterialLocalizations.delegate,
          ],
        );
      },
    );
  }
}
