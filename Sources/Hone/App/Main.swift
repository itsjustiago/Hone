import AppKit
import Foundation

/// Entry point. `HONE_RENDER_PREVIEWS=<folder>` renders the popover's previews
/// to PNGs and exits before anything else runs: no app delegate, no modules,
/// no status items, no defaults written — safe beside the Hone that's running.
@main
enum HoneMain {
    @MainActor
    static func main() {
        if let folder = ProcessInfo.processInfo.environment["HONE_RENDER_PREVIEWS"], !folder.isEmpty {
            exit(PreviewRenderer.renderAll(to: URL(fileURLWithPath: folder)) ? 0 : 1)
        }
        HoneApp.main()
    }
}
