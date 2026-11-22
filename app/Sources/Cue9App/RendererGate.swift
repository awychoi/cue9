import Foundation

/// The C renderer keeps a few global working buffers. The live preview and the
/// small face stills share them, so every renderer call goes through one gate.
/// Frames are cheap; correctness is worth the tiny wait.
enum RendererGate {
    private static let lock = NSLock()

    static func run<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
