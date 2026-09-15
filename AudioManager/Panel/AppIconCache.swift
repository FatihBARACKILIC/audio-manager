import AppKit

/// Small, bounded cache of app icons rendered at the size the panel draws them.
///
/// Asking the workspace for an icon is not free and the panel asks for every row on
/// every appearance. Icons are rasterised once at display size and the cache is capped,
/// so a machine with fifty running apps cannot quietly grow our memory footprint.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    private let limit = 40
    private let size = NSSize(width: 22, height: 22)
    private var storage: [String: NSImage] = [:]
    private var order: [String] = []

    func icon(forBundlePath path: String?) -> NSImage? {
        guard let path else { return nil }

        if let cached = storage[path] {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: path)
        let resized = NSImage(size: size, flipped: false) { rect in
            icon.draw(in: rect)
            return true
        }

        storage[path] = resized
        order.append(path)
        if order.count > limit, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
        return resized
    }

    /// Dropped when the panel closes: nothing on screen needs these until it opens again.
    func clear() {
        storage.removeAll()
        order.removeAll()
    }
}
