import SwiftUI

/// Visual constants — 安心加速器 dark theme.
enum Theme {
    static let accent = Color(red: 0.22, green: 0.62, blue: 1.00)
    static let accentSoft = accent.opacity(0.18)
    static let background = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let surface = Color(red: 0.10, green: 0.12, blue: 0.17)
    static let surfaceAlt = Color(red: 0.14, green: 0.16, blue: 0.22)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)

    static func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(surface)
    }
}

/// Byte formatting helper (libbox FormatBytes parity).
enum ByteFormat {
    static func format(_ bytes: Int64) -> String {
        let units: [String] = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.2f %@", value, units[unit])
    }
}
