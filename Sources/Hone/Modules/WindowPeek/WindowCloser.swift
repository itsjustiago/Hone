import ApplicationServices

/// Closes one window from a preview's X.
///
/// It presses the window's own close button through the Accessibility API, which
/// is exactly what clicking the red dot does — the app still gets to run its
/// "save changes?" sheet, and nothing is forced. A window with no close button
/// (a panel, a full-screen tile) simply reports back as not closed, so the caller
/// can leave its card in place instead of lying about it.
enum WindowCloser {
    @discardableResult
    static func close(_ window: WindowInfo) -> Bool {
        guard let element = AX.window(for: window),
              let button = AX.element(element, "AXCloseButton")
        else { return false }
        return AX.perform(button, "AXPress")
    }
}
