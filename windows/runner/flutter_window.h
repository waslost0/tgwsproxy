#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <memory>
#include <string>

#include "win32_window.h"

// A window that hosts the Flutter view and a notification-area (tray) icon.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void CreateTrayIcon();
  void RemoveTrayIcon();
  void UpdateTray();
  void ShowTrayMenu();
  void ShowFromTray();
  void HideToTray();
  void CopyLinkToClipboard();
  void InvokeDart(const char* method);
  void HandleMenuCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Mirrors the Dart-side menu channel used by the macOS menu bar.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      menu_channel_;

  NOTIFYICONDATAW tray_icon_{};
  bool tray_added_ = false;
  bool close_hint_shown_ = false;
  bool force_close_ = false;
  bool running_ = false;
  bool starting_ = false;
  int port_ = 1443;
  std::wstring link_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
