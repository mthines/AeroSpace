import AppKit
import Common

/// Guards the layout engine from re-flowing windows while the overview is active.
/// When true, layoutRecursive() returns immediately without touching windows.
/// Analogous to currentlyManipulatedWithMouseWindowId in mouse.swift.
@MainActor var isOverviewActive: Bool = false
