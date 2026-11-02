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
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if url.pathExtension == ProjectPackage.pathExtension { model.openProject(url) } else { model.open(url) }
    }
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
            tab(L10n.Settings.transcription, "text.bubble", TranscriptionSettingsView())
            tab(L10n.Settings.detection, "waveform", DetectionSettingsView())
            tab(L10n.Settings.subtitles, "captions.bubble", SubtitleSettingsView(model: model))
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
        let services = item(L10n.App.services, nil)
        services.submenu = NSMenu(title: L10n.App.services)
        NSApp.servicesMenu = services.submenu
        menu(
            L10n.App.name,
            [
                item(L10n.App.about, #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
                item(L10n.App.settings, #selector(showSettings(_:)), ","), .separator(), services, .separator(),
                item(L10n.App.hide, #selector(NSApplication.hide(_:)), "h"),
                item(L10n.App.hideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                item(L10n.App.showAll, #selector(NSApplication.unhideAllApplications(_:))), .separator(),
                item(L10n.App.quit, #selector(NSApplication.terminate(_:)), "q"),
            ])
        menu(
            L10n.Menu.file,
            [
                item(L10n.Menu.openMedia, #selector(EditorWindowController.importVideo(_:)), "o"),
                item(L10n.Menu.openProject, #selector(EditorWindowController.openProject(_:)), "o", [.command, .shift]),
                item(L10n.Menu.saveProject, #selector(EditorWindowController.saveProject(_:)), "s"),
                item(L10n.Menu.export, #selector(EditorWindowController.showExport(_:)), "e", [.command, .shift]),
                .separator(), item(L10n.Menu.close, #selector(NSWindow.performClose(_:)), "w"),
            ])
        // undo:/redo: reach the editor window's undo manager, or a text field's own in other windows.
        menu(
            L10n.Menu.edit,
            [
                item(L10n.Menu.undo, Selector(("undo:")), "z"), item(L10n.Menu.redo, Selector(("redo:")), "z", [.command, .shift]),
                .separator(), item(L10n.Menu.cut, #selector(NSText.cut(_:)), "x"),
                item(L10n.Menu.copy, #selector(NSText.copy(_:)), "c"), item(L10n.Menu.paste, #selector(NSText.paste(_:)), "v"),
                item(L10n.Menu.selectAll, #selector(NSText.selectAll(_:)), "a"),
            ])
        menu(L10n.Menu.view, [item(L10n.Menu.fullScreen, #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])])
        menu(
            L10n.Menu.playback,
            [
                item(L10n.Menu.play, #selector(EditorWindowController.togglePlayback(_:)), " ", []),
                item(
                    L10n.Menu.back5, #selector(EditorWindowController.skipBackward(_:)), arrow(NSLeftArrowFunctionKey),
                    []),
                item(
                    L10n.Menu.forward5, #selector(EditorWindowController.skipForward(_:)),
                    arrow(NSRightArrowFunctionKey), []),
            ])
        menu(
            L10n.Menu.clip,
            [
                item(L10n.Menu.splitAtPlayhead, #selector(EditorWindowController.splitAtPlayhead(_:)), "b"),
                item(L10n.Menu.removeSelectedClip, #selector(TimelineCanvas.deleteSelection(_:)), "\u{8}", []),
                item(L10n.Menu.deselect, #selector(TimelineCanvas.deselect(_:)), "\u{1b}", []), .separator(),
                item(L10n.Menu.previewCuts, #selector(EditorWindowController.togglePreview(_:)), "p", [.command, .shift]),
                item(L10n.Menu.snapTrim, #selector(EditorWindowController.toggleSnap(_:))), .separator(),
                item(L10n.Menu.transcribeAgain, #selector(EditorWindowController.transcribe(_:))),
                item(L10n.Menu.detectAgain, #selector(EditorWindowController.detect(_:)), "r", [.command, .shift]),
            ])
        NSApp.windowsMenu = menu(
            L10n.Menu.window,
            [
                item(L10n.Menu.minimize, #selector(NSWindow.performMiniaturize(_:)), "m"),
                item(L10n.Menu.zoom, #selector(NSWindow.performZoom(_:))), .separator(),
                item(L10n.Menu.bringAllFront, #selector(NSApplication.arrangeInFront(_:))),
            ])
        NSApp.helpMenu = menu(L10n.Menu.help, [])
        return main
    }
}
