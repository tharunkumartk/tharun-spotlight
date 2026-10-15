import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A system-wide hotkey through Carbon's RegisterEventHotKey: no
/// Accessibility permission needed, and the key press never reaches other apps.
final class HotKey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    /// `spec` is like "cmd+space" or "opt+shift+k".
    init?(spec: String, action: @escaping () -> Void) {
        guard let parsed = Self.parse(spec) else { return nil }
        let (code, mods) = parsed
        HotKey.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &type, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x464C_4E43), id: 1) // 'FLNC'
        guard RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        let keys: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "`": kVK_ANSI_Grave,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        var mods = 0
        var code: Int?
        for part in spec.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": mods |= cmdKey
            case "opt", "option", "alt", "⌥": mods |= optionKey
            case "ctrl", "control", "⌃": mods |= controlKey
            case "shift", "⇧": mods |= shiftKey
            default:
                guard let k = keys[part] else { return nil }
                code = k
            }
        }
        guard let c = code, mods != 0 else { return nil }
        return (UInt32(c), UInt32(mods))
    }
}

/// Spotlight owns ⌘Space until its shortcut is turned off.
enum SpotlightShortcut {
    static var shortcutEnabled: Bool {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all["64"] as? [String: Any]
        else { return true } // never changed: on
        return (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let apps = AppCatalog()
    private let fsearch = FSearchClient()
    private let digup = DigUpClient()
    private var launcher: LauncherController!
    private var hotKey: HotKey?
    private var hotKeySpec = "cmd+space"
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        apps.refresh(force: true)
        fsearch.warmUp()
        launcher = LauncherController(apps: apps, fsearch: fsearch, digup: digup)
        setUpStatusItem()

        hotKeySpec = UserDefaults.standard.string(forKey: "Hotkey") ?? "cmd+space"
        hotKey = HotKey(spec: hotKeySpec) { [weak self] in self?.launcher.toggle() }
        if hotKey == nil {
            alert("Couldn't register \(hotKeySpec)",
                  "Another app may be using it. Choose another, e.g.:\n\ndefaults write dev.fastlauncher.app Hotkey \"opt+space\"\n\nthen relaunch FastLauncher.")
        } else if hotKeySpec == "cmd+space", SpotlightShortcut.shortcutEnabled {
            spotlightHelp(firstRun: true)
        }
        if !UserDefaults.standard.bool(forKey: "shownOnce") {
            UserDefaults.standard.set(true, forKey: "shownOnce")
            launcher.show()
        }
    }

    /// Opening the app again (from Finder or Launchpad) shows the launcher.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcher.show()
        return false
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "FastLauncher")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let shortcut = hotKeySpec.replacingOccurrences(of: "cmd", with: "⌘").replacingOccurrences(of: "opt", with: "⌥")
            .replacingOccurrences(of: "ctrl", with: "⌃").replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "space", with: "Space")
        add(menu, "Open FastLauncher   \(shortcut)", #selector(openLauncher))
        menu.addItem(.separator())
        let state = fsearch.problem ?? (fsearch.fullDiskAccess == false
            ? "no Full Disk Access, so Desktop, Documents and Downloads aren't searched" : "connected")
        let status = NSMenuItem(title: "fsearch: \(state)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if fsearch.fullDiskAccess == false {
            add(menu, "Give fsearch Full Disk Access…", #selector(grantAccess))
            add(menu, "Restart fsearch", #selector(restartFSearch))
        }
        let meaning = NSMenuItem(title: "DigUp (search by content): \(digup.status)", action: nil, keyEquivalent: "")
        meaning.isEnabled = false
        menu.addItem(meaning)
        add(menu, "Rescan Applications", #selector(rescan))
        if hotKeySpec == "cmd+space", SpotlightShortcut.shortcutEnabled {
            add(menu, "Free ⌘Space from Spotlight…", #selector(showSpotlightHelp))
        }
        let login = add(menu, "Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "Quit FastLauncher", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openLauncher() { launcher.show() }

    @objc private func rescan() { apps.refresh(force: true) }

    /// Opens the Full Disk Access list with the fsearch binary shown in
    /// Finder, ready to drag in (~/.local is hidden from the + button).
    @objc private func grantAccess() {
        if let bin = fsearch.binary { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bin)]) }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    @objc private func restartFSearch() { fsearch.restartDaemon() }

    @objc private func showSpotlightHelp() { spotlightHelp(firstRun: false) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Launch at Login", "\(error.localizedDescription)\n\nMove FastLauncher to /Applications first, then try again.")
        }
    }

    // MARK: - Alerts

    private func spotlightHelp(firstRun: Bool) {
        if firstRun, UserDefaults.standard.bool(forKey: "spotlightHelpShown") { return }
        UserDefaults.standard.set(true, forKey: "spotlightHelpShown")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Give ⌘Space to FastLauncher"
        a.informativeText = """
            Spotlight is still using ⌘Space. To free it:

            System Settings → Keyboard → Keyboard Shortcuts… → Spotlight → turn off “Show Spotlight search”.

            If ⌘Space still opens Spotlight afterwards, quit FastLauncher from the menu bar and open it again.
            """
        a.addButton(withTitle: "Open Keyboard Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

// A helper that dies (DigUp's search service) must not take us with it
// when we next write to its pipe.
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
