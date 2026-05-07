import AppKit
import Common

/// Manages the full lifecycle of the workspace overview: snapshot window frames,
/// move windows into a Mission-Control-style grid, show dim panel + HUD, and
/// restore window positions on close.
@MainActor final class OverviewManager {
    static let shared = OverviewManager()
    private init() {}

    private var snapshots: [OverviewWindowSnapshot] = []
    private var snapshotIds: Set<UInt32> = []

    /// Monitor the overview is anchored to, identified by `rect.topLeftCorner` so it
    /// survives display reconfiguration. Captured on activate; the grid, HUD, and dim
    /// panel are scoped to this monitor. nil while the overview is closed.
    private var anchorMonitorCorner: CGPoint?

    /// True from the moment deactivate() starts until it's done. Used by the auto-close
    /// hook in setFocus to avoid re-entering deactivate while a tear-down is in flight.
    private(set) var isClosing: Bool = false

    /// True while applyOverviewLayout is running. Blocks recursive refreshLayout calls
    /// triggered by AX events from our own setAxFrameBlocking calls.
    private(set) var isRefreshing: Bool = false

    func isWindowInOverview(_ windowId: UInt32) -> Bool { snapshotIds.contains(windowId) }

    /// True when the given workspace lives on the monitor the overview is anchored to.
    /// Lets cross-monitor focus changes skip the overview-sync hook so the grid keeps
    /// running on monitor A while the user works on monitor B.
    func isOnAnchorMonitor(_ workspace: Workspace) -> Bool {
        guard let corner = anchorMonitorCorner else { return false }
        return workspace.workspaceMonitor.rect.topLeftCorner == corner
    }

    /// True when the given monitor is the anchor monitor.
    /// Used by `layoutWorkspaces` to skip the anchor monitor — overview owns its frames —
    /// while still laying out other monitors so cross-monitor workspace switches reflect.
    func isAnchorMonitor(_ monitor: Monitor) -> Bool {
        guard let corner = anchorMonitorCorner else { return false }
        return monitor.rect.topLeftCorner == corner
    }

    /// True if the named workspace would pass the overview's allowlist/excludelist filter.
    /// Empty workspaces still return true here — they're filtered at activation by
    /// `selectWorkspaces`, which combines this check with isEffectivelyEmpty.
    func isWorkspaceEligibleForOverview(_ name: String?) -> Bool {
        guard let name else { return false }
        let cfg = config.overview
        if let allowList = cfg.workspaces { return allowList.contains(name) }
        if !cfg.excludeWorkspaces.isEmpty { return !cfg.excludeWorkspaces.contains(name) }
        return true
    }

    /// Returns the workspace at the grid-adjacent cell in the given direction.
    /// Used by FocusCommand to wrap ctrl+arrow keys to adjacent workspaces while
    /// the overview is open.
    func adjacentSelectedWorkspace(from name: String, direction: CardinalDirection) -> Workspace? {
        let workspaces = selectWorkspaces()
        guard let idx = workspaces.firstIndex(where: { $0.name == name }) else { return nil }
        let cols = resolveColumns(forCount: workspaces.count)
        let delta: Int = switch direction {
            case .left: -1
            case .right: 1
            case .up: -cols
            case .down: cols
        }
        let target = idx + delta
        guard workspaces.indices.contains(target) else { return nil }
        return workspaces[target]
    }

    func activate() async throws {
        guard !isOverviewActive else {
            try await deactivate(selectWorkspace: nil)
            return
        }
        anchorMonitorCorner = focus.workspace.workspaceMonitor.rect.topLeftCorner
        isOverviewActive = true
        try await applyOverviewLayout(initialOpen: true)
    }

    /// Refresh the layout while overview is already open. Idempotent and safe to call
    /// repeatedly (e.g. when a window was closed, a new window appeared, or the tree
    /// state otherwise drifted).
    func refreshLayout() async throws {
        guard isOverviewActive, !isClosing, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        try await applyOverviewLayout(initialOpen: false)
    }

    private func applyOverviewLayout(initialOpen: Bool) async throws {
        let selectedWorkspaces = selectWorkspaces()
        guard let anchor = resolveAnchorMonitor(), !selectedWorkspaces.isEmpty else {
            if initialOpen {
                isOverviewActive = false
                anchorMonitorCorner = nil
            } else {
                try await deactivate(selectWorkspace: nil)
            }
            return
        }

        // Refresh tree weights for each selected workspace without moving windows.
        // Inactive workspaces' children weights may be stale after a node was moved
        // out (the remaining nodes' weights weren't redistributed). dryRun=true
        // bypasses the isOverviewActive guard inside layoutRecursive.
        for workspace in selectedWorkspaces {
            try await workspace.layoutWorkspace(dryRun: true)
        }

        // Unhide floating windows so getAxRect returns valid positions (idempotent).
        for workspace in selectedWorkspaces {
            for window in workspace.allLeafWindowsRecursive.compactMap({ $0 as? MacWindow }) {
                window.unhideFromCorner()
            }
        }

        // If the user opened the overview from a workspace that isn't in the grid
        // (e.g. workspace 7 with [overview] workspaces = ['1'..'6']), corner-hide its
        // windows so they don't occlude the cells. The post-deactivate layoutWorkspaces
        // pass un-hides the active workspace's windows automatically on Esc / commit.
        let focusedWs = focus.workspace
        if !selectedWorkspaces.contains(focusedWs) && focusedWs.workspaceMonitor.rect.topLeftCorner == anchor.rect.topLeftCorner {
            for window in focusedWs.allLeafWindowsRecursive.compactMap({ $0 as? MacWindow }) {
                try await window.hideInCorner(.bottomRightCorner)
            }
        }

        // Snapshot every window. Preserve `frame` from existing snapshots so restore-on-Esc
        // returns to the pre-overview position even after a refresh-layout pass.
        let existingFrames: [UInt32: Rect] = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.windowId, $0.frame) })
        var newSnapshots: [OverviewWindowSnapshot] = []
        for workspace in selectedWorkspaces {
            for window in workspace.allLeafWindowsRecursive.compactMap({ $0 as? MacWindow }) {
                let frame: Rect? = if let existing = existingFrames[window.windowId] {
                    existing
                } else if let layoutRect = window.lastAppliedLayoutPhysicalRect {
                    layoutRect
                } else {
                    try await window.getAxRect()
                }
                guard let frame else { continue }
                newSnapshots.append(OverviewWindowSnapshot(window: window, frame: frame, workspaceName: workspace.name))
            }
        }
        guard !newSnapshots.isEmpty else {
            if initialOpen {
                isOverviewActive = false
            } else {
                try await deactivate(selectWorkspace: nil)
            }
            return
        }

        let monitorRect = anchor.visibleRect
        let (overviewCells, columns) = computeOverviewCells(for: selectedWorkspaces, monitorRect: monitorRect)
        let cellByName: [String: OverviewCell] = Dictionary(uniqueKeysWithValues: overviewCells.map { ($0.workspaceName, $0) })

        // Move windows into their cell slots (blocking so the HUD doesn't reveal before
        // the move). For tiling windows, use the freshly-computed lastAppliedLayoutPhysicalRect
        // (from the dry-run pass above) for cell positioning so existing windows reflow
        // when neighbors are added or removed. snapshot.frame is reserved for restore.
        // Fullscreen windows fill their cell so the toggle is visible mid-overview.
        for snapshot in newSnapshots {
            guard let cell = cellByName[snapshot.workspaceName] else { continue }
            let targetFrame: Rect
            if snapshot.window.isFullscreen {
                targetFrame = cell.frame
            } else {
                let positioningFrame = snapshot.window.lastAppliedLayoutPhysicalRect ?? snapshot.frame
                targetFrame = windowFrameInCell(originalFrame: positioningFrame, cell: cell, monitorRect: monitorRect)
            }
            try await snapshot.window.setAxFrameBlocking(
                targetFrame.topLeftCorner,
                CGSize(width: targetFrame.width, height: targetFrame.height),
            )
        }
        self.snapshots = newSnapshots
        self.snapshotIds = Set(newSnapshots.map(\.windowId))

        let dimOpacity = config.overview.dimBackground ? config.overview.dimOpacity : 0.0
        OverviewDimPanel.shared.show(monitorFrame: monitorRect, opacity: dimOpacity)

        let hudCells = buildHudCells(for: overviewCells, monitorRect: monitorRect)
        OverviewHUD.shared.show(
            monitorFrame: monitorRect,
            cells: hudCells,
            columnCount: columns,
            onCommit: { [weak self] workspaceName in
                guard let self else { return }
                Task { @MainActor in try? await self.deactivate(selectWorkspace: workspaceName) }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                Task { @MainActor in try? await self.deactivate(selectWorkspace: nil) }
            },
        )
    }

    func deactivate(selectWorkspace: String?) async throws {
        guard !isClosing else { return }
        isClosing = true
        defer {
            isOverviewActive = false
            isClosing = false
            snapshots = []
            snapshotIds = []
            anchorMonitorCorner = nil
            scheduleCancellableCompleteRefreshSession(.hotkeyBinding)
        }

        OverviewHUD.shared.hide()
        OverviewDimPanel.shared.close()

        // Sequential restore avoids AX rate-limit issues for multiple windows in the same app.
        for snapshot in snapshots {
            try await snapshot.window.setAxFrameBlocking(
                snapshot.frame.topLeftCorner,
                CGSize(width: snapshot.frame.width, height: snapshot.frame.height),
            )
        }

        // focusWorkspace updates _focus to point at the workspace's MRU window.
        // The explicit nativeFocus drives NSApp.activate at the macOS level —
        // without it, the post-deactivate refresh's updateFocusCache(getNativeFocusedWindow)
        // would observe whichever app was macOS-focused before the overview opened
        // and snap _focus back, undoing the user's chosen target.
        if let name = selectWorkspace {
            let workspace = Workspace.get(byName: name)
            _ = workspace.focusWorkspace()
            if let mru = workspace.mostRecentWindowRecursive as? MacWindow {
                mru.nativeFocus()
            }
        }
    }

    /// Workspaces currently displayed in the overview grid. Empty array when the
    /// overview is not active. Public so `workspace next/prev` can iterate the same
    /// list the user sees while the overview is open.
    func displayedWorkspaces() -> [Workspace] {
        isOverviewActive ? selectWorkspaces() : []
    }

    private func selectWorkspaces() -> [Workspace] {
        let anchorCorner = anchorMonitorCorner
        return Workspace.all.filter { workspace in
            guard !workspace.isEffectivelyEmpty else { return false }
            // When opened on a multi-monitor setup, scope the grid to the monitor the
            // overview was activated on — workspaces on other monitors stay untouched.
            if let anchorCorner, workspace.workspaceMonitor.rect.topLeftCorner != anchorCorner { return false }
            return isWorkspaceEligibleForOverview(workspace.name)
        }
    }

    private func resolveAnchorMonitor() -> Monitor? {
        guard let corner = anchorMonitorCorner else { return nil }
        return monitors.first(where: { $0.rect.topLeftCorner == corner })
    }

    struct OverviewCell {
        let workspaceName: String
        /// Cell rect on monitor in AeroSpace coordinates (top-left origin, Y-down).
        let frame: Rect
    }

    /// Mission-Control-style column count: 1→1, 2→2, 3→3, 4→2 (2×2), 5–6→3, 7–8→4, 9+→3.
    private func autoColumns(forCount count: Int) -> Int {
        switch count {
            case ...1: return 1
            case 2: return 2
            case 3: return 3
            case 4: return 2
            case 5 ... 6: return 3
            case 7 ... 8: return 4
            default: return 3
        }
    }

    private func resolveColumns(forCount count: Int) -> Int {
        switch config.overview.columns {
            case .auto: return autoColumns(forCount: count)
            case .fixed(let n): return max(1, n)
        }
    }

    private func computeOverviewCells(for workspaces: [Workspace], monitorRect: Rect) -> ([OverviewCell], Int) {
        let count = workspaces.count
        guard count > 0 else { return ([], 1) }

        let columns = resolveColumns(forCount: count)
        let rows = Int(ceil(Double(count) / Double(columns)))

        let padding: CGFloat = 14
        let cellW = (monitorRect.width - padding * CGFloat(columns + 1)) / CGFloat(columns)
        let cellH = (monitorRect.height - padding * CGFloat(rows + 1)) / CGFloat(rows)

        let cells = workspaces.enumerated().map { index, workspace in
            let col = index % columns
            let row = index / columns
            let x = monitorRect.topLeftX + padding + CGFloat(col) * (cellW + padding)
            let y = monitorRect.topLeftY + padding + CGFloat(row) * (cellH + padding)
            return OverviewCell(
                workspaceName: workspace.name,
                frame: Rect(topLeftX: x, topLeftY: y, width: cellW, height: cellH),
            )
        }
        return (cells, columns)
    }

    /// Scale a window's original frame into its cell proportionally.
    private func windowFrameInCell(originalFrame: Rect, cell: OverviewCell, monitorRect: Rect) -> Rect {
        let scaleX = cell.frame.width / monitorRect.width
        let scaleY = cell.frame.height / monitorRect.height

        let relX = originalFrame.topLeftX - monitorRect.topLeftX
        let relY = originalFrame.topLeftY - monitorRect.topLeftY

        let newX = cell.frame.topLeftX + relX * scaleX
        let newY = cell.frame.topLeftY + relY * scaleY
        let newW = max(80, originalFrame.width * scaleX)
        let newH = max(60, originalFrame.height * scaleY)

        return Rect(topLeftX: newX, topLeftY: newY, width: newW, height: newH)
    }

    private func buildHudCells(for overviewCells: [OverviewCell], monitorRect: Rect) -> [OverviewCellInfo] {
        let snapshotsByWorkspace: [String: [OverviewWindowSnapshot]] = Dictionary(grouping: snapshots, by: \.workspaceName)
        let cellLabel = config.overview.cellLabel

        return overviewCells.map { cell in
            let relX = cell.frame.topLeftX - monitorRect.topLeftX
            let relY = cell.frame.topLeftY - monitorRect.topLeftY
            let hudFrame = CGRect(x: relX, y: relY, width: cell.frame.width, height: cell.frame.height)

            let appNames = (snapshotsByWorkspace[cell.workspaceName] ?? [])
                .map { $0.window.app.name?.takeIf { !$0.isEmpty } }
                .filterNotNil()
                .toOrderedSet()
                .elements

            return OverviewCellInfo(
                id: cell.workspaceName,
                workspaceName: cell.workspaceName,
                hudFrame: hudFrame,
                label: formatCellLabel(workspaceName: cell.workspaceName, appNames: appNames, style: cellLabel),
            )
        }
    }

    private func formatCellLabel(workspaceName: String, appNames: [String], style: OverviewCellLabel) -> String {
        switch style {
            case .workspaceName: return workspaceName
            case .appList: return appNames.prefix(3).joined(separator: ", ")
            case .both:
                let apps = appNames.prefix(3).joined(separator: ", ")
                return apps.isEmpty ? workspaceName : "\(workspaceName): \(apps)"
        }
    }
}
