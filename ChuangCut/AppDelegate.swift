import AppKit
import ChuangCutCore
import SwiftUI

@main @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = EditorModel()
    private var editor: EditorWindowController?
    private var settingsWindow: NSWindow?
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        model.openSettings = { [weak self] in self?.showSettings(nil) }
        let editor = EditorWindowController(model: model)
        self.editor = editor
        editor.showWindow(nil)
        model.launchArguments()
    }
    func application(_ application: NSApplication, open urls: [URL]) { if let url = urls.first { model.open(url) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        model.cancel()
        model.finishSaving()
    }
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            func tab(_ label: String, _ symbol: String, _ view: some View) {
                let controller = NSHostingController(rootView: view)
                controller.title = label
                let item = NSTabViewItem(viewController: controller)
                item.label = label
                item.image = .symbol(symbol, label)
                tabs.addTabViewItem(item)
            }
            tab("Models", "cpu", ModelSettingsView())
            tab("Detection", "waveform", DetectionSettingsView())
            tab("Subtitles", "captions.bubble", SubtitleSettingsView(model: model))
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    /// Commands with plain-key shortcuts (Space, arrows, Delete, Escape) are validated against the key
    /// window, so they never fire while Settings or a sheet is taking text input.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        @discardableResult func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func item(
            _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(UInt32(key))!)) }
        let services = item("Services", nil)
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        menu(
            "ChuangCut",
            [
                item("About ChuangCut", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
                item("Settings…", #selector(showSettings(_:)), ","), .separator(), services, .separator(),
                item("Hide ChuangCut", #selector(NSApplication.hide(_:)), "h"),
                item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                item("Show All", #selector(NSApplication.unhideAllApplications(_:))), .separator(),
                item("Quit ChuangCut", #selector(NSApplication.terminate(_:)), "q"),
            ])
        menu(
            "File",
            [
                item("Open…", #selector(EditorWindowController.importVideo(_:)), "o"),
                item("Export…", #selector(EditorWindowController.showExport(_:)), "e", [.command, .shift]),
                .separator(), item("Close", #selector(NSWindow.performClose(_:)), "w"),
            ])
        // undo:/redo: reach the editor window's undo manager, or a text field's own in other windows.
        menu(
            "Edit",
            [
                item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                .separator(), item("Cut", #selector(NSText.cut(_:)), "x"),
                item("Copy", #selector(NSText.copy(_:)), "c"), item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
            ])
        menu("View", [item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        menu(
            "Playback",
            [
                item("Play", #selector(EditorWindowController.togglePlayback(_:)), " ", []),
                item(
                    "Back 5 Seconds", #selector(EditorWindowController.skipBackward(_:)), arrow(NSLeftArrowFunctionKey),
                    []),
                item(
                    "Forward 5 Seconds", #selector(EditorWindowController.skipForward(_:)),
                    arrow(NSRightArrowFunctionKey), []),
                .separator(), item("Split at Playhead", #selector(EditorWindowController.splitAtPlayhead(_:)), "b"),
                item("Remove Selected Clip", #selector(TimelineCanvas.removeSelectedClip(_:)), "\u{8}", []),
                item("Deselect Clip", #selector(TimelineCanvas.deselectClip(_:)), "\u{1b}", []),
            ])
        NSApp.windowsMenu = menu(
            "Window",
            [
                item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                item("Zoom", #selector(NSWindow.performZoom(_:))), .separator(),
                item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
            ])
        NSApp.helpMenu = menu("Help", [])
        return main
    }
}
