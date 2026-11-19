// Purpose: app-wide toast facade. Keeps widgets free of ScaffoldMessenger
// boilerplate and gives every screen the same message styling.
import 'package:bot_toast/bot_toast.dart';
import 'package:material_ui/material_ui.dart';

class AppToast {
  const AppToast._();

  static const _infoBackground = Color(0xFF62F5C8);
  static const _errorBackground = Color(0xFFFF7A7A);
  static const _foreground = Color(0xFF071018);

  static void showMessage(
    String? message, {
    bool isError = false,
    bool onlyOne = true,
  }) {
    if (message == null || message.isEmpty) return;
    BotToast.showCustomText(
      duration: const Duration(seconds: 4),
      align: Alignment.bottomCenter,
      onlyOne: onlyOne,
      toastBuilder: (_) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isError ? _errorBackground : _infoBackground,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Text(
          message,
          style: const TextStyle(
            color: _foreground,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  static void showError(String? message, {bool onlyOne = true}) {
    showMessage(message, isError: true, onlyOne: onlyOne);
  }
}
