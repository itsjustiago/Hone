import ApplicationServices

/// One `AXObserver` per running app, reporting when one of its windows goes away.
///
/// The window-destroyed notification is delivered **per element**, not by the
/// application element, so every window has to be registered individually: the
/// ones open when the watcher attaches, plus each new one announced by
/// `kAXWindowCreatedNotification`.
///
/// The watcher only ever reports destruction — it never says anything on attach.
/// An app that has just launched and hasn't drawn its first window yet must not
/// look like an app whose last window was closed.
@MainActor
final class AppWindowWatcher {
    let pid: pid_t

    /// A window of this app was destroyed; it *may* now have none left. Counting
    /// is the controller's job — this is only the trigger.
    var onWindowDestroyed: (() -> Void)?

    private let appElement: AXUIElement
    private var observer: AXObserver?

    /// Every window we registered on, kept so teardown can unregister exactly
    /// what was registered.
    private var observedWindows: [AXUIElement] = []

    init?(pid: pid_t) {
        var observer: AXObserver?
        guard AXObserverCreate(pid, axWatcherCallback, &observer) == .success,
              let created = observer
        else { return nil }

        self.pid = pid
        self.appElement = AXUIElementCreateApplication(pid)
        self.observer = created

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, appElement, kAXWindowCreatedNotification as CFString, refcon)

        // A short deadline: an app that doesn't answer just gets watched from its
        // next window onwards, rather than holding up the whole attach pass.
        for window in AX.windows(ofApplication: pid, timeout: 0.25).windows {
            observe(window)
        }
    }

    /// Unregisters everything and detaches from the run loop. Must be called
    /// before the watcher is released — the observer holds an unretained refcon
    /// back to it.
    func stop() {
        guard let observer else { return }
        for window in observedWindows {
            AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString)
        }
        observedWindows.removeAll()
        AXObserverRemoveNotification(observer, appElement, kAXWindowCreatedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        onWindowDestroyed = nil
    }

    fileprivate func handle(notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            observe(element)
        case kAXUIElementDestroyedNotification:
            forget(element)
            onWindowDestroyed?()
        default:
            break
        }
    }

    private func observe(_ window: AXUIElement) {
        guard let observer, !observedWindows.contains(where: { CFEqual($0, window) }) else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon) == .success
        else { return }
        observedWindows.append(window)
    }

    private func forget(_ window: AXUIElement) {
        observedWindows.removeAll { CFEqual($0, window) }
    }
}

/// C trampoline. `AXObserverGetRunLoopSource` was added to the main run loop, so
/// this always lands on the main thread — same shape as the event-tap callbacks.
private func axWatcherCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let watcher = Unmanaged<AppWindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        watcher.handle(notification: name, element: element)
    }
}
