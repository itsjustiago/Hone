import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

/// Search text + keyboard selection in the history, shared between the key
/// handler and the SwiftUI view.
final class PanelViewModel: ObservableObject {
    @Published var query = ""
    @Published var selectedIndex = 0
    @Published var focusPulse = 0
    /// Mirrors the search field's focus for the view's own use. The key handlers
    /// ask AppKit instead — see `typingInPanel`.
    @Published var searchActive = false
    /// The table whose name is in edit mode, so Escape can cancel from outside.
    /// The rename state is read from here and never from `@FocusState`: a focus
    /// flag left stuck at true would hand every keystroke to the app underneath.
    @Published var editingTable: UUID?
    /// The table with an open inline composer, read here for the same reason.
    @Published var composingTable: UUID?
    /// Text being typed into a table's composer. It lives here so Return can be
    /// committed by the key handler instead of relying on the field's `onSubmit`.
    @Published var draftEntry = ""
    /// True while an inline text field owns the keyboard — rename or compose.
    var isEditing: Bool { editingTable != nil || composingTable != nil }

    /// Escape closes whichever inline field is open, composer first.
    func cancelEditing() {
        if composingTable != nil {
            composingTable = nil
        } else {
            editingTable = nil
        }
    }
    /// Which card the keyboard is driving. ← and → walk it across the cards.
    @Published var keyboardOrigin: ClipOrigin = .history
    /// The cards' rectangles, in the panel's own coordinate space. The window
    /// spans the gaps between them, so a click has to be tested against these
    /// and not against the whole frame.
    @Published var cardRects: [CGRect] = []
    /// Room the table cards have next to the main card; the controller sizes the
    /// window and the view scrolls the strip when the cards no longer fit.
    @Published var tablesWidth: CGFloat = 0
    unowned let store: HistoryStore
    unowned let collections: CollectionStore

    init(store: HistoryStore, collections: CollectionStore) {
        self.store = store
        self.collections = collections
    }

    /// The history card's list: everything, or what matches the search.
    func filtered() -> [ClipItem] {
        let base = store.orderedItems
        guard !query.isEmpty else { return base }
        return base.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
    }

    /// The list the keyboard is pointing at.
    func focusedItems() -> [ClipItem] {
        switch keyboardOrigin {
        case .history:
            return filtered()
        case .table(let id):
            return collections.table(id)?.items ?? []
        }
    }

    /// Every card, left to right — the order ← and → walk.
    private var origins: [ClipOrigin] {
        [.history] + collections.tables.map { .table($0.id) }
    }

    /// Steps the keyboard one card sideways. Stops at the ends instead of
    /// wrapping, so holding an arrow doesn't loop around.
    func moveFocus(_ delta: Int) {
        let all = origins
        let current = all.firstIndex(of: keyboardOrigin) ?? 0
        let next = min(max(current + delta, 0), all.count - 1)
        guard next != current else { return }
        keyboardOrigin = all[next]
        selectedIndex = 0
    }

    /// A table that goes away must not keep the keyboard.
    func validateFocus() {
        if case .table(let id) = keyboardOrigin, collections.table(id) == nil {
            keyboardOrigin = .history
            selectedIndex = 0
        }
    }
}

/// The panel is up without focus, so AppKit would spend the first click just
/// bringing it forward and rows would need two clicks to paste. Taking the first
/// mouse makes every click count, which is how the rows behaved as buttons.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    required init(rootView: Content) { super.init(rootView: rootView) }
}

/// Borderless panels can't become key by default — allow it so the search field works.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Builds and drives the floating history panel: showing, keyboard control, and paste-back.
final class PanelController: NSObject, NSWindowDelegate {
    /// Open the panel without taking focus, so the app underneath keeps its text
    /// selection. Needs Accessibility (the key tap); falls back when unavailable.
    static var preserveFocus: Bool {
        get { ClippyDefaults.store.object(forKey: "preserveFocus") as? Bool ?? true }
        set { ClippyDefaults.store.set(newValue, forKey: "preserveFocus") }
    }

    private let store: HistoryStore
    private let collections: CollectionStore
    private let clipboard: ClipboardManager
    private let vm: PanelViewModel
    private var panel: FloatingPanel?
    private var monitor: Any?
    private var outsideClicks: Any?
    private let keyTap = KeyTap()
    /// Keeps the window as wide as the cards it has to show.
    private var tablesObserver: AnyCancellable?
    private var previousApp: NSRunningApplication?
    /// True while the panel is up without ever having taken focus.
    private var keptFocus = false

    init(store: HistoryStore, collections: CollectionStore, clipboard: ClipboardManager) {
        self.store = store
        self.collections = collections
        self.clipboard = clipboard
        self.vm = PanelViewModel(store: store, collections: collections)
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        vm.query = ""
        vm.selectedIndex = 0
        vm.searchActive = false
        vm.keyboardOrigin = .history
        vm.editingTable = nil
        vm.composingTable = nil
        vm.focusPulse += 1
        position(panel)
        addMonitor()

        // Preferred path: show the panel without activating Clippy, so whatever
        // had focus keeps it — selected text stays selected, carets keep
        // blinking, and web pages never see a blur. The tap drives the keyboard
        // in place of the key window we deliberately don't become.
        if PanelController.preserveFocus, startKeyTap() {
            keptFocus = true
            watchOutsideClicks()
            panel.orderFrontRegardless()
        } else {
            keptFocus = false
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        removeMonitor()
        stopWatchingOutsideClicks()
        keyTap.stop()
        panel?.orderOut(nil)
    }

    // MARK: - Building

    private func build() {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: ContentView.mainWidth, height: ContentView.cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window spans the cards and the gaps between them, so its own
        // shadow would outline the empty space — each card draws its own.
        panel.hasShadow = false
        // Off on purpose: with it on, AppKit starts moving the window on the
        // first drag over anything that isn't an AppKit control, and a SwiftUI
        // gesture never gets the chance to claim it — which is exactly what the
        // rows' drag handles need. The panel opens at the pointer anyway.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let root = ContentView(
            store: store, collections: collections, vm: vm,
            onChoose: { [weak self] item, origin in self?.choose(item, from: origin) },
            onDelete: { [weak self] in self?.deleteSelected($0) },
            onTogglePin: { [weak self] in self?.togglePin($0) },
            onClearAll: { [weak self] in self?.clearAll() },
            onBeginEditing: { [weak self] in self?.takeKeyboard() })
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        // Fires right away with the tables already loaded, so this also sets the
        // initial width.
        tablesObserver = collections.$tables.sink { [weak self] tables in
            self?.resize(tableCount: tables.count)
        }
    }

    /// Window width follows the cards; past the screen the strip scrolls instead.
    private func resize(tableCount: Int) {
        guard let panel else { return }
        let screen = panel.screen ?? NSScreen.main
        let limit = (screen?.visibleFrame.width ?? ContentView.mainWidth) - 16
        var width = ContentView.panelWidth(tableCount: tableCount)
        if width > limit {
            // Round down to whole cards: half a card at the edge reads as a
            // drawing glitch, and the rest of the strip scrolls anyway.
            let room = limit - ContentView.panelWidth(tableCount: 0)
            let fits = max(1, Int(room / (ContentView.tableWidth + ContentView.cardGap)))
            width = ContentView.panelWidth(tableCount: fits)
        }
        vm.tablesWidth = width - ContentView.mainWidth - ContentView.cardGap
        panel.setContentSize(NSSize(width: width, height: ContentView.cardHeight))
        clamp(panel)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        // Open next to the cursor (cursor just inside the top-left), clamped on-screen.
        panel.setFrameOrigin(NSPoint(x: mouse.x - 28, y: mouse.y - size.height + 28))
        clamp(panel)
    }

    /// Keeps the whole window on screen — a new table must never push a card off it.
    private func clamp(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? panel.screen ?? NSScreen.main
        guard let screen else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        var origin = panel.frame.origin
        origin.x = min(max(origin.x, vf.minX + 8), max(vf.minX + 8, vf.maxX - size.width - 8))
        origin.y = min(max(origin.y, vf.minY + 8), max(vf.minY + 8, vf.maxY - size.height - 8))
        panel.setFrameOrigin(origin)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Clicking into the panel (the search field) takes focus after all, so
        // the app underneath has to be re-activated before pasting.
        keptFocus = false
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    /// Without focus the panel never resigns key, so watch for a click elsewhere.
    private func watchOutsideClicks() {
        guard outsideClicks == nil else { return }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !self.pointIsOnACard(NSEvent.mouseLocation, in: panel) { self.hide() }
            }
    }

    /// The cards' rects live in the view's space (origin top-left, y down); the
    /// mouse comes in screen coordinates, so each one is flipped into place.
    private func pointIsOnACard(_ point: NSPoint, in panel: NSPanel) -> Bool {
        let rects = vm.cardRects
        guard !rects.isEmpty else { return NSMouseInRect(point, panel.frame, false) }
        let frame = panel.frame
        return rects.contains { rect in
            let onScreen = NSRect(x: frame.minX + rect.minX,
                                  y: frame.maxY - rect.maxY,
                                  width: rect.width, height: rect.height)
            return NSMouseInRect(point, onScreen, false)
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    // MARK: - Actions

    /// A table item keeps its image in the tables directory, so the URL has to
    /// come from the collection store, not the history.
    private func choose(_ item: ClipItem, from origin: ClipOrigin = .history) {
        let focused = keptFocus   // the target app never lost focus
        let url = origin == .history ? nil : collections.imageURL(for: item)
        hide()
        clipboard.copyToPasteboard(item, imageURL: url)
        pasteToPrevious(reactivate: !focused)
    }

    /// Called from the menu-bar quick list (no panel involved).
    func pasteDirect(_ item: ClipItem) {
        previousApp = NSWorkspace.shared.frontmostApplication
        clipboard.copyToPasteboard(item)
        pasteToPrevious(reactivate: true)
    }

    /// The keyboard only ever deletes from the history; table rows use the trash.
    /// ⌘⌫ deletes from whichever card the keyboard is on — in a table that means
    /// dropping it from the table, never from the history.
    private func deleteSelected(_ item: ClipItem, from origin: ClipOrigin = .history) {
        switch origin {
        case .history:
            store.delete(item)
        case .table(let id):
            guard let table = collections.table(id) else { return }
            collections.remove(item, from: table)
        }
        vm.selectedIndex = min(vm.selectedIndex, max(0, vm.focusedItems().count - 1))
    }

    /// Plain Return while composing. A multiline text field would take it as a
    /// newline, so the panel commits the entry itself; ⇧↵ still breaks the line.
    private func isComposerReturn(_ event: NSEvent) -> Bool {
        guard vm.composingTable != nil, !event.modifierFlags.contains(.shift) else { return false }
        return Int(event.keyCode) == kVK_Return || Int(event.keyCode) == kVK_ANSI_KeypadEnter
    }

    /// Stores what was typed and leaves the composer open for the next one.
    private func commitDraft() {
        guard let id = vm.composingTable, let table = collections.table(id) else { return }
        let text = vm.draftEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        vm.draftEntry = ""
        guard !text.isEmpty else { return }
        collections.addText(text, source: nil, to: table)
    }

    /// Editing a table name needs the keystrokes to land in the text field, so
    /// the panel has to be key — normally it deliberately never is.
    private func takeKeyboard() {
        guard let panel, !panel.isKeyWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Pinning is a history-only concept.
    /// Pinning is a history-only idea; in a table the key does nothing.
    private func togglePin(_ item: ClipItem) {
        guard case .history = vm.keyboardOrigin else { return }
        store.togglePin(item)
    }

    private func clearAll() {
        store.clearUnpinned()
        vm.selectedIndex = 0
    }

    private func pasteToPrevious(reactivate: Bool) {
        // Focus never left the target app: paste straight into it, no round trip.
        guard reactivate else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                if PasteHelper.hasAccessibility(prompt: true) {
                    PasteHelper.paste()
                }
            }
            return
        }
        let prev = previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            prev?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                if PasteHelper.hasAccessibility(prompt: true) {
                    PasteHelper.paste()
                }
            }
        }
    }

    // MARK: - Keyboard

    /// What a key press means to the panel.
    private enum Action {
        case dismiss, up, down, left, right, paste, remove, pin
        case pick(Int)
    }

    private func startKeyTap() -> Bool {
        keyTap.onKeyDown = { [weak self] event in self?.handleTapped(event) ?? false }
        return keyTap.start()
    }

    private func addMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Keys AppKit delivers to us — the panel is key (search field clicked, or
    /// the fallback path where Clippy activated).
    private func handle(_ event: NSEvent) -> NSEvent? {
        // Inline text field (rename or compose): it owns the keyboard. Escape
        // cancels the edit instead of closing the panel; Return reaches `onSubmit`.
        if vm.isEditing {
            if Int(event.keyCode) == kVK_Escape {
                vm.cancelEditing()
                return nil
            }
            if isComposerReturn(event) {
                commitDraft()
                return nil
            }
            return event
        }
        if let action = action(for: event) {
            perform(action)
            return nil
        }
        // Typing only filters if the user clicked the search field first.
        // Otherwise close the panel and pass the keystroke to the app underneath.
        if !typingInPanel {
            forwardKeyToPrevious(keyCode: event.keyCode, flags: event.modifierFlags)
            return nil
        }
        return event
    }

    /// Keys from the tap, while the panel is up but has no focus.
    /// Returns `true` when Clippy claims the key.
    private func handleTapped(_ event: NSEvent) -> Bool {
        // Let the global shortcut through so its handler can toggle us closed.
        if isShortcut(event) { return false }
        // Inline editing: the text field owns everything except Escape, which cancels.
        if vm.isEditing {
            if Int(event.keyCode) == kVK_Escape {
                vm.cancelEditing()
                return true
            }
            guard isComposerReturn(event) else { return false }
            commitDraft()
            return true
        }
        // Arrows, Return, Escape and the ⌘ shortcuts drive the panel even while
        // the search field has focus — otherwise they'd land in the app below.
        if let action = action(for: event) {
            perform(action)
            return true
        }
        // Typing only filters once the user has clicked the search field; the
        // panel is key then, so AppKit hands the key to `handle(_:)`.
        if typingInPanel { return false }
        // Anything else closes the panel and lands in the app underneath, which
        // still has focus — the keystroke carries on, nothing to replay.
        hide()
        return false
    }

    /// True only when a field inside the panel really has the keyboard. Asking
    /// AppKit instead of a SwiftUI `@FocusState` matters: a focus flag can be
    /// left behind as true, and then keystrokes meant for the app underneath
    /// would keep the panel open instead of dismissing it.
    private var typingInPanel: Bool {
        guard let panel, panel.isKeyWindow else { return false }
        return panel.firstResponder is NSText
    }

    private func isShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return Int(event.keyCode) == Shortcut.keyCode && mods == Shortcut.modifiers
    }

    private func action(for event: NSEvent) -> Action? {
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape:
            return .dismiss
        case kVK_DownArrow:
            return .down
        case kVK_UpArrow:
            return .up
        case kVK_LeftArrow:
            return .left
        case kVK_RightArrow:
            return .right
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return .paste
        case kVK_Delete where cmd:
            return .remove
        case kVK_ANSI_P where cmd:
            return .pin
        default:
            if cmd, let index = pickIndex(for: event) { return .pick(index) }
            return nil
        }
    }

    private func perform(_ action: Action) {
        vm.validateFocus()
        let items = vm.focusedItems()
        let origin = vm.keyboardOrigin
        switch action {
        case .dismiss:
            hide()
        case .down:
            if !items.isEmpty { vm.selectedIndex = min(vm.selectedIndex + 1, items.count - 1) }
        case .up:
            if !items.isEmpty { vm.selectedIndex = max(vm.selectedIndex - 1, 0) }
        case .left:
            vm.moveFocus(-1)
        case .right:
            vm.moveFocus(1)
        case .paste:
            if items.indices.contains(vm.selectedIndex) { choose(items[vm.selectedIndex], from: origin) }
        case .remove:
            if items.indices.contains(vm.selectedIndex) { deleteSelected(items[vm.selectedIndex], from: origin) }
        case .pin:
            if items.indices.contains(vm.selectedIndex) { togglePin(items[vm.selectedIndex]) }
        case .pick(let index):
            if items.indices.contains(index) { choose(items[index], from: origin) }
        }
    }

    /// ⌘1…⌘9 → row index. Tapped events can arrive without characters, so fall
    /// back to the physical key.
    private func pickIndex(for event: NSEvent) -> Int? {
        if let s = event.charactersIgnoringModifiers, let n = Int(s), (1...9).contains(n) {
            return n - 1
        }
        if let n = PanelController.digitKeys[Int(event.keyCode)] { return n - 1 }
        return nil
    }

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    /// Closes the panel and re-sends a keystroke to the previously focused app.
    /// Only needed on the fallback path — with the tap the key was never taken.
    private func forwardKeyToPrevious(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let prev = previousApp
        let cgFlags = PasteHelper.cgFlags(from: flags)
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            prev?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if PasteHelper.hasAccessibility(prompt: false) {
                    PasteHelper.postKey(keyCode: CGKeyCode(keyCode), flags: cgFlags)
                }
            }
        }
    }
}
