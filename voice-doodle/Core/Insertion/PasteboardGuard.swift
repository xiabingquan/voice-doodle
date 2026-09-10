import AppKit
import Foundation

/// Backs up, writes, and restores the general pasteboard around a ⌘V insertion.
@MainActor
final class PasteboardGuard {
    struct Backup {
        let contents: [NSPasteboard.PasteboardType: Data]
    }

    private let pasteboard = NSPasteboard.general
    private let sizeLimit = 10_000_000

    func currentChangeCount() -> Int {
        pasteboard.changeCount
    }

    func backup() -> Backup {
        var contents: [NSPasteboard.PasteboardType: Data] = [:]
        for type in pasteboard.types ?? [] {
            guard let data = pasteboard.data(forType: type), data.count <= sizeLimit else { continue }
            contents[type] = data
        }
        return Backup(contents: contents)
    }

    /// Returns the pasteboard changeCount after writing.
    @discardableResult
    func writePlainText(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    func restore(_ backup: Backup) {
        guard !backup.contents.isEmpty else { return }
        pasteboard.clearContents()
        for (type, data) in backup.contents {
            pasteboard.setData(data, forType: type)
        }
    }
}
