#include "windows_notifications.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <propkey.h>
#include <propvarutil.h>
#include <winrt/Windows.UI.Notifications.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>

#include <chrono>
#include <string>
#include <vector>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;

std::wstring ExecutablePath() {
  std::vector<wchar_t> path(32768);
  const auto length = GetModuleFileNameW(nullptr, path.data(),
                                       static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    throw winrt::hresult_error(E_FAIL);
  }
  return std::wstring(path.data(), length);
}

std::string AppId(const EncodableValue* argument) {
  const auto id = argument ? std::get_if<std::string>(argument) : nullptr;
  if (!id || (*id != "app.raft.raft_flutter" &&
              *id != "app.raft.raft_flutter.notificationlab")) {
    throw winrt::hresult_error(E_INVALIDARG);
  }
  return *id;
}

// Unpackaged desktop toasts need a Start Menu link with both the AUMID and
// activator CLSID. The link and COM server contain only this executable path.
void RegisterShortcut(const std::wstring& executable, const std::string& id,
                      const GUID& guid) {
  PWSTR programs = nullptr;
  winrt::check_hresult(SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_CREATE,
                                          nullptr, &programs));
  const std::wstring folder = std::wstring(programs) +
      (id == "app.raft.raft_flutter.notificationlab"
          ? L"\\Raft Flutter notification lab" : L"\\Raft Flutter");
  CoTaskMemFree(programs);
  if (!CreateDirectoryW(folder.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    winrt::throw_last_error();
  }
  winrt::com_ptr<IShellLinkW> link;
  winrt::check_hresult(CoCreateInstance(CLSID_ShellLink, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(link.put())));
  winrt::check_hresult(link->SetPath(executable.c_str()));
  const auto directory = executable.substr(0, executable.find_last_of(L"\\/"));
  winrt::check_hresult(link->SetWorkingDirectory(directory.c_str()));
  winrt::check_hresult(link->SetIconLocation(executable.c_str(), 0));
  const auto properties = link.as<IPropertyStore>();
  PROPVARIANT value;
  winrt::check_hresult(InitPropVariantFromString(winrt::to_hstring(id).c_str(), &value));
  auto status = properties->SetValue(PKEY_AppUserModel_ID, value);
  PropVariantClear(&value);
  winrt::check_hresult(status);
  winrt::check_hresult(InitPropVariantFromCLSID(guid, &value));
  status = properties->SetValue(PKEY_AppUserModel_ToastActivatorCLSID, value);
  PropVariantClear(&value);
  winrt::check_hresult(status);
  winrt::check_hresult(properties->Commit());
  winrt::check_hresult(link.as<IPersistFile>()->Save((folder + L"\\Raft.lnk").c_str(), TRUE));
}

bool NotificationPermission(const std::string& id) {
  using namespace winrt::Windows::UI::Notifications;
  const auto app_id = winrt::to_hstring(id);
  const auto notifier = ToastNotificationManager::CreateToastNotifier(app_id);
  try {
    return notifier.Setting() == NotificationSetting::Enabled;
  } catch (const winrt::hresult_error& error) {
    if (error.code() != HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) throw;
    // Windows only exposes Setting after an unpackaged app's first toast.
    // Match CommunityToolkit's PreRegisterIdentityLessApp: no popup, no private
    // content, short expiry, immediate removal, then read the real OS setting.
    winrt::Windows::Data::Xml::Dom::XmlDocument xml;
    xml.LoadXml(L"<toast><visual><binding template='ToastGeneric'>"
                L"<text>Raft</text></binding></visual></toast>");
    ToastNotification registration(xml);
    registration.SuppressPopup(true);
    registration.Tag(L"raft-registration");
    registration.Group(L"RaftRegistration");
    registration.ExpirationTime(winrt::clock::now() + std::chrono::seconds(15));
    notifier.Show(registration);
    ToastNotificationManager::History().Remove(
        registration.Tag(), registration.Group(), app_id);
    return notifier.Setting() == NotificationSetting::Enabled;
  }
}

std::string Configure(const EncodableValue* argument, HWND window) {
  const auto values = argument ? std::get_if<EncodableMap>(argument) : nullptr;
  if (!values) throw winrt::hresult_error(E_INVALIDARG);
  const auto id = AppId(&values->at(EncodableValue("appId")));
  const auto& guid = std::get<std::string>(values->at(EncodableValue("guid")));
  const auto expected_guid = id == "app.raft.raft_flutter.notificationlab"
      ? "c7f8c268-2e7c-5079-9305-1a7294c70d9d"
      : "b951813c-37ff-5d5c-95ac-f9573572c87c";
  if (guid != expected_guid) throw winrt::hresult_error(E_INVALIDARG);
  const std::wstring clsid = L"{" + std::wstring(winrt::to_hstring(guid)) + L"}";
  GUID validated_guid;
  winrt::check_hresult(CLSIDFromString(clsid.c_str(), &validated_guid));
  const auto executable = ExecutablePath();
  RegisterShortcut(executable, id, validated_guid);
  const auto command = L"\"" + executable + L"\" --notification-activation";
  const auto key_path = L"Software\\Classes\\CLSID\\" + clsid + L"\\LocalServer32";
  HKEY key = nullptr;
  winrt::check_win32(RegCreateKeyExW(HKEY_CURRENT_USER, key_path.c_str(), 0,
                                   nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr));
  auto status = RegSetValueExW(key, nullptr, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(command.c_str()),
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  if (status == ERROR_SUCCESS) {
    status = RegSetValueExW(key, L"ServerExecutable", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(executable.c_str()),
        static_cast<DWORD>((executable.size() + 1) * sizeof(wchar_t)));
  }
  RegCloseKey(key);
  winrt::check_win32(status);
  winrt::check_hresult(SetCurrentProcessExplicitAppUserModelID(
      winrt::to_hstring(id).c_str()));
  if (id == "app.raft.raft_flutter.notificationlab") {
    SetWindowTextW(window, L"Raft notification lab");
  }
  const auto directory = executable.substr(0, executable.find_last_of(L"\\/"));
  return winrt::to_string(directory + L"\\raft.ico");
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<EncodableValue>>
CreateWindowsNotificationsChannel(flutter::BinaryMessenger* messenger,
                                  HWND window) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "app.raft/windows-notifications",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [window](const auto& call, auto result) {
        try {
          if (call.method_name() == "configure") {
            result->Success(EncodableValue(Configure(call.arguments(), window)));
          } else if (call.method_name() == "configureSdk") {
            const auto icon = Configure(call.arguments(), window);
            const auto values = std::get_if<EncodableMap>(call.arguments());
            InitializeWindowsNotificationSdk(
                AppId(&values->at(EncodableValue("appId"))), icon);
            result->Success();
          } else if (call.method_name() == "show") {
            ShowWindowsSdkNotification(call.arguments());
            result->Success();
          } else if (call.method_name() == "cancelAll") {
            ClearWindowsSdkNotifications();
            result->Success();
          } else if (call.method_name() == "takeActivations") {
            result->Success(EncodableValue(TakeWindowsNotificationActivations()));
          } else if (call.method_name() == "permission") {
            const auto id = AppId(call.arguments());
            result->Success(EncodableValue(NotificationPermission(id)));
          } else if (call.method_name() == "isActive") {
            const HWND foreground = GetForegroundWindow();
            DWORD process_id = 0;
            if (foreground != nullptr) {
              GetWindowThreadProcessId(foreground, &process_id);
            }
            result->Success(EncodableValue(
                foreground != nullptr && process_id == GetCurrentProcessId()));
          } else if (call.method_name() == "present") {
            ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
            SetForegroundWindow(window);
            result->Success();
          } else if (call.method_name() == "labHistory") {
            // The synthetic smoke host may inspect only its own identity.
            result->Success(EncodableValue(static_cast<int32_t>(
                winrt::Windows::UI::Notifications::ToastNotificationManager::
                    History().GetHistory(
                        L"app.raft.raft_flutter.notificationlab").Size())));
          } else {
            result->NotImplemented();
          }
        } catch (const winrt::hresult_error& error) {
          result->Error("windows-notifications-unavailable",
                        "Windows notification settings could not be accessed.",
                        EncodableValue(static_cast<int64_t>(error.code().value)));
        } catch (...) {
          result->Error("windows-notifications-unavailable",
                        "Windows notification settings could not be accessed.");
        }
      });
  return channel;
}
