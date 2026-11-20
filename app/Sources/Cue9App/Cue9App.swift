import AppKit
import SwiftUI

@MainActor
final class Cue9AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var model = AppModel()
    private var snapshotPath: String?
    private var snapshotSection: AppSection = .mote
    private var snapshotAppearance: AppearanceMode = .dark
    private var appearanceObserver: NSObjectProtocol?

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Cue9Font.register()
        parseSnapshotArguments()
        installMainMenu()
        installAppearanceObserver()
        if let snapshotPath {
            let model = self.model
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                Snapshot.write(
                    model: model,
                    section: self.snapshotSection,
                    appearance: self.snapshotAppearance,
                    to: snapshotPath
                )
                NSApp.terminate(nil)
            }
            return
        }
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.activate(ignoringOtherApps: true)
        showWindow()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        model.pauseBackgroundWork()
    }

    private func showWindow() {
        if let window {
            model.resumeBackgroundWork()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingView(rootView: RootView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "cue9"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let savedAppearance = UserDefaults.standard.string(forKey: "appearance")
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system
        window.appearance = savedAppearance.nsAppearance
        window.delegate = self
        window.contentView = hosting
        hosting.appearance = savedAppearance.nsAppearance
        window.center()
        self.window = window
        model.resumeBackgroundWork()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installAppearanceObserver() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let saved = UserDefaults.standard.string(forKey: "appearance")
                    .flatMap(AppearanceMode.init(rawValue:)) ?? .system
                guard let window = self?.window else { return }
                window.appearance = saved.nsAppearance
                window.contentView?.appearance = saved.nsAppearance
            }
        }
    }

    private func parseSnapshotArguments() {
        guard let idx = CommandLine.arguments.firstIndex(of: "--snapshot"),
              CommandLine.arguments.count > idx + 1 else { return }
        snapshotPath = CommandLine.arguments[idx + 1]
        if let sectionIndex = CommandLine.arguments.firstIndex(of: "--snapshot-section"),
           CommandLine.arguments.count > sectionIndex + 1,
           let parsed = AppSection.allCases.first(where: {
               $0.rawValue.lowercased() == CommandLine.arguments[sectionIndex + 1].lowercased()
           }) {
            snapshotSection = parsed
        }
        if let appearanceIndex = CommandLine.arguments.firstIndex(of: "--snapshot-appearance"),
           CommandLine.arguments.count > appearanceIndex + 1,
           let parsed = AppearanceMode(rawValue: CommandLine.arguments[appearanceIndex + 1].lowercased()) {
            snapshotAppearance = parsed
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: "cue9", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About cue9",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())

        let servicesMenu = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)

        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide cue9",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit cue9",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu
        NSApp.servicesMenu = servicesMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        let pluginItem = NSMenuItem(
            title: "Copy cue9 plugin URL",
            action: #selector(copyPluginURL),
            keyEquivalent: ""
        )
        pluginItem.target = self
        helpMenu.addItem(pluginItem)
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func copyPluginURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("https://github.com/awychoi/dsh-cue9-mote", forType: .string)
    }
}
