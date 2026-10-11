@testable import AppBundle
import Common
import XCTest

@MainActor
final class OverviewCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseWindowsFlag() {
        let windowsArgs = (parseCommand("overview --windows").cmdOrDie as? OverviewCommand)?.args
        assertEquals(windowsArgs?.windows, true)
        assertEquals(windowsArgs?.suspend, false)
        assertEquals(windowsArgs?.resume, false)

        assertEquals((parseCommand("overview").cmdOrDie as? OverviewCommand)?.args.windows, false)
    }

    func testParseIncompatibleFlags() {
        assertEquals(parseCommand("overview --windows --suspend").errorOrNil, "--windows is incompatible with --suspend and --resume")
        assertEquals(parseCommand("overview --resume --windows").errorOrNil, "--windows is incompatible with --suspend and --resume")
        assertEquals(parseCommand("overview --suspend --resume").errorOrNil, "--suspend and --resume are mutually exclusive")
    }

    func testWindowsFlagInHotkeyBinding() {
        let (config, errors) = parseConfig(
            """
            [mode.main.binding]
            alt-shift-tab = 'overview --windows'
            """,
        )
        assertEquals(errors, [])
        let commands = config.modes[mainModeId]?.bindings.values.flatMap(\.commands) ?? []
        let overview = commands.compactMap { $0 as? OverviewCommand }.singleOrNil()
        assertEquals(overview?.args.windows, true)
    }

    func testOverviewGridWindowsOrderAndExclusions() {
        let workspace = Workspace.get(byName: name).apply {
            $0.rootTilingContainer.apply {
                TestWindow.new(id: 1, parent: $0)
                TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 2, parent: $0)
                    TestWindow.new(id: 3, parent: $0)
                }
            }
            TestWindow.new(id: 4, parent: $0) // floating
            TestWindow.new(id: 5, parent: $0.macOsNativeFullscreenWindowsContainer) // owned by macOS, can't be moved
        }
        // Tiling windows in tree (dfs) order, then floating windows
        assertEquals(workspace.overviewGridWindows.map(\.windowId), [1, 2, 3, 4])
    }

    func testWindowCellLabel() {
        assertEquals(overviewWindowCellLabel(appName: "Safari", title: "Apple"), "Safari: Apple")
        assertEquals(overviewWindowCellLabel(appName: "Finder", title: "Finder"), "Finder")
        assertEquals(overviewWindowCellLabel(appName: "Terminal", title: ""), "Terminal")
        assertEquals(overviewWindowCellLabel(appName: nil, title: "Untitled"), "Untitled")
        assertEquals(overviewWindowCellLabel(appName: "", title: ""), "")
    }
}
