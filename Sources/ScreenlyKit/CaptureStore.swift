import AppKit

/// A single screenshot Screenly has taken. The image lives on disk inside our
/// Application Support folder; `savedPath` is where the user's copy was written.
struct Shot: Identifiable, Codable, Equatable {
    var id = UUID()
    var imageFile: String          // filename inside our images dir
    var savedPath: String? = nil   // the user-facing copy (may be moved/deleted by the user)
    var date = Date()
    var pinned = false
    var mode: String = ""          // CaptureMode.rawValue

    var modeTitle: String { CaptureMode(rawValue: mode)?.shortTitle ?? "Captura" }
}

/// Owns the recent-capture history, persists it to Application Support and manages
/// the image files + a thumbnail cache. Adapted from Clippy's `HistoryStore`.
final class CaptureStore: ObservableObject {
    @Published private(set) var items: [Shot] = []
    private let maxItems = 100

    let imagesDir: URL
    private let fileURL: URL
    private let thumbCache = NSCache<NSString, NSImage>()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Screenly", isDirectory: true)
        imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        fileURL = dir.appendingPathComponent("shots.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    /// Pinned first, then newest to oldest.
    var orderedItems: [Shot] {
        items.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.date > b.date
        }
    }

    // MARK: - Adding

    /// Copy captured image bytes into our store as a new recent item.
    @discardableResult
    func add(data: Data, ext: String, mode: CaptureMode, savedPath: String?) -> URL? {
        let name = UUID().uuidString + "." + ext
        let url = imagesDir.appendingPathComponent(name)
        do {
            try data.write(to: url)
        } catch {
            NSLog("Screenly: could not save capture: \(error.localizedDescription)")
            return nil
        }
        items.insert(Shot(imageFile: name, savedPath: savedPath, mode: mode.rawValue), at: 0)
        trimAndSave()
        return url
    }

    // MARK: - Mutations

    func delete(_ item: Shot) {
        items.removeAll { $0.id == item.id }
        removeImageFile(item)
        save()
    }

    func togglePin(_ item: Shot) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].pinned.toggle()
        save()
    }

    func clearUnpinned() {
        for item in items where !item.pinned { removeImageFile(item) }
        items.removeAll { !$0.pinned }
        save()
    }

    // MARK: - Images

    func imageURL(for item: Shot) -> URL { imagesDir.appendingPathComponent(item.imageFile) }

    func thumbnail(for item: Shot) -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = thumbCache.object(forKey: key) { return cached }
        guard let img = NSImage(contentsOf: imageURL(for: item)) else { return nil }
        thumbCache.setObject(img, forKey: key)
        return img
    }

    private func removeImageFile(_ item: Shot) {
        try? FileManager.default.removeItem(at: imageURL(for: item))
        thumbCache.removeObject(forKey: item.id.uuidString as NSString)
    }

    // MARK: - Persistence

    private func trimAndSave() {
        let pinned = items.filter { $0.pinned }
        var unpinned = items.filter { !$0.pinned }.sorted { $0.date > $1.date }
        if unpinned.count > maxItems {
            for item in unpinned[maxItems...] { removeImageFile(item) }
            unpinned = Array(unpinned[..<maxItems])
        }
        items = pinned + unpinned
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Screenly: save error: \(error.localizedDescription)")
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Shot].self, from: data) else { return }
        // Drop records whose backing image file no longer exists.
        items = decoded.filter {
            FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent($0.imageFile).path)
        }
    }
}
