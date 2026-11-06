import SwiftUI

// Lo único que se toma de las diapositivas es el ámbar como color de acento.
// El resto es iOS tal cual: fondo negro puro (en pantallas OLED los píxeles negros no gastan), sin degradados ni animaciones.

enum Tema {
    static let ambar = Color(red: 0xF2 / 255, green: 0xA3 / 255, blue: 0x3A / 255)
}
