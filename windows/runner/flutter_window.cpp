#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <strsafe.h>

#include <cstring>
#include <optional>
#include <string>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;

constexpr UINT kTrayMenuToggle = 1001;
constexpr UINT kTrayMenuOpenTelegram = 1002;
constexpr UINT kTrayMenuCopyLink = 1003;
constexpr UINT kTrayMenuShow = 1004;
constexpr UINT kTrayMenuExit = 1005;

constexpr char kMenuChannelName[] = "com.whitetigersoft.tgwsproxy/menu";

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                                         static_cast<int>(value.size()),
                                         nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                        static_cast<int>(value.size()), result.data(), size);
  return result;
}

const flutter::EncodableValue* FindValue(const flutter::EncodableMap& map,
                                         const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

bool ReadBool(const flutter::EncodableMap& map, const char* key,
              bool fallback) {
  const flutter::EncodableValue* value = FindValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* boolean = std::get_if<bool>(value)) {
    return *boolean;
  }
  return fallback;
}

int ReadInt(const flutter::EncodableMap& map, const char* key, int fallback) {
  const flutter::EncodableValue* value = FindValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* number = std::get_if<int32_t>(value)) {
    return *number;
  }
  if (const auto* number = std::get_if<int64_t>(value)) {
    return static_cast<int>(*number);
  }
  return fallback;
}

std::string ReadString(const flutter::EncodableMap& map, const char* key,
                       const std::string& fallback) {
  const flutter::EncodableValue* value = FindValue(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* text = std::get_if<std::string>(value)) {
    return *text;
  }
  return fallback;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // The Dart backend pushes proxy state here and receives tray commands.
  menu_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), kMenuChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  menu_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMenuCall(call, std::move(result)); });

  CreateTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (menu_channel_) {
    menu_channel_->SetMethodCallHandler(nullptr);
    menu_channel_.reset();
  }
  RemoveTrayIcon();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kTrayCallbackMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONDBLCLK:
      case WM_LBUTTONUP:
        ShowFromTray();
        break;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowTrayMenu();
        break;
    }
    return 0;
  }

  // Closing the window keeps the proxy alive in the notification area, like
  // the macOS menu-bar build. "Exit" in the tray menu really quits.
  if (message == WM_CLOSE && !force_close_) {
    HideToTray();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::CreateTrayIcon() {
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(tray_icon_);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = 1;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_.hIcon = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  StringCchCopyW(tray_icon_.szTip, ARRAYSIZE(tray_icon_.szTip),
                 L"TG WS Proxy — прокси выключен");
  tray_added_ = ::Shell_NotifyIconW(NIM_ADD, &tray_icon_) != FALSE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_added_) {
    ::Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
    tray_added_ = false;
  }
  if (tray_icon_.hIcon != nullptr) {
    ::DestroyIcon(tray_icon_.hIcon);
    tray_icon_.hIcon = nullptr;
  }
}

void FlutterWindow::UpdateTray() {
  if (!tray_added_) {
    return;
  }
  std::wstring status;
  if (starting_) {
    status = L"TG WS Proxy — запуск…";
  } else if (running_) {
    status = L"TG WS Proxy — включён :" + std::to_wstring(port_);
  } else {
    status = L"TG WS Proxy — выключен";
  }
  StringCchCopyW(tray_icon_.szTip, ARRAYSIZE(tray_icon_.szTip),
                 status.c_str());
  tray_icon_.uFlags = NIF_TIP;
  ::Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  std::wstring status;
  if (starting_) {
    status = L"Запуск…";
  } else if (running_) {
    status = L"Прокси включён :" + std::to_wstring(port_);
  } else {
    status = L"Прокси выключен";
  }

  ::AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, status.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING | (starting_ ? MF_GRAYED : 0),
                kTrayMenuToggle, running_ ? L"Отключить" : L"Подключить");
  ::AppendMenuW(menu, MF_STRING, kTrayMenuOpenTelegram, L"Открыть Telegram");
  ::AppendMenuW(menu, MF_STRING | (link_.empty() ? MF_GRAYED : 0),
                kTrayMenuCopyLink, L"Скопировать ссылку");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kTrayMenuShow, L"Открыть приложение");
  ::AppendMenuW(menu, MF_STRING, kTrayMenuExit, L"Выход");

  POINT cursor;
  ::GetCursorPos(&cursor);
  ::SetForegroundWindow(GetHandle());
  const UINT command = static_cast<UINT>(::TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY, cursor.x, cursor.y, 0, GetHandle(),
      nullptr));
  ::DestroyMenu(menu);
  // Required by the shell so the menu closes correctly on the next click.
  ::PostMessage(GetHandle(), WM_NULL, 0, 0);

  switch (command) {
    case kTrayMenuToggle:
      InvokeDart("toggle");
      break;
    case kTrayMenuOpenTelegram:
      InvokeDart("openTelegram");
      break;
    case kTrayMenuCopyLink:
      CopyLinkToClipboard();
      break;
    case kTrayMenuShow:
      ShowFromTray();
      break;
    case kTrayMenuExit:
      force_close_ = true;
      ::DestroyWindow(GetHandle());
      break;
    default:
      break;
  }
}

void FlutterWindow::ShowFromTray() {
  ::ShowWindow(GetHandle(), SW_RESTORE);
  ::SetForegroundWindow(GetHandle());
}

void FlutterWindow::HideToTray() {
  ::ShowWindow(GetHandle(), SW_HIDE);
  if (close_hint_shown_ || !tray_added_) {
    return;
  }
  close_hint_shown_ = true;
  StringCchCopyW(tray_icon_.szInfoTitle, ARRAYSIZE(tray_icon_.szInfoTitle),
                 L"TG WS Proxy");
  StringCchCopyW(tray_icon_.szInfo, ARRAYSIZE(tray_icon_.szInfo),
                 L"Приложение свёрнуто в трей. Прокси продолжает работать.");
  tray_icon_.uFlags = NIF_INFO;
  tray_icon_.dwInfoFlags = NIIF_INFO;
  ::Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
}

void FlutterWindow::CopyLinkToClipboard() {
  if (link_.empty() || !::OpenClipboard(GetHandle())) {
    return;
  }
  ::EmptyClipboard();
  const size_t bytes = (link_.size() + 1) * sizeof(wchar_t);
  HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (memory != nullptr) {
    void* data = ::GlobalLock(memory);
    if (data != nullptr) {
      std::memcpy(data, link_.c_str(), bytes);
      ::GlobalUnlock(memory);
      if (::SetClipboardData(CF_UNICODETEXT, memory) == nullptr) {
        ::GlobalFree(memory);
      }
    } else {
      ::GlobalFree(memory);
    }
  }
  ::CloseClipboard();
}

void FlutterWindow::InvokeDart(const char* method) {
  if (menu_channel_) {
    menu_channel_->InvokeMethod(method,
                                std::make_unique<flutter::EncodableValue>());
  }
}

void FlutterWindow::HandleMenuCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "state") {
    result->NotImplemented();
    return;
  }

  const auto* arguments = call.arguments();
  const auto* map = arguments == nullptr
                        ? nullptr
                        : std::get_if<flutter::EncodableMap>(arguments);
  if (map == nullptr) {
    result->Success();
    return;
  }

  running_ = ReadBool(*map, "running", running_);
  starting_ = ReadBool(*map, "starting", starting_);
  port_ = ReadInt(*map, "port", port_);
  link_ = Utf8ToWide(ReadString(*map, "link", std::string()));
  UpdateTray();
  result->Success();
}
