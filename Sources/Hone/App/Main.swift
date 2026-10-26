import AppKit
import Foundation

/// Entry point. `HONE_RENDER_PREVIEWS=<folder>` renders the popover's previews
/// to PNGs and exits before anything else runs: no app delegate, no modules,
/// no status items, no defaults written — safe beside the Hone that's running.
/// `HONE_ISLAND_FRAME_PROBE=<file>` measures the island's animations into that file
/// and exits the same way (see `IslandFrameProbe`).
@main
enum HoneMain {
    @MainActor
    static func main() {
        if let folder = ProcessInfo.processInfo.environment["HONE_RENDER_PREVIEWS"], !folder.isEmpty {
            exit(PreviewRenderer.renderAll(to: URL(fileURLWithPath: folder)) ? 0 : 1)
        }
        if let file = ProcessInfo.processInfo.environment["HONE_ISLAND_FRAME_PROBE"], !file.isEmpty {
            IslandFrameProbe.run(writingTo: URL(fileURLWithPath: file))
        }
        HoneApp.main()
    }
}
