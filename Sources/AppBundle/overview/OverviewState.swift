import AppKit
import Common

/// Guards the layout engine from re-flowing windows while the overview is active.
/// When true, layoutRecursive() returns immediately without touching windows.
/// Analogous to currentlyManipulatedWithMouseWindowId in mouse.swift.
@MainActor var isOverviewActive: Bool = false

/// What the overview grid shows.
enum OverviewMode: Equatable {
    /// One cell per eligible workspace on the anchor monitor (`overview`).
    case workspaces
    /// One cell per window of a single workspace (`overview --windows`).
    case windows(workspaceName: String)
}

/// What a grid cell stands for — and therefore what selecting it focuses.
enum OverviewCellTarget: Hashable {
    case workspace(String)
    case window(UInt32)
}
