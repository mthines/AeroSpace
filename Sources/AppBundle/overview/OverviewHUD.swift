import AppKit
import Carbon.HIToolbox
import SwiftUI
import Common

@MainActor final class OverviewHUD: NSPanelHud {
    static let shared = OverviewHUD()

    private var hostingView: NSHostingView<OverviewHUDView>?
    private var eventMonitor: Any?
    private var columnCount: Int = 1
    private var onCommit: ((OverviewCellTarget) -> Void)?
    private var onCancel: (() -> Void)?
    private var cells: [OverviewCellInfo] = []

    private let selectionState = SelectionState()
    private var selectedIndex: Int { selectionState.index }

    override private init() {
        super.init()
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        // Click-through: cells are visual-only. Clicks pass to the windows beneath so
        // macOS click-to-focus works normally; AeroSpace's setFocus hook then calls
        // syncSelection(to:) to keep the highlight in sync.
        self.ignoresMouseEvents = true
    }

    /// `initialSelection` is the cell highlighted when the HUD appears — the cell holding
    /// the current focus. Falls back to the first cell when nil or not in `cells`.
    func show(
        monitorFrame: Rect,
        cells: [OverviewCellInfo],
        columnCount: Int,
        initialSelection: OverviewCellTarget?,
        onCommit: @escaping @MainActor (OverviewCellTarget) -> Void,
        onCancel: @escaping @MainActor () -> Void,
    ) {
        self.cells = cells
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.columnCount = max(1, columnCount)

        let initialIdx = cells.firstIndex(where: { $0.target == initialSelection }) ?? 0
        self.selectionState.index = initialIdx

        let view = OverviewHUDView(cells: cells, selection: selectionState)
        if let existing = hostingView {
            existing.rootView = view
            existing.frame = NSRect(origin: .zero, size: NSSize(width: monitorFrame.width, height: monitorFrame.height))
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: NSSize(width: monitorFrame.width, height: monitorFrame.height))
            contentView?.addSubview(hosting)
            self.hostingView = hosting
        }

        self.setFrame(toAppKitFrame(monitorFrame), display: false)

        // Only steal activation on the *initial* present. Subsequent show() calls come
        // from refreshLayout (e.g. after macOS fires didActivateApplicationNotification
        // for a clicked target app) — re-activating AeroSpace would yank focus back.
        if !self.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            self.makeKeyAndOrderFront(nil)
        } else {
            self.orderFront(nil)
        }

        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyEvent(event)
            }
        }
    }

    func hide() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        cells = []
        onCommit = nil
        onCancel = nil
        close()
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard !cells.isEmpty else { return event }

        switch Int(event.keyCode) {
            case kVK_LeftArrow:                  move(delta: -1); return nil
            case kVK_RightArrow:                 move(delta: 1); return nil
            case kVK_DownArrow:                  move(delta: columnCount); return nil
            case kVK_UpArrow:                    move(delta: -columnCount); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter: selectCurrent(); return nil
            case kVK_Escape:                     onCancel?(); return nil
            default:
                switch event.charactersIgnoringModifiers {
                    case "h": move(delta: -1); return nil
                    case "l": move(delta: 1); return nil
                    case "j": move(delta: columnCount); return nil
                    case "k": move(delta: -columnCount); return nil
                    default: return event
                }
        }
    }

    private func move(delta: Int) {
        let count = cells.count
        guard count > 0 else { return }
        selectionState.index = (selectionState.index + delta + count) % count
    }

    private func selectCurrent() {
        guard let cell = cells.getOrNil(atIndex: selectedIndex) else { return }
        onCommit?(cell.target)
    }

    /// Move the highlight to the cell for `target`. Called from setFocus while the overview
    /// is open so external focus changes (workspace switches, focus commands, clicks) keep
    /// the HUD selection in sync. No-op when no cell matches.
    @MainActor func syncSelection(to target: OverviewCellTarget) {
        guard let idx = cells.firstIndex(where: { $0.target == target }) else { return }
        if idx == selectionState.index { return }
        selectionState.index = idx
    }
}

@MainActor final class SelectionState: ObservableObject {
    @Published var index: Int = 0
}
