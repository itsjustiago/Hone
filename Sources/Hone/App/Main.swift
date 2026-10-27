import AppKit
import Foundation

/// Entry point. `HONE_RENDER_PREVIEWS=<folder>` renders the popover's previews
/// to PNGs and exits before anything else runs: no app delegate, no modules,
/// no status items, no defaults written — safe beside the Hone that's running.
/// `HONE_ISLAND_FRAME_PROBE=<file>` measures the island's animations into that file
/// and exits the same way (see `IslandFrameProbe`). `HONE_CLAUDE_DUMP=1` prints what
/// the island knows about Claude Code sessions and exits (see `ClaudeActivityDump`).
/// `HONE_ISLAND_SCREENS_DUMP=1` prints where the island would go on each connected
/// screen, with no window, and exits (see `IslandScreensDump`).
@main
enum HoneMain {
    @MainActor
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["HONE_RENDER_PREVIEWS"], !folder.isEmpty {
            exit(PreviewRenderer.renderAll(to: URL(fileURLWithPath: folder)) ? 0 : 1)
        }
        if let file = environment["HONE_ISLAND_FRAME_PROBE"], !file.isEmpty {
            IslandFrameProbe.run(writingTo: URL(fileURLWithPath: file))
        }
        if environment["HONE_CLAUDE_DUMP"] == "1" {
            ClaudeActivityDump.run(environment: environment)
        }
        if environment["HONE_ISLAND_SCREENS_DUMP"] == "1" {
            IslandScreensDump.run()
        }
        HoneApp.main()
    }
}
