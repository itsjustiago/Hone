import AppKit

/// Which visible list a clip belongs to: the history, or one of the tables.
enum ClipOrigin: Hashable {
    case history
    case table(UUID)
}

/// Where a dragged row can land: a visible list, or the "+" (a brand-new table).
enum DropZone: Hashable {
    case list(ClipOrigin)
    case newTable
}

/// A user-made table of clips. Unlike the history it is never trimmed and
/// "Limpar" doesn't touch it — the point is that these stay forever.
struct ClipTable: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var items: [ClipItem] = []
}

/// Owns the secondary tables, persists them next to the history, and keeps
/// their images in a directory of their own so the history trim can never
/// delete a file a table still points at.
final class CollectionStore: ObservableObject {
    @Published private(set) var tables: [ClipTable] = []

    private let imagesDir: URL
    private let historyImagesDir: URL
    private let fileURL: URL
    private let thumbCache = NSCache<NSString, NSImage>()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Clippy", isDirectory: true)
        imagesDir = dir.appendingPathComponent("tables-images", isDirectory: true)
        historyImagesDir = dir.appendingPathComponent("images", isDirectory: true)
        fileURL = dir.appendingPathComponent("tables.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    // MARK: - Tables

    func table(_ id: UUID) -> ClipTable? { tables.first { $0.id == id } }

    /// Next "Tabela N" that isn't taken yet.
    func defaultName() -> String {
        var n = tables.count + 1
        while tables.contains(where: { $0.name == "Tabela \(n)" }) { n += 1 }
        return "Tabela \(n)"
    }

    /// How many cards fit next to the history before the strip has to scroll.
    static let maxTables = 3

    /// True while there's room for another table. Tables saved before the limit
    /// existed are kept — only creating more is blocked.
    var canAddTable: Bool { tables.count < CollectionStore.maxTables }

    @discardableResult
    func addTable(name: String) -> ClipTable? {
        guard canAddTable else { return nil }
        let table = ClipTable(name: name)
        tables.append(table)
        save()
        return table
    }

    func rename(_ table: ClipTable, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = index(of: table) else { return }
        tables[i].name = clean
        save()
    }

    /// Drops the table and the image files only it owned.
    func deleteTable(_ table: ClipTable) {
        guard let i = index(of: table) else { return }
        for item in tables[i].items { removeImageFile(item) }
        tables.remove(at: i)
        save()
    }

    // MARK: - Items

    /// Copies an item (from the history or another table) into `table`.
    /// Images get a fresh file under `tables-images/`, never a shared one.
    @discardableResult
    func add(_ item: ClipItem, to table: ClipTable) -> Bool {
        guard let i = index(of: table), let payload = payload(of: item) else { return false }
        return insert(payload, source: item.sourceApp, date: item.date, into: i)
    }

    @discardableResult
    func addText(_ text: String, source: String?, to table: ClipTable) -> Bool {
        guard let i = index(of: table) else { return false }
        return insert(.text(text), source: source, date: Date(), into: i)
    }

    @discardableResult
    func addImage(_ data: Data, source: String?, to table: ClipTable) -> Bool {
        guard let i = index(of: table) else { return false }
        return insert(.image(data), source: source, date: Date(), into: i)
    }

    func remove(_ item: ClipItem, from table: ClipTable) {
        guard let i = index(of: table) else { return }
        tables[i].items.removeAll { $0.id == item.id }
        removeImageFile(item)
        save()
    }

    /// Free reordering — tables have no pinned block to stay inside.
    func move(_ item: ClipItem, in table: ClipTable, to index: Int) {
        guard let i = self.index(of: table),
              let from = tables[i].items.firstIndex(where: { $0.id == item.id }) else { return }
        let to = min(max(index, 0), tables[i].items.count - 1)
        guard to != from else { return }
        let moved = tables[i].items.remove(at: from)
        tables[i].items.insert(moved, at: to)
        save()
    }

    /// Table → table is a move: copy first, then drop the original (and its file).
    func move(_ item: ClipItem, from source: ClipTable, to destination: ClipTable) {
        guard source.id != destination.id, add(item, to: destination) else { return }
        remove(item, from: source)
    }

    // MARK: - Images

    /// Table items live in `tables-images/`; an item still owned by the history
    /// resolves to the history directory, which is what copying reads from.
    func imageURL(for item: ClipItem) -> URL? {
        guard let file = item.imageFile else { return nil }
        let local = imagesDir.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let history = historyImagesDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: history.path) ? history : nil
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
        guard let file = item.imageFile else { return }
        // Only ever delete our own copy — never the history's file.
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(file))
    }

    // MARK: - Insertion

    /// The content of an entry, independent of where its bytes currently live.
    private enum Payload {
        case text(String)
        case image(Data)
    }

    private func payload(of item: ClipItem) -> Payload? {
        switch item.kind {
        case .text:
            return .text(item.text)
        case .image:
            guard let url = imageURL(for: item), let data = try? Data(contentsOf: url) else { return nil }
            return .image(data)
        }
    }

    /// Adds at the top, or lifts the existing twin to the top instead of duplicating.
    private func insert(_ payload: Payload, source: String?, date: Date, into i: Int) -> Bool {
        if let existing = tables[i].items.firstIndex(where: { matches($0, payload) }) {
            let moved = tables[i].items.remove(at: existing)
            tables[i].items.insert(moved, at: 0)
            save()
            return true
        }
        let item: ClipItem
        switch payload {
        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            item = ClipItem(kind: .text, text: text, sourceApp: source, date: date)
        case .image(let data):
            let name = UUID().uuidString + ".png"
            do {
                try data.write(to: imagesDir.appendingPathComponent(name), options: .atomic)
            } catch {
                NSLog("Clippy: could not save table image: \(error.localizedDescription)")
                return false
            }
            item = ClipItem(kind: .image, imageFile: name, sourceApp: source, date: date)
        }
        tables[i].items.insert(item, at: 0)
        save()
        return true
    }

    private func matches(_ item: ClipItem, _ payload: Payload) -> Bool {
        switch payload {
        case .text(let text):
            return item.kind == .text && item.text == text
        case .image(let data):
            guard item.kind == .image, let url = imageURL(for: item) else { return false }
            return (try? Data(contentsOf: url)) == data
        }
    }

    private func index(of table: ClipTable) -> Int? {
        tables.firstIndex { $0.id == table.id }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(tables)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Clippy: tables save error: \(error.localizedDescription)")
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ClipTable].self, from: data) else { return }
        tables = decoded.map { table in
            var table = table
            table.items = table.items.filter { item in
                guard item.kind == .image else { return true }
                guard let file = item.imageFile else { return false }
                return FileManager.default.fileExists(atPath: imagesDir.appendingPathComponent(file).path)
            }
            return table
        }
    }
}
