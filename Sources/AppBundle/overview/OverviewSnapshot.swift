import AppKit
import Common

struct OverviewWindowSnapshot {
    let window: MacWindow
    /// Frame captured before the overview moved this window, in screen coordinates.
    let frame: Rect
    let workspaceName: String

    var windowId: UInt32 { window.windowId }
}
