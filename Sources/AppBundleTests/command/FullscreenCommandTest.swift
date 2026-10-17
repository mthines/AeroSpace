@testable import AppBundle
import Common
import XCTest

@MainActor
final class FullscreenCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testTogglesWhenOverviewIsClosed() async {
        let window = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
        }.children.first as! Window
        assertEquals(window.focusWindow(), true)

        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, true)

        await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, false)
    }
}
