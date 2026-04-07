import SwiftUI

struct ThemeOption: Identifiable {
    let id: String
    let titleKey: String
    let color: Color
}

enum ThemeStyle {
    static let options: [ThemeOption] = [
        ThemeOption(id: "claude", titleKey: "theme_claude", color: Color(red: 0.85, green: 0.47, blue: 0.34)),
        ThemeOption(id: "green", titleKey: "theme_green", color: Color(red: 0.3, green: 0.85, blue: 0.4)),
        ThemeOption(id: "blue", titleKey: "theme_blue", color: Color(red: 0.4, green: 0.7, blue: 1.0)),
        ThemeOption(id: "teal", titleKey: "theme_teal", color: Color(red: 0.35, green: 0.82, blue: 0.78)),
    ]

    static func color(id: String) -> Color {
        options.first(where: { $0.id == id })?.color ?? options[1].color
    }
}
