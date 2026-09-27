import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var collections: CollectionStore
    @ObservedObject var vm: PanelViewModel
    let onChoose: (ClipItem, ClipOrigin) -> Void
    let onDelete: (ClipItem) -> Void
    let onTogglePin: (ClipItem) -> Void
    let onClearAll: () -> Void
    /// Renaming needs real keyboard focus — the panel usually runs without it.
    let onBeginEditing: () -> Void

    @FocusState private var searchFocused: Bool
    @FocusState private var nameFocused: Bool
    @FocusState private var composerFocused: Bool
    @State private var clearHovering = false
    @State private var plusHovering = false
    @State private var closeHovering: UUID?
    @State private var addHovering: UUID?
    @State private var writeHovering: UUID?
    /// Entry being typed in a card's composer, kept out of the store until submit.
    /// Name being typed in a card header — only written back to the store on
    /// submit, so Escape can walk away without touching anything.
    @State private var draftName = ""

    // Drag state. `rowFrames` is filled by the rows themselves, so the drop
    // target is computed from real geometry (rows have variable heights), and
    // `zoneFrames` holds the cards, so a drag can cross from one card to another.
    @State private var draggingID: ClipItem.ID?
    @State private var draggingItem: ClipItem?
    @State private var draggingOrigin: ClipOrigin = .history
    /// Cursor position and where inside the row it grabbed, so the floating
    /// copy stays under the pointer instead of snapping its centre to it.
    @State private var dragLocation: CGPoint = .zero
    @State private var grabOffset: CGSize = .zero
    @State private var dropIndex: Int?
    @State private var rowFrames: [ClipItem.ID: CGRect] = [:]
    @State private var zoneFrames: [DropZone: CGRect] = [:]
    @State private var dropZone: DropZone?
    /// Natural height of each table's list, so a card is only as tall as its content.
    @State private var listHeights: [UUID: CGFloat] = [:]

    /// One space for the whole window: every card is measured in it and the row
    /// gesture reports into it, so a drag can cross from a card to another.
    static let panelSpace = "panel"

    // MARK: - Metrics

    static let mainWidth: CGFloat = 440
    static let cardHeight: CGFloat = 540
    static let tableWidth: CGFloat = 300
    static let cardGap: CGFloat = 12
    static let addSize: CGFloat = 36
    private static let maxListHeight: CGFloat = 430
    private static let minCardHeight: CGFloat = 140

    /// Width the window needs for `count` tables, "+" included.
    static func panelWidth(tableCount: Int) -> CGFloat {
        mainWidth + CGFloat(tableCount) * (tableWidth + cardGap) + cardGap + addSize
    }

    /// Width the strip of tables + "+" needs on its own.
    private var stripWidth: CGFloat {
        CGFloat(collections.tables.count) * (Self.tableWidth + Self.cardGap) + Self.addSize
    }

    /// A filtered list doesn't map onto the stored order, so reordering is off then.
    private var canReorderHistory: Bool { vm.query.isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: Self.cardGap) {
            mainCard
            tablesStrip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Above every card and outside their clip shapes, so the dragged row
        // stays visible all the way from one card to the next.
        .overlay(alignment: .topLeading) { dragPreview.zIndex(10) }
        .coordinateSpace(name: Self.panelSpace)
        .onPreferenceChange(ZoneFramesKey.self) {
            zoneFrames = $0
            vm.cardRects = Array($0.values)
        }
        .onPreferenceChange(ListHeightKey.self) { listHeights = $0 }
        // Search is NOT focused by default — the user must click it to type/search.
        .onAppear { searchFocused = false }
        .onChange(of: vm.focusPulse) { searchFocused = false }
        .onChange(of: searchFocused) { vm.searchActive = searchFocused }
        .onChange(of: vm.query) { vm.selectedIndex = 0 }
        // Escape cancels a rename from the key handler, so the focus follows it.
        .onChange(of: vm.editingTable) { nameFocused = vm.editingTable != nil }
        // Same for the composer: Escape closes it from the key handler.
        .onChange(of: vm.composingTable) { composerFocused = vm.composingTable != nil }
    }

    // MARK: - Main card

    private var mainCard: some View {
        let items = vm.filtered()
        return VStack(spacing: 0) {
            windowGrabber
            searchBar
            Divider().opacity(0.4)
            if items.isEmpty {
                historyEmptyState
            } else {
                historyList(items)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: Self.mainWidth, height: Self.cardHeight)
        .modifier(CardSurface(highlighted: isDropTarget(.history),
                              focused: isKeyboardCard(.history)))
        .background(zoneReader(.list(.history)))
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Pesquisar no histórico…", text: $vm.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func historyList(_ items: [ClipItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index, origin: .history, in: items,
                            selected: vm.keyboardOrigin == .history
                                && index == clampedSelection(items.count),
                            showPin: true,
                            onDelete: { onDelete(item) },
                            onTogglePin: { onTogglePin(item) })
                            .id(item.id)
                    }
                }
                .padding(8)
                .onPreferenceChange(RowFramesKey.self) { rowFrames.merge($0) { _, new in new } }
            }
            .onChange(of: vm.selectedIndex) {
                let idx = clampedSelection(items.count)
                if items.indices.contains(idx) {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(items[idx].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func clampedSelection(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(vm.selectedIndex, 0), count - 1)
    }

    /// The one place the panel itself can be dragged from. The window used to be
    /// movable by any empty area, but that made AppKit swallow the rows' own
    /// drags before SwiftUI ever saw them.
    private var windowGrabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.top, 7)
            .padding(.bottom, 5)
            .background(WindowDragArea())
    }

    // MARK: - Tables strip

    /// The cards live in the same window as the history, side by side. Once they
    /// no longer fit the screen the strip scrolls instead of growing further.
    @ViewBuilder private var tablesStrip: some View {
        let cards = HStack(alignment: .top, spacing: Self.cardGap) {
            ForEach(collections.tables) { tableCard($0) }
            addButton
        }
        if vm.tablesWidth > 0, stripWidth > vm.tablesWidth + 1 {
            // Snaps to whole cards, so scrolling never leaves one cut in half.
            ScrollView(.horizontal, showsIndicators: false) {
                cards
                    .padding(.trailing, 2)
                    .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .frame(width: vm.tablesWidth, height: Self.cardHeight, alignment: .topLeading)
        } else {
            cards
        }
    }

    private func tableCard(_ table: ClipTable) -> some View {
        VStack(spacing: 0) {
            tableHeader(table)
            Divider().opacity(0.4)
            // An open composer needs the list even when the table is still empty.
            if table.items.isEmpty, vm.composingTable != table.id {
                tableEmptyState(table)
            } else {
                tableList(table)
                Divider().opacity(0.4)
                tableFooter(table)
            }
        }
        .frame(width: Self.tableWidth)
        .frame(minHeight: Self.minCardHeight, alignment: .top)
        .modifier(CardSurface(highlighted: isDropTarget(.table(table.id)),
                              focused: isKeyboardCard(.table(table.id))))
        .background(zoneReader(.list(.table(table.id))))
    }

    /// Name is edited in place; the menu covers the rest.
    private func tableHeader(_ table: ClipTable) -> some View {
        HStack(spacing: 6) {
            if vm.editingTable == table.id {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($nameFocused)
                    .onAppear { nameFocused = true }
                    .onSubmit { commitRename(table) }
            } else {
                Text(table.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !table.items.isEmpty {
                    Text("\(table.items.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                closeButton(table)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Mudar o nome") { beginRename(table) }
            Button("Apagar tabela", role: .destructive) { deleteTable(table) }
        }
    }

    /// Deletes the table. Sits in the header so a card can go away without
    /// hunting through the context menu.
    private func closeButton(_ table: ClipTable) -> some View {
        Button { deleteTable(table) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(closeHovering == table.id ? Color.red : Color.secondary.opacity(0.65))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { closeHovering = $0 ? table.id : nil }
        .help("Apagar tabela")
        .animation(.easeInOut(duration: 0.12), value: closeHovering)
    }

    /// The list is as tall as its rows, capped — that's what makes a card with
    /// two items short and one with twenty full height.
    private func tableList(_ table: ClipTable) -> some View {
        let natural = listHeights[table.id] ?? 0
        return ScrollViewReader { proxy in
            tableScroll(table)
                // Arrow keys can walk a table taller than its card.
                .onChange(of: vm.selectedIndex) {
                    guard vm.keyboardOrigin == .table(table.id) else { return }
                    let idx = clampedSelection(table.items.count)
                    guard table.items.indices.contains(idx) else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(table.items[idx].id, anchor: .center)
                    }
                }
        }
        .frame(height: min(max(natural, 44), Self.maxListHeight))
    }

    private func tableScroll(_ table: ClipTable) -> some View {
        ScrollView {
            LazyVStack(spacing: Self.rowSpacing) {
                if vm.composingTable == table.id { composer(table) }
                ForEach(Array(table.items.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index, origin: .table(table.id), in: table.items,
                        selected: vm.keyboardOrigin == .table(table.id)
                            && index == clampedSelection(table.items.count),
                        showPin: false,
                        onDelete: { collections.remove(item, from: table) },
                        onTogglePin: {})
                }
            }
            .padding(8)
            .background(listHeightReader(table))
            .onPreferenceChange(RowFramesKey.self) { rowFrames.merge($0) { _, new in new } }
        }
    }

    /// Typed straight into the table: lands at the top, where the entry goes.
    private func composer(_ table: ClipTable) -> some View {
        TextField("Escreve e Enter", text: $vm.draftEntry, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(1...4)
            .focused($composerFocused)
            .onSubmit { commitEntry(to: table) }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { composerFocused = true }
            // Clicking away closes it, unless something is already typed.
            .onChange(of: composerFocused) {
                if !composerFocused, trimmedDraft.isEmpty { vm.composingTable = nil }
            }
    }

    private func tableFooter(_ table: ClipTable) -> some View {
        HStack(spacing: 6) {
            writeButton(table)
            addFromClipboardButton(table)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func tableEmptyState(_ table: ClipTable) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("Arrasta cópias para aqui, ou escreve uma")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                writeButton(table)
                addFromClipboardButton(table)
            }
            .padding(.top, 2)
        }
        // Fixed, not flexible: an empty card must stay short, not fill the window.
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    /// Floats outside the main card, after the last table — a drop here makes a
    /// new table with the dragged item already inside.
    private var addButton: some View {
        let room = collections.canAddTable
        let hot = room && (plusHovering || dropZone == .newTable)
        return Button { createTable() } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hot ? Brand.tint : .secondary)
                .frame(width: Self.addSize, height: Self.addSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardSurface(cornerRadius: 11, highlighted: hot && dropZone == .newTable))
        .background(zoneReader(.newTable))
        .disabled(!room)
        .opacity(room ? 1 : 0.4)
        .onHover { plusHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hot)
        .help(room ? "Nova tabela" : "Máximo de \(CollectionStore.maxTables) tabelas")
    }

    // MARK: - Table actions

    private func createTable() {
        guard let new = collections.addTable(name: collections.defaultName()) else { return }
        beginRename(new)
    }

    private func beginRename(_ table: ClipTable) {
        onBeginEditing()
        draftName = table.name
        vm.editingTable = table.id
    }

    /// Empty name keeps the one it already had — a fresh table never loses its default.
    private func commitRename(_ table: ClipTable) {
        collections.rename(table, to: draftName)
        vm.editingTable = nil
    }

    private func deleteTable(_ table: ClipTable) {
        if vm.editingTable == table.id { vm.editingTable = nil }
        if vm.composingTable == table.id { vm.composingTable = nil }
        collections.deleteTable(table)
    }

    // MARK: - Writing an entry

    private var trimmedDraft: String {
        vm.draftEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The panel has no focus of its own, so the composer has to ask for it —
    /// otherwise what's typed lands in the app underneath.
    private func beginCompose(_ table: ClipTable) {
        onBeginEditing()
        vm.draftEntry = ""
        vm.editingTable = nil
        vm.composingTable = table.id
        composerFocused = true
    }

    /// Enter stores the entry and leaves the field open for the next one.
    private func commitEntry(to table: ClipTable) {
        let text = trimmedDraft
        vm.draftEntry = ""
        composerFocused = true
        guard !text.isEmpty else { return }
        collections.addText(text, source: nil, to: table)
    }

    /// New table holding `item`: a copy from the history, a move from a table.
    /// Does nothing once the table limit is reached.
    private func addToNewTable(_ item: ClipItem, from origin: ClipOrigin) {
        guard let new = collections.addTable(name: collections.defaultName()) else { return }
        collections.add(item, to: new)
        if case .table(let id) = origin, let source = collections.table(id) {
            collections.remove(item, from: source)
        }
        beginRename(new)
    }

    private func addFromClipboard(to table: ClipTable) {
        let source = NSWorkspace.shared.frontmostApplication?.localizedName
        switch ClipboardManager.current() {
        case .text(let text):
            collections.addText(text, source: source, to: table)
        case .image(let data):
            collections.addImage(data, source: source, to: table)
        case nil:
            break
        }
    }

    // MARK: - Rows

    private static let rowSpacing: CGFloat = 4
    /// A nudge on the grip is enough — there is no click to tell it apart from.
    static let dragStart: CGFloat = 3

    private func row(_ item: ClipItem, index: Int, origin: ClipOrigin,
                     in items: [ClipItem], selected: Bool, showPin: Bool,
                     onDelete: @escaping () -> Void,
                     onTogglePin: @escaping () -> Void) -> some View {
        let dragged = draggingID == item.id
        return ClipRow(item: item,
                       index: index,
                       selected: selected,
                       thumbnail: thumbnail(for: item, origin: origin),
                       showPin: showPin,
                       showShortcut: showPin,
                       tables: otherTables(than: origin),
                       onChoose: { onChoose(item, origin) },
                       onDelete: onDelete,
                       onTogglePin: onTogglePin,
                       onAddTo: { transfer(item, from: origin, to: .table($0.id)) },
                       onAddToNew: { addToNewTable(item, from: origin) },
                       canAddTable: collections.canAddTable,
                       onDragChanged: { dragChanged($0, item: item, index: index, origin: origin, in: items) },
                       onDragEnded: { dragEnded($0, item: item, index: index, origin: origin) })
            .background(frameReader(item))
            .offset(y: shift(for: index, origin: origin, in: items))
            .animation(.easeInOut(duration: 0.15), value: dropIndex)
            // The lifted copy is the root overlay; what stays here is a ghost.
            .opacity(dragged ? 0.35 : 1)
    }

    /// The row the cursor is carrying, drawn once at the root — inert, so it
    /// never steals a click from the card underneath.
    @ViewBuilder private var dragPreview: some View {
        if let item = draggingItem, let id = draggingID {
            ClipRow(item: item,
                    index: 0,
                    selected: false,
                    thumbnail: thumbnail(for: item, origin: draggingOrigin),
                    showPin: false,
                    showShortcut: false,
                    tables: [],
                    onChoose: {}, onDelete: {}, onTogglePin: {},
                    onAddTo: { _ in }, onAddToNew: {},
                    onDragChanged: { _ in }, onDragEnded: { _ in })
                .frame(width: rowFrames[id]?.width ?? Self.tableWidth - 16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .scaleEffect(1.02)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                .position(x: dragLocation.x - grabOffset.width,
                          y: dragLocation.y - grabOffset.height)
                .allowsHitTesting(false)
        }
    }

    private func otherTables(than origin: ClipOrigin) -> [ClipTable] {
        collections.tables.filter { .table($0.id) != origin }
    }

    private func thumbnail(for item: ClipItem, origin: ClipOrigin) -> NSImage? {
        guard item.kind == .image else { return nil }
        return origin == .history ? store.thumbnail(for: item) : collections.thumbnail(for: item)
    }

    // MARK: - Drag between cards

    private func frameReader(_ item: ClipItem) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: RowFramesKey.self,
                                   value: [item.id: geo.frame(in: .named(Self.panelSpace))])
        }
    }

    private func zoneReader(_ zone: DropZone) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: ZoneFramesKey.self,
                                   value: [zone: geo.frame(in: .named(Self.panelSpace))])
        }
    }

    private func listHeightReader(_ table: ClipTable) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: ListHeightKey.self, value: [table.id: geo.size.height])
        }
    }

    private func canReorder(_ origin: ClipOrigin) -> Bool {
        origin == .history ? canReorderHistory : true
    }

    /// True while a dragged row hovers a card that isn't the one it came from.
    /// Only worth showing once ← and → have somewhere to go.
    private func isKeyboardCard(_ origin: ClipOrigin) -> Bool {
        !collections.tables.isEmpty && vm.keyboardOrigin == origin
    }

    private func isDropTarget(_ origin: ClipOrigin) -> Bool {
        dropZone == .list(origin) && draggingOrigin != origin && draggingID != nil
    }

    /// One gesture for three jobs: a short press pastes, a longer one reorders,
    /// and crossing into another card drops the item there.
    private func dragChanged(_ value: DragGesture.Value, item: ClipItem,
                             index: Int, origin: ClipOrigin, in items: [ClipItem]) {
        if draggingID == nil {
            guard hypot(value.translation.width, value.translation.height) > Self.dragStart else { return }
            // Grab point inside the row, measured once, so the copy doesn't jump.
            if let frame = rowFrames[item.id] {
                grabOffset = CGSize(width: value.startLocation.x - frame.midX,
                                    height: value.startLocation.y - frame.midY)
            } else {
                grabOffset = .zero
            }
            withAnimation(.easeOut(duration: 0.12)) {
                draggingID = item.id
                draggingItem = item
                draggingOrigin = origin
            }
        }
        guard draggingID == item.id else { return }
        dragLocation = value.location
        let zone = zoneFrames.first { $0.value.contains(value.location) }?.key
        dropZone = zone
        // The gap only opens in the list the row came from.
        if zone == .list(origin), canReorder(origin) {
            dropIndex = dropTarget(from: index, offset: value.translation.height, in: items)
        } else {
            dropIndex = nil
        }
    }

    private func dragEnded(_ value: DragGesture.Value, item: ClipItem,
                           index: Int, origin: ClipOrigin) {
        if draggingID == item.id {
            switch dropZone {
            case .newTable:
                addToNewTable(item, from: origin)
            case .list(let target) where target == origin:
                if let dropIndex, dropIndex != index { reorder(item, to: dropIndex, in: origin) }
            case .list(let target):
                transfer(item, from: origin, to: target)
            case nil:
                break
            }
        }
        draggingID = nil
        draggingItem = nil
        dropIndex = nil
        dropZone = nil
        grabOffset = .zero
    }

    private func reorder(_ item: ClipItem, to index: Int, in origin: ClipOrigin) {
        switch origin {
        case .history:
            store.move(item, to: index)
        case .table(let id):
            guard let table = collections.table(id) else { return }
            collections.move(item, in: table, to: index)
        }
    }

    /// History → table copies, table → table moves, table → history copies back.
    private func transfer(_ item: ClipItem, from origin: ClipOrigin, to target: ClipOrigin) {
        switch (origin, target) {
        case (.history, .table(let id)):
            guard let destination = collections.table(id) else { return }
            collections.add(item, to: destination)
        case (.table(let from), .table(let to)):
            guard from != to,
                  let source = collections.table(from),
                  let destination = collections.table(to) else { return }
            collections.move(item, from: source, to: destination)
        case (.table, .history):
            copyToHistory(item)
        case (.history, .history):
            break
        }
    }

    private func copyToHistory(_ item: ClipItem) {
        switch item.kind {
        case .text:
            store.addText(item.text, source: item.sourceApp)
        case .image:
            guard let url = collections.imageURL(for: item),
                  let data = try? Data(contentsOf: url) else { return }
            store.addImage(data, source: item.sourceApp)
        }
    }

    /// Index whose measured frame contains the dragged row's centre, clamped to
    /// the item's own block so pinned and unpinned never mix.
    private func dropTarget(from index: Int, offset: CGFloat, in items: [ClipItem]) -> Int {
        guard let start = rowFrames[items[index].id] else { return index }
        let y = start.midY + offset
        var target = index
        for (i, other) in items.enumerated() {
            guard let frame = rowFrames[other.id] else { continue }
            target = i
            if y <= frame.maxY { break }   // first row the centre reaches
        }
        // In a table nothing is pinned, so this collapses to the whole list.
        let pinnedCount = items.prefix { $0.pinned }.count
        let lower = items[index].pinned ? 0 : pinnedCount
        let upper = items[index].pinned ? pinnedCount - 1 : items.count - 1
        return min(max(target, lower), max(lower, upper))
    }

    /// How far a row steps aside to open the gap for the dragged one.
    private func shift(for index: Int, origin: ClipOrigin, in items: [ClipItem]) -> CGFloat {
        guard let draggingID,
              draggingOrigin == origin,
              items[index].id != draggingID,
              let from = items.firstIndex(where: { $0.id == draggingID }),
              let to = dropIndex else { return 0 }
        let step = (rowFrames[draggingID]?.height ?? 0) + Self.rowSpacing
        if from < to, index > from, index <= to { return -step }
        if from > to, index >= to, index < from { return step }
        return 0
    }

    // MARK: - States

    @ViewBuilder private var historyEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: vm.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(vm.query.isEmpty ? "Sem histórico ainda" : "Sem resultados")
                .foregroundStyle(.secondary)
            if vm.query.isEmpty {
                Text("Copia algo (⌘C) e aparece aqui.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↵", "colar")
            hint("⌘⌫", "apagar")
            hint("esc", "fechar")
            Spacer()
            if !store.items.isEmpty { clearButton }
            Text("\(store.items.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(minWidth: 18, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var clearButton: some View {
        Button { onClearAll() } label: {
            Label("Limpar", systemImage: "trash")
                .font(.system(size: 11))
                .foregroundStyle(clearHovering ? .red : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    clearHovering ? Color.red.opacity(0.14) : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .onHover { clearHovering = $0 }
        .help("Limpar o histórico (mantém os fixados)")
        .animation(.easeInOut(duration: 0.12), value: clearHovering)
    }

    /// Opens the inline composer at the top of the card's list.
    private func writeButton(_ table: ClipTable) -> some View {
        let hot = writeHovering == table.id || vm.composingTable == table.id
        return Button { beginCompose(table) } label: {
            Label("Escrever", systemImage: "square.and.pencil")
                .font(.system(size: 11))
                .foregroundStyle(hot ? Brand.tint : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    hot ? Brand.tint.opacity(0.14) : Color.primary.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .onHover { writeHovering = $0 ? table.id : nil }
        .animation(.easeInOut(duration: 0.12), value: hot)
        .help("Escrever uma entrada nesta tabela")
    }

    /// Disabled when the pasteboard holds nothing we can store.
    private func addFromClipboardButton(_ table: ClipTable) -> some View {
        let available = ClipboardManager.hasContent()
        let hot = addHovering == table.id && available
        return Button { addFromClipboard(to: table) } label: {
            Label("Do clipboard", systemImage: "plus")
                .font(.system(size: 11))
                .foregroundStyle(hot ? Brand.tint : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    hot ? Brand.tint.opacity(0.14) : Color.primary.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.45)
        .onHover { addHovering = $0 ? table.id : nil }
        .animation(.easeInOut(duration: 0.12), value: hot)
        .help("Guardar o conteúdo atual do clipboard nesta tabela")
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Window dragging

/// An AppKit view whose only job is to move the window when pressed. SwiftUI
/// gestures can't do this without `isMovableByWindowBackground`, which steals
/// every other drag in the panel.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Card surface

/// The floating look every card shares. The window itself is transparent and
/// shadowless, so the shadow has to be drawn here — one per card, never around
/// the empty gaps between them.
private struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    var highlighted = false
    /// The card the arrow keys are driving — a quieter ring than a drop target.
    var focused = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(.ultraThinMaterial, in: shape)
            .background(highlighted ? Brand.tint.opacity(0.12) : .clear, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(border, lineWidth: highlighted ? 1.5 : 1))
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
            .animation(.easeInOut(duration: 0.12), value: highlighted)
            .animation(.easeInOut(duration: 0.12), value: focused)
    }

    private var border: Color {
        if highlighted { return Brand.tint.opacity(0.8) }
        if focused { return Brand.tint.opacity(0.35) }
        return Color.primary.opacity(0.10)
    }
}

// MARK: - Geometry

/// Measured row frames in the window's coordinate space — rows have variable
/// heights, so the drop target can't be derived from a fixed row height.
private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [ClipItem.ID: CGRect] = [:]

    static func reduce(value: inout [ClipItem.ID: CGRect],
                       nextValue: () -> [ClipItem.ID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Card frames, in the same space as the rows, so a drag can target them.
private struct ZoneFramesKey: PreferenceKey {
    static let defaultValue: [DropZone: CGRect] = [:]

    static func reduce(value: inout [DropZone: CGRect],
                       nextValue: () -> [DropZone: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Natural height of each table's rows, used to size its card.
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Row

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let thumbnail: NSImage?
    /// Pinning only exists in the history.
    let showPin: Bool
    /// ⌘1…⌘9 only drives the history, so table rows don't advertise it.
    let showShortcut: Bool
    let tables: [ClipTable]
    let onChoose: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    let onAddTo: (ClipTable) -> Void
    let onAddToNew: () -> Void
    /// False once the table limit is reached — "Nova tabela…" greys out.
    var canAddTable = true
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    @State private var hovering = false
    @State private var trashHovering = false

    /// Three jobs, three zones, no overlap: the grip drags, the content is a
    /// plain `Button` that pastes, and the pin/trash cluster sits outside both.
    /// In a panel that never takes focus, a `Button` is the only thing AppKit
    /// delivers a first click to reliably.
    var body: some View {
        HStack(spacing: 0) {
            handle
            contentZone
            trailing
        }
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .contextMenu {
            if showPin {
                Button(item.pinned ? "Desafixar" : "Fixar") { onTogglePin() }
            }
            Menu("Adicionar a") {
                ForEach(tables) { table in
                    Button(table.name) { onAddTo(table) }
                }
                if !tables.isEmpty { Divider() }
                Button("Nova tabela…") { onAddToNew() }
                    .disabled(!canAddTable)
            }
            Divider()
            Button(showPin ? "Apagar" : "Remover da tabela", role: .destructive) { onDelete() }
        }
    }

    /// The grip: six dots, the one place a drag starts. It keeps its width when
    /// hidden so the row never shifts as the pointer comes and goes.
    private var handle: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.5) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(.tertiary)
        .frame(width: 18, height: 34)
        .contentShape(Rectangle())
        .opacity(hovering ? 1 : 0)
        .padding(.leading, 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(ContentView.panelSpace))
                .onChanged(onDragChanged)
                .onEnded(onDragEnded)
        )
        .onHover { inside in
            (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }
    }

    private var contentZone: some View {
        Button(action: onChoose) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    content
                    meta
                }
                Spacer(minLength: 4)
            }
            .padding(.leading, 4)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rowBackground: Color {
        if selected { return Brand.tint.opacity(0.22) }
        if hovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    /// Trailing controls: pin toggle + (trash on hover / ⌘N otherwise).
    /// Both slots keep their 26×26 hit area at all times — only the opacity
    /// fades, so a fast click lands even before hover has propagated.
    private var trailing: some View {
        HStack(spacing: 2) {
            if showPin {
                Button(action: onTogglePin) {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(item.pinned ? .orange : .secondary)
                        .frame(width: ClipRow.hitSize, height: ClipRow.hitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.pinned ? "Desafixar" : "Fixar")
                .opacity(item.pinned || hovering ? 1 : 0)
            }

            ZStack {
                if showShortcut, index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 0 : 1)
                }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(trashHovering ? .red : .secondary)
                        .frame(width: ClipRow.hitSize, height: ClipRow.hitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showPin ? "Apagar" : "Remover da tabela")
                .opacity(hovering ? 1 : 0)
                .onHover { trashHovering = $0 }
            }
            .frame(width: ClipRow.hitSize, height: ClipRow.hitSize)
        }
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private static let hitSize: CGFloat = 26

    @ViewBuilder private var icon: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "text.alignleft")
                .frame(width: 34, height: 34)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        if item.kind == .image {
            Text("Imagem").font(.system(size: 13, weight: .medium))
        } else {
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 13))
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private var meta: some View {
        HStack(spacing: 6) {
            if let src = item.sourceApp {
                Text(src)
                Text("·")
            }
            Text(item.date, format: .relative(presentation: .numeric))
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
}
