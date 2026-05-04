import AppKit
import Common

/// Full-monitor dim overlay that sits behind the repositioned windows.
/// Window level = NSWindowLevel.normal - 1, so regular app windows render above it.
@MainActor final class OverviewDimPanel: NSPanelHud {
    static let shared = OverviewDimPanel()

    override private init() {
        super.init()
        // One level below normal app windows: repositioned windows render above the dim panel
        self.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        self.backgroundColor = .black
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
    }

    /// Show the dim panel covering `monitorFrame`.
    /// `monitorFrame` is in AeroSpace coordinates (top-left origin, Y-down).
    func show(monitorFrame: Rect, opacity: Double) {
        let appKitFrame = toAppKitFrame(monitorFrame)
        self.setFrame(appKitFrame, display: false)
        self.alphaValue = CGFloat(opacity)
        self.orderFrontRegardless()
    }
}

/// Convert an AeroSpace `Rect` (top-left origin, Y-down) to an AppKit `NSRect`
/// (bottom-left origin, Y-up) for use with NSWindow.setFrame.
/// Uses the main screen height as the flip axis (same convention as NSScreen.rect).
@MainActor func toAppKitFrame(_ rect: Rect) -> NSRect {
    let screenH = mainMonitor.height
    // AppKit minY = screenH - (aerospaceTopLeftY + height)
    let appKitY = screenH - rect.topLeftY - rect.height
    return NSRect(x: rect.topLeftX, y: appKitY, width: rect.width, height: rect.height)
}
