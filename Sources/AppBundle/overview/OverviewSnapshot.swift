import AppKit
import Common

struct OverviewWindowSnapshot {
    let window: MacWindow
    /// Frame captured before the overview moved this window, in screen coordinates.
    let frame: Rect
    /// The grid cell this window is drawn in.
    let cellTarget: OverviewCellTarget

    var windowId: UInt32 { window.windowId }
}
