import SwiftUI

// Space Lens tokens. They extend `Theme` and belong with it; they live in this file only because
// Theme.swift is shared with modules being built in parallel. Fold them into Theme.swift when merging.

extension Theme {
    /// Segment colors for the space map, one per top-level folder in turn. Bright, similar lightness,
    /// and distinct from each other on the indigo backdrop.
    static let spaceMapPalette: [Color] = [
        Color(hex: 0x7DF5C8),  // mint (accent)
        Color(hex: 0x62BFFF),  // sky
        Color(hex: 0xB3A6FF),  // lavender
        Color(hex: 0xFF8FAB),  // rose
        Color(hex: 0xFFC56E),  // amber
        Color(hex: 0x55E3D2),  // aqua
        Color(hex: 0xFFB894),  // coral
        Color(hex: 0x9BE68F),  // leaf
    ]
    /// "Other" aggregates and unreadable folders in the space map.
    static let spaceMapMuted = Color(hex: 0xBFC8D1)
    /// The map's center disc.
    static let spaceMapCenter = Color(hex: 0x0F1638, opacity: 0.6)
}
