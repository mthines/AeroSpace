import AppKit
import Common

/// Manages the full lifecycle of the overview: snapshot window frames, move windows into a
/// Mission-Control-style grid, show dim panel + HUD, and restore window positions on close.
/// The grid shows either workspaces (one cell per workspace) or the windows of a single
/// workspace (one cell per window) — see `OverviewMode`.
@MainActor final class OverviewManager {
    static let shared = OverviewManager()
    private init() {}

    private var snapshots: [OverviewWindowSnapshot] = []
    private var snapshotIds: Set<UInt32> = []

    /// What the grid shows. Set on activate, preserved across suspend/resume, reset on close.
    private var mode: OverviewMode = .workspaces

    /// Windows mode only: the workspace's AeroSpace-fullscreen window when the grid opened.
    /// On close, fullscreen moves to whichever window of that workspace ended up focused, so
    /// switching windows from the grid keeps the workspace in fullscreen.
    private var fullscreenWindowAtOpen: (windowId: UInt32, noOuterGaps: Bool)?

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

    /// True while the overview is suspended — HUD/dim hidden, window frames restored,
    /// snapshots and anchor preserved so `resume()` can re-establish the same grid.
    /// `isOverviewActive` is false while suspended so the normal layout pass owns
    /// window placement on every monitor (the user is working elsewhere).
    private(set) var isSuspended: Bool = false

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
    func isAnchorMonitor(_ monitor: MonitorInfo) -> Bool {
        guard let corner = anchorMonitorCorner else { return false }
        return monitor.rect.topLeftCorner == corner
    }

    /// True if the named workspace belongs in the grid: in workspaces mode, it passes the
    /// overview's allowlist/excludelist filter; in windows mode, it is the workspace whose
    /// windows are shown. Empty workspaces still return true here — they're filtered at
    /// activation by `selectWorkspaces`, which combines this check with isEffectivelyEmpty.
    func isWorkspaceEligibleForOverview(_ name: String?) -> Bool {
        guard let name else { return false }
        if case .windows(let workspaceName) = mode { return name == workspaceName }
        let cfg = config.overview
        if let allowList = cfg.workspaces { return allowList.contains(name) }
        if !cfg.excludeWorkspaces.isEmpty { return !cfg.excludeWorkspaces.contains(name) }
        return true
    }

    /// Returns the workspace at the grid-adjacent cell in the given direction.
    /// Used by FocusCommand to wrap ctrl+arrow keys to adjacent workspaces while
    /// the overview is open. Always nil in windows mode — its cells are windows, not
    /// workspaces — so callers fall back to their normal in-workspace behavior.
    func adjacentSelectedWorkspace(from name: String, direction: CardinalDirection) -> Workspace? {
        guard mode == .workspaces else { return nil }
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

    /// Open the overview in `newMode`. While any overview is open, this closes it instead,
    /// so both `overview` and `overview --windows` hotkeys act as toggles.
    func activate(mode newMode: OverviewMode) async throws {
        guard !isOverviewActive else {
            try await deactivate(select: nil)
            return
        }
        // Explicit re-activation discards any preserved suspend state — the hotkey
        // means "show me the grid on this monitor now", not "resume the old one".
        isSuspended = false
        snapshots = []
        snapshotIds = []
        mode = newMode
        fullscreenWindowAtOpen = nil
        if case .windows = newMode,
           let window = focus.workspace.rootTilingContainer.mostRecentWindowRecursive,
           window.isFullscreen
        {
            fullscreenWindowAtOpen = (window.windowId, window.noOuterGapsInFullscreen)
        }
        anchorMonitorCorner = focus.workspace.workspaceMonitor.rect.topLeftCorner
        isOverviewActive = true
        try await applyOverviewLayout(initialOpen: true)
    }

    /// Pause the overview: hide HUD + dim, restore window frames, keep snapshot data.
    /// Lets the user visit a non-grid workspace (e.g. a scratchpad) without tearing
    /// down the overview; `resume()` re-establishes the grid on the same monitor.
    /// Safe to call when the overview is closed or already suspended (no-op).
    func suspend() async throws {
        guard isOverviewActive, !isSuspended, !isClosing else { return }
        isSuspended = true
        OverviewHUD.shared.hide()
        OverviewDimPanel.shared.close()
        // Restore each window from its snapshot. Sequential to avoid AX rate-limit
        // issues when multiple windows belong to the same app.
        for snapshot in snapshots {
            try await snapshot.window.setAxFrameBlocking(
                snapshot.frame.topLeftCorner,
                CGSize(width: snapshot.frame.width, height: snapshot.frame.height),
            )
        }
        // Release the layout lock so the upcoming workspace switch (and every monitor
        // in general) lays out normally while the overview is paused.
        isOverviewActive = false
        scheduleCancellableCompleteRefreshSession(.hotkeyBinding)
    }

    /// Resume a suspended overview: re-snapshot current window positions and re-apply
    /// the grid on the original anchor monitor. Safe to call when not suspended (no-op).
    func resume() async throws {
        guard isSuspended, !isClosing else { return }
        isSuspended = false
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

    /// Keep the overview in sync with a focus change on the anchor monitor: move the
    /// highlight when focus lands on a window already in the grid, refresh the grid when
    /// it lands on a new window that belongs in it, and close the overview when focus
    /// leaves what the grid shows. Called from setFocus.
    func syncToFocusChange(_ newFocus: LiveFocus) {
        if let win = newFocus.windowOrNil {
            if isWindowInOverview(win.windowId) {
                if let target = cellTarget(for: newFocus) {
                    OverviewHUD.shared.syncSelection(to: target)
                }
            } else if isWorkspaceEligibleForOverview(win.nodeWorkspace?.name) {
                Task.startUnstructured { @MainActor in try? await self.refreshLayout() }
            } else {
                Task.startUnstructured { @MainActor in try? await self.deactivate(select: nil) }
            }
        } else if case .windows(let workspaceName) = mode, newFocus.workspace.name != workspaceName {
            // Windows mode shows a single workspace: switching to another one closes it.
            Task.startUnstructured { @MainActor in try? await self.deactivate(select: nil) }
        } else {
            Task.startUnstructured { @MainActor in try? await self.refreshLayout() }
        }
    }

    private func applyOverviewLayout(initialOpen: Bool) async throws {
        let selectedWorkspaces = selectWorkspaces()
        guard let anchor = resolveAnchorMonitor(), !selectedWorkspaces.isEmpty else {
            if initialOpen {
                abortOpen()
            } else {
                try await deactivate(select: nil)
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
        let contents = cellContents(of: selectedWorkspaces)
        let existingFrames: [UInt32: Rect] = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.windowId, $0.frame) })
        var newSnapshots: [OverviewWindowSnapshot] = []
        for content in contents {
            for window in content.windows {
                let frame: Rect? = if let existing = existingFrames[window.windowId] {
                    existing
                } else if let layoutRect = window.lastAppliedLayoutPhysicalRect {
                    layoutRect
                } else {
                    try await window.getAxRect(.nonCancellable)
                }
                guard let frame else { continue }
                newSnapshots.append(OverviewWindowSnapshot(window: window, frame: frame, cellTarget: content.target))
            }
        }
        guard !newSnapshots.isEmpty else {
            if initialOpen {
                abortOpen()
            } else {
                try await deactivate(select: nil)
            }
            return
        }

        // A window that left the grid while it was open (e.g. moved to another workspace)
        // would otherwise stay in its old cell. Put it back where it was and hide it if its
        // new workspace isn't on screen; the post-close layout pass handles the rest.
        let newSnapshotIds = Set(newSnapshots.map(\.windowId))
        for snapshot in snapshots where !newSnapshotIds.contains(snapshot.windowId) {
            guard let workspace = snapshot.window.nodeWorkspace, !workspace.isVisible else { continue }
            try await snapshot.window.setAxFrameBlocking(
                snapshot.frame.topLeftCorner,
                CGSize(width: snapshot.frame.width, height: snapshot.frame.height),
            )
            try await snapshot.window.hideInCorner(.bottomRightCorner)
        }

        let monitorRect = anchor.visibleRect
        let (overviewCells, columns) = computeOverviewCells(for: contents.map(\.target), monitorRect: monitorRect)
        let cellByTarget: [OverviewCellTarget: OverviewCell] = Dictionary(uniqueKeysWithValues: overviewCells.map { ($0.target, $0) })

        // Move windows into their cell slots (blocking so the HUD doesn't reveal before
        // the move). For tiling windows, use the freshly-computed lastAppliedLayoutPhysicalRect
        // (from the dry-run pass above) for cell positioning so existing windows reflow
        // when neighbors are added or removed. snapshot.frame is reserved for restore.
        // Fullscreen windows fill their cell so the toggle is visible mid-overview, and so
        // does every window in windows mode, where each window has a cell to itself.
        for snapshot in newSnapshots {
            guard let cell = cellByTarget[snapshot.cellTarget] else { continue }
            let targetFrame: Rect
            if snapshot.window.isFullscreen || mode != .workspaces {
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
        self.snapshotIds = newSnapshotIds

        let hudCells = try await buildHudCells(for: overviewCells, monitorRect: monitorRect)
        // The awaits above are suspension points: the overview may have been closed in
        // the meantime (e.g. by a focus change). Don't bring the HUD back in that case.
        guard isOverviewActive, !isClosing else { return }

        let dimOpacity = config.overview.dimBackground ? config.overview.dimOpacity : 0.0
        OverviewDimPanel.shared.show(monitorFrame: monitorRect, opacity: dimOpacity)

        OverviewHUD.shared.show(
            monitorFrame: monitorRect,
            cells: hudCells,
            columnCount: columns,
            initialSelection: cellTarget(for: focus),
            onCommit: { [weak self] target in
                guard let self else { return }
                Task.startUnstructured { @MainActor in try? await self.deactivate(select: target) }
            },
            onCancel: { [weak self] in
                guard let self else { return }
                Task.startUnstructured { @MainActor in try? await self.deactivate(select: nil) }
            },
        )
    }

    /// Close the overview, restore every window, and focus `target` when given: the
    /// selected workspace, or the selected window in windows mode.
    func deactivate(select target: OverviewCellTarget?) async throws {
        guard !isClosing else { return }
        isClosing = true
        defer {
            isOverviewActive = false
            isClosing = false
            isSuspended = false
            mode = .workspaces
            fullscreenWindowAtOpen = nil
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

        // focusWorkspace / focusWindow update _focus (setFocus skips the overview hook while
        // isClosing). The explicit nativeFocus drives NSApp.activate at the macOS level —
        // without it, the post-deactivate refresh's updateFocusCache(getNativeFocusedWindow)
        // would observe whichever app was macOS-focused before the overview opened
        // and snap _focus back, undoing the user's chosen target.
        switch target {
            case .workspace(let name):
                let workspace = Workspace.get(byName: name)
                _ = workspace.focusWorkspace()
                if let mru = workspace.mostRecentWindowRecursive as? MacWindow {
                    mru.nativeFocus()
                }
            case .window(let windowId):
                if let window = Window.get(byId: windowId) {
                    _ = window.focusWindow()
                    window.nativeFocus()
                }
            case nil:
                break
        }
        moveFullscreenToFocusedWindow()
    }

    /// Windows mode: close the grid on the highlighted window, as Enter does. Returns false,
    /// leaving the overview alone, when no windows-mode overview is open.
    func closeWindowsModeOnSelection() async throws -> Bool {
        guard isOverviewActive, !isClosing, case .windows = mode else { return false }
        try await deactivate(select: OverviewHUD.shared.selectedTarget)
        return true
    }

    /// Windows mode: when the workspace was in AeroSpace fullscreen as the grid opened and a
    /// different tiling window of it is focused now (selected with Enter, clicked, or reached
    /// with a focus command), make that window the fullscreen one. Plain AeroSpace focus
    /// semantics would instead drop the workspace back to its tiled layout.
    private func moveFullscreenToFocusedWindow() {
        guard case .windows(let workspaceName) = mode,
              let original = fullscreenWindowAtOpen,
              let focused = focus.windowOrNil,
              focused.windowId != original.windowId,
              !focused.isFloating,
              focused.nodeWorkspace?.name == workspaceName
        else { return }
        Window.get(byId: original.windowId)?.isFullscreen = false
        focused.isFullscreen = true
        focused.noOuterGapsInFullscreen = original.noOuterGaps
    }

    /// Workspaces currently displayed in the overview grid. Empty array when the
    /// overview is not active, and in windows mode (its cells are windows), so
    /// `workspace next/prev` iterates the same list the user sees while the
    /// workspaces overview is open and keeps its normal order otherwise.
    func displayedWorkspaces() -> [Workspace] {
        isOverviewActive && mode == .workspaces ? selectWorkspaces() : []
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

    /// One grid cell's content: what selecting the cell focuses, and the windows drawn in it.
    private struct CellContent {
        let target: OverviewCellTarget
        let windows: [MacWindow]
    }

    /// Workspaces mode: one cell per workspace holding all of its windows.
    /// Windows mode: one cell per window, in `overviewGridWindows` order.
    private func cellContents(of workspaces: [Workspace]) -> [CellContent] {
        switch mode {
            case .workspaces:
                workspaces.map { workspace in
                    CellContent(
                        target: .workspace(workspace.name),
                        windows: workspace.allLeafWindowsRecursive.compactMap { $0 as? MacWindow },
                    )
                }
            case .windows:
                workspaces
                    .flatMap { $0.overviewGridWindows.compactMap { $0 as? MacWindow } }
                    .map { CellContent(target: .window($0.windowId), windows: [$0]) }
        }
    }

    /// The cell holding `liveFocus`: its workspace's cell, or in windows mode its window's.
    private func cellTarget(for liveFocus: LiveFocus) -> OverviewCellTarget? {
        switch mode {
            case .workspaces: .workspace(liveFocus.workspace.name)
            case .windows: liveFocus.windowOrNil.map { .window($0.windowId) }
        }
    }

    /// Reset after an initial open (or resume) that found nothing to show.
    private func abortOpen() {
        isOverviewActive = false
        anchorMonitorCorner = nil
        mode = .workspaces
        fullscreenWindowAtOpen = nil
    }

    private func resolveAnchorMonitor() -> MonitorInfo? {
        guard let corner = anchorMonitorCorner else { return nil }
        return monitorInfos.first(where: { $0.rect.topLeftCorner == corner })
    }

    struct OverviewCell {
        let target: OverviewCellTarget
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

    private func computeOverviewCells(for targets: [OverviewCellTarget], monitorRect: Rect) -> ([OverviewCell], Int) {
        let count = targets.count
        guard count > 0 else { return ([], 1) }

        let columns = resolveColumns(forCount: count)
        let rows = Int(ceil(Double(count) / Double(columns)))

        let padding: CGFloat = 14
        let cellW = (monitorRect.width - padding * CGFloat(columns + 1)) / CGFloat(columns)
        let cellH = (monitorRect.height - padding * CGFloat(rows + 1)) / CGFloat(rows)

        let cells = targets.enumerated().map { index, target in
            let col = index % columns
            let row = index / columns
            let x = monitorRect.topLeftX + padding + CGFloat(col) * (cellW + padding)
            let y = monitorRect.topLeftY + padding + CGFloat(row) * (cellH + padding)
            return OverviewCell(
                target: target,
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

    private func buildHudCells(for overviewCells: [OverviewCell], monitorRect: Rect) async throws -> [OverviewCellInfo] {
        let snapshotsByTarget: [OverviewCellTarget: [OverviewWindowSnapshot]] = Dictionary(grouping: snapshots, by: \.cellTarget)

        var result: [OverviewCellInfo] = []
        for cell in overviewCells {
            let relX = cell.frame.topLeftX - monitorRect.topLeftX
            let relY = cell.frame.topLeftY - monitorRect.topLeftY
            let hudFrame = CGRect(x: relX, y: relY, width: cell.frame.width, height: cell.frame.height)
            let windows = (snapshotsByTarget[cell.target] ?? []).map(\.window)

            let label: String
            switch cell.target {
                case .workspace(let workspaceName):
                    let appNames = windows
                        .map { $0.app.name?.takeIf { !$0.isEmpty } }
                        .filterNotNil()
                        .toOrderedSet()
                        .elements
                    label = formatCellLabel(workspaceName: workspaceName, appNames: appNames, style: config.overview.cellLabel)
                case .window:
                    let title = try await windows.first?.getTitle(.nonCancellable) ?? ""
                    label = overviewWindowCellLabel(appName: windows.first?.app.name, title: title)
            }
            result.append(OverviewCellInfo(target: cell.target, hudFrame: hudFrame, label: label))
        }
        return result
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

/// Label for a windows-mode cell: "App: Title". Either part is dropped when empty, and the
/// title is dropped when it just repeats the app name.
func overviewWindowCellLabel(appName: String?, title: String) -> String {
    [appName, title]
        .filterNotNil()
        .filter { !$0.isEmpty }
        .toOrderedSet()
        .elements
        .joined(separator: ": ")
}

extension Workspace {
    /// Windows `overview --windows` shows for this workspace, in grid order: tiling windows
    /// in tree (dfs) order, then floating windows. Leaves out windows macOS owns —
    /// native-fullscreen and hidden-app windows — which can't be moved into a cell.
    @MainActor var overviewGridWindows: [Window] {
        rootTilingContainer.allLeafWindowsRecursive + floatingWindowsContainer.children.filterIsInstance(of: Window.self)
    }
}
