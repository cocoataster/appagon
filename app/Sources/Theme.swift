import SwiftUI

// Soft, calming colors: the app is opened at a stressful moment.
// Everything else is stock iOS: pure black background (black pixels use no power on OLED), no gradients and almost no animation.

enum Theme {
    static let accent = Color(red: 0x4F / 255, green: 0xA8 / 255, blue: 0x9E / 255)       // teal
    static let online = Color(red: 0x5A / 255, green: 0xA9 / 255, blue: 0xE6 / 255)      // blue
    static let offline = Color(red: 0xB3 / 255, green: 0xA1 / 255, blue: 0xE0 / 255)  // lilac: no alarm, the app works the same
}
