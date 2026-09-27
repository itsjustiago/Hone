import AppKit

/// A single entry in the clipboard history — either text or an image (stored on disk).
struct ClipItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: Kind
    var text: String = ""
    var imageFile: String? = nil
    var sourceApp: String? = nil
    var date = Date()
    var pinned = false

    enum Kind: String, Codable { case text, image }

    var searchText: String { kind == .text ? text : (sourceApp ?? "imagem") }

    var menuTitle: String {
        switch kind {
        case .text:
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return t.count > 50 ? String(t.prefix(50)) + "…" : t
        case .image:
            return "🖼 Imagem" + (sourceApp.map { " · \($0)" } ?? "")
        }
    }
}

/// Owns the history, persists it to Application Support, and manages image files.
final class HistoryStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    private let maxItems = 200

    private let imagesDir: URL
    private let fileURL: URL
    private let thumbCache = NSCache<NSString, NSImage>()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Clippy", isDirectory: true)
        imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        fileURL = dir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    /// `items` already is the display order, so this is just a pass-through.
    var orderedItems: [ClipItem] { items }

    /// Start of the unpinned block. The invariant is: pinned first, then the rest.
    private var pinnedCount: Int { items.firstIndex { !$0.pinned } ?? items.count }

    // MARK: - Adding

    func addText(_ text: String, source: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let idx = items.firstIndex(where: { $0.kind == .text && $0.text == text }) {
            items[idx].date = Date()
            if let source { items[idx].sourceApp = source }
            // A pinned item stays where the user put it; an unpinned one resurfaces.
            if !items[idx].pinned {
                let top = pinnedCount
                let item = items.remove(at: idx)
                items.insert(item, at: top)
            }
        } else {
            items.insert(ClipItem(kind: .text, text: text, sourceApp: source), at: pinnedCount)
        }
        trimAndSave()
    }

    func addImage(_ data: Data, source: String?) {
        let name = UUID().uuidString + ".png"
        do {
            try data.write(to: imagesDir.appendingPathComponent(name))
        } catch {
            NSLog("Clippy: could not save image: \(error.localizedDescription)")
            return
        }
        items.insert(ClipItem(kind: .image, imageFile: name, sourceApp: source), at: pinnedCount)
        trimAndSave()
    }

    // MARK: - Mutations

    func delete(_ item: ClipItem) {
        items.removeAll { $0.id == item.id }
        removeImageFile(item)
        save()
    }

    /// Pinning sends the item to the very top; unpinning drops it to the top of
    /// the unpinned block, so the two blocks never interleave.
    func togglePin(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        var moved = items.remove(at: idx)
        moved.pinned.toggle()
        items.insert(moved, at: moved.pinned ? 0 : pinnedCount)
        save()
    }

    /// Moves an item to `index`, clamped to its own block (pinned or unpinned).
    func move(_ item: ClipItem, to index: Int) {
        guard let from = items.firstIndex(where: { $0.id == item.id }) else { return }
        let pinned = items[from].pinned
        let lower = pinned ? 0 : pinnedCount
        let upper = pinned ? pinnedCount - 1 : items.count - 1
        guard lower <= upper else { return }
        let to = min(max(index, lower), upper)
        guard to != from else { return }
        let moved = items.remove(at: from)
        items.insert(moved, at: to)
        save()
    }

    func clearUnpinned() {
        for item in items where !item.pinned { removeImageFile(item) }
        items.removeAll { !$0.pinned }
        save()
    }

    // MARK: - Images

    func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { imagesDir.appendingPathComponent($0) }
    }

    func thumbnail(for item: ClipItem) -> NSImage? {
        guard let url = imageURL(for: item) else { return nil }
        let key = item.id.uuidString as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let img = NSImage(contentsOf: url) else { return nil }
        thumbCache.setObject(img, forKey: key)
        return img
    }

    private func removeImageFile(_ item: ClipItem) {
        guard let url = imageURL(for: item) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Persistence

    /// Trims from the end of the unpinned block, so the manual order survives.
    private func trimAndSave() {
        let limit = pinnedCount + maxItems
        if items.count > limit {
            for item in items[limit...] { removeImageFile(item) }
            items.removeSubrange(limit...)
        }
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Clippy: save error: \(error.localizedDescription)")
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        let valid = decoded.filter { item in
            guard item.kind == .image else { return true }
            guard let file = item.imageFile else { return false }
            return FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent(file).path)
        }
        // Stable partition only — sorting here would wipe the user's manual order.
        items = valid.filter { $0.pinned } + valid.filter { !$0.pinned }
    }
}
