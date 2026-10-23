import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The grouped backgrounds the statistics are drawn on — the iPhone's system ones, and the Mac's
/// nearest: a window's background and the controls' on it.
extension Color {
    #if canImport(UIKit)
    static let grouped = Color(UIColor.systemGroupedBackground)
    static let groupedSecondary = Color(UIColor.secondarySystemGroupedBackground)
    static let groupedTertiary = Color(UIColor.tertiarySystemGroupedBackground)
    #else
    static let grouped = Color(NSColor.windowBackgroundColor)
    static let groupedSecondary = Color(NSColor.controlBackgroundColor)
    static let groupedTertiary = Color(NSColor.underPageBackgroundColor)
    #endif
}
