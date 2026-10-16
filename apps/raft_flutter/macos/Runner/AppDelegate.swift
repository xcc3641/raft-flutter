import Cocoa
import FlutterMacOS

protocol RaftPreferencesWindow: AnyObject {
  var canOpenPreferences: Bool { get }
  func openPreferences()
}

@main
class AppDelegate: FlutterAppDelegate, NSMenuItemValidation {
  // Flutter's outlet is weak. Keep the existing window and engine alive when
  // the user closes it, so reopening preserves the current workspace and draft.
  private var retainedMainWindow: NSWindow?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // The nib starts invisible. Show behind existing windows without activation,
    // including when a cold launch finishes after the user has switched apps.
    retainedMainWindow = mainFlutterWindow
    retainedMainWindow?.order(.below, relativeTo: 0)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    return restoreMainWindow() == nil
  }

  private func restoreMainWindow() -> NSWindow? {
    guard let window = retainedMainWindow ?? mainFlutterWindow else { return nil }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    return window
  }

  @objc func showPreferences(_ sender: Any?) {
    guard let target = (retainedMainWindow ?? mainFlutterWindow) as? RaftPreferencesWindow,
      target.canOpenPreferences else { return }
    _ = restoreMainWindow()
    target.openPreferences()
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(showPreferences(_:)) {
      return ((retainedMainWindow ?? mainFlutterWindow) as? RaftPreferencesWindow)?
        .canOpenPreferences ?? false
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
