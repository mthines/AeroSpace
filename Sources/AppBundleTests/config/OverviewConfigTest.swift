@testable import AppBundle
import Common
import XCTest

@MainActor
final class OverviewConfigTest: XCTestCase {

    // MARK: - Defaults

    func testDefaultValues() {
        let (config, errors) = parseOverviewTestConfig("")
        assertEquals(errors, [])
        let ov = config.overview
        XCTAssertNil(ov.workspaces)
        assertEquals(ov.excludeWorkspaces, [])
        assertEquals(ov.columns, OverviewColumns.auto)
        assertEquals(ov.cellLabel, OverviewCellLabel.workspaceName)
        assertEquals(ov.dimBackground, true)
        // Default dimOpacity = 0.7 (user writes dim-opacity = 70)
        XCTAssertEqual(ov.dimOpacity, 0.7, accuracy: 0.001)
    }

    // MARK: - Workspaces allowlist

    func testWorkspacesAllowlist() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            workspaces = ['1', '2', '3']
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.overview.workspaces, ["1", "2", "3"])
        assertEquals(config.overview.excludeWorkspaces, [])
    }

    func testEmptyWorkspacesAllowlist() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            workspaces = []
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.overview.workspaces, [])
    }

    // MARK: - Exclude workspaces denylist

    func testExcludeWorkspaces() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            exclude-workspaces = ['9']
            """,
        )
        assertEquals(errors, [])
        XCTAssertNil(config.overview.workspaces)
        assertEquals(config.overview.excludeWorkspaces, ["9"])
    }

    // MARK: - Mutual exclusion error

    func testWorkspacesAndExcludeWorkspacesMutuallyExclusive() {
        let (_, errors) = parseOverviewTestConfig(
            """
            [overview]
            workspaces = ['1', '2']
            exclude-workspaces = ['9']
            """,
        )
        XCTAssertTrue(
            errors.singleOrNil()?.contains("mutually exclusive") == true,
            "Expected mutual exclusion error, got: \(errors)",
        )
    }

    // MARK: - Columns

    func testColumnsAuto() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            columns = 'auto'
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.overview.columns, OverviewColumns.auto)
    }

    func testColumnsFixed() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            columns = 3
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.overview.columns, OverviewColumns.fixed(3))
    }

    func testColumnsNegativeError() {
        let (_, errors) = parseOverviewTestConfig(
            """
            [overview]
            columns = -1
            """,
        )
        XCTAssertFalse(errors.isEmpty, "Expected error for negative columns")
    }

    func testColumnsZeroError() {
        let (_, errors) = parseOverviewTestConfig(
            """
            [overview]
            columns = 0
            """,
        )
        XCTAssertFalse(errors.isEmpty, "Expected error for zero columns")
    }

    func testColumnsInvalidStringError() {
        let (_, errors) = parseOverviewTestConfig(
            """
            [overview]
            columns = 'invalid'
            """,
        )
        XCTAssertFalse(errors.isEmpty, "Expected error for invalid columns string")
    }

    // MARK: - Cell label

    func testCellLabelWorkspaceName() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            cell-label = 'workspace-name'
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.overview.cellLabel, OverviewCellLabel.workspaceName)
    }

    func testCellLabelAppList() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            cell-label = 'app-list'
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.overview.cellLabel, OverviewCellLabel.appList)
    }

    func testCellLabelBoth() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            cell-label = 'both'
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.overview.cellLabel, OverviewCellLabel.both)
    }

    func testCellLabelInvalidError() {
        let (_, errors) = parseOverviewTestConfig(
            """
            [overview]
            cell-label = 'screenshot'
            """,
        )
        XCTAssertFalse(errors.isEmpty, "Expected error for invalid cell-label")
    }

    // MARK: - Dim settings

    func testDimBackgroundFalse() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            dim-background = false
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.overview.dimBackground, false)
    }

    func testDimOpacityInteger() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            dim-opacity = 40
            """,
        )
        assertEquals(errors, [])
        XCTAssertEqual(config.overview.dimOpacity, 0.40, accuracy: 0.001)
    }

    func testDimOpacityZero() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            dim-opacity = 0
            """,
        )
        assertEquals(errors, [])
        XCTAssertEqual(config.overview.dimOpacity, 0.0, accuracy: 0.001)
    }

    func testDimOpacity100() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            dim-opacity = 100
            """,
        )
        assertEquals(errors, [])
        XCTAssertEqual(config.overview.dimOpacity, 1.0, accuracy: 0.001)
    }

    func testDimOpacityOutOfRangeError() {
        let (_, errors) = parseOverviewTestConfig(
            """
            [overview]
            dim-opacity = 101
            """,
        )
        XCTAssertFalse(errors.isEmpty, "Expected error for dim-opacity out of range")
    }

    // MARK: - All keys together

    func testAllKeysValid() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [overview]
            workspaces = ['1', '2']
            columns = 2
            cell-label = 'both'
            dim-background = true
            dim-opacity = 70
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.overview.workspaces, ["1", "2"])
        assertEquals(config.overview.columns, OverviewColumns.fixed(2))
        assertEquals(config.overview.cellLabel, OverviewCellLabel.both)
        assertEquals(config.overview.dimBackground, true)
        XCTAssertEqual(config.overview.dimOpacity, 0.7, accuracy: 0.001)
    }

    // MARK: - Overview command in hotkey binding

    func testOverviewCommandInHotkeyBinding() {
        let (config, errors) = parseOverviewTestConfig(
            """
            [mode.main.binding]
            ctrl-alt-o = 'overview'
            """,
        )
        assertEquals(errors, [])
        let modeBindings = config.modes[mainModeId]?.bindings ?? [:]
        let hasOverview = modeBindings.values.contains(where: {
            $0.commands.flatten().contains(where: { $0 is OverviewCommand })
        })
        XCTAssertTrue(hasOverview, "Expected overview command in hotkey binding")
    }
}

/// `parseConfig` result as (config, error messages) — the shape these tests are written against.
@MainActor
private func parseOverviewTestConfig(_ toml: String) -> (Config, [String]) {
    let result = parseConfig(toml)
    return (result.config, result.strErrors)
}
