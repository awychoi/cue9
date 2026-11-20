import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = Cue9AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
