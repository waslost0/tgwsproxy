// Purpose: Global UI state: database, theme mode, lifecycle.
import 'package:material_ui/material_ui.dart';

import '../db/app_database.dart';

class AppModel extends ChangeNotifier {
  AppModel(this.db);

  final AppDatabase db;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  Future<void> init() async {
    final stored = await db.read('theme_mode');
    _themeMode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await db.write('theme_mode', mode.name);
  }

  @override
  void dispose() {
    db.close();
    super.dispose();
  }
}
