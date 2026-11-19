// Purpose: GoRouter with the four-tab StatefulShellRoute.
import 'package:bot_toast/bot_toast.dart';
import 'package:go_router/go_router.dart';

import '../../features/connection/connection_page.dart';
import '../../features/info/info_page.dart';
import '../../features/logs/logs_page.dart';
import '../../features/settings/dc_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/settings/workers_page.dart';
import '../ui/main_shell.dart';

final appRouter = GoRouter(
  initialLocation: '/connection',
  observers: [BotToastNavigatorObserver()],
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          MainShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/connection',
              builder: (context, state) => const ConnectionPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsPage(),
              routes: [
                GoRoute(
                  path: 'workers',
                  builder: (context, state) => const WorkersPage(),
                ),
                GoRoute(
                  path: 'dc',
                  builder: (context, state) => const DcPage(),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/logs',
              builder: (context, state) => const LogsPage(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/info',
              builder: (context, state) => const InfoPage(),
            ),
          ],
        ),
      ],
    ),
  ],
);
