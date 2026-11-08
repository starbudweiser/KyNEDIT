import SwiftUI

/// Jetons Socle (thème sombre) utilisés par l'interface.
enum Socle {
    static let bg = Color(hex: 0x1E1E1E), surface = Color(hex: 0x222222), sunken = Color(hex: 0x181818)
    static let control = Color(hex: 0x333333), border = Color(hex: 0x333333)
    static let textStrong = Color.white, text = Color(hex: 0xDDDDDD), muted = Color(hex: 0xAAAAAA), subtle = Color(hex: 0x8F8F8F)
    static let accentText = Color(hex: 0x38BDF8), action = Color(hex: 0xFBBF24), onAction = Color(hex: 0x1A1A1A)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
