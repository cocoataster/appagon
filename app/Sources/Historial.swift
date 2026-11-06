import Foundation

// Conversaciones y respuestas guardadas, en el propio móvil (UserDefaults, en JSON).
// El historial solo se muestra: cada pregunta se sigue respondiendo por separado, como en la evaluación.

struct Mensaje: Codable, Identifiable, Equatable {
    var id = UUID()
    var fecha = Date()
    var pregunta: String
    var respuesta: String
    var calculos: [String] = []
    var fuentes: [String] = []
    var correccion: [String] = []   // «Dato calculado»: se guarda con la respuesta para no perder la red de seguridad
    var medidas = ""
    var guardado = false
}

struct Conversacion: Codable, Identifiable, Equatable {
    var id = UUID()
    var mensajes: [Mensaje] = []
    var titulo: String { mensajes.first?.pregunta ?? "Conversación nueva" }
    var fecha: Date { mensajes.last?.fecha ?? Date() }
}

@MainActor
final class Historial: ObservableObject {
    @Published private(set) var conversaciones: [Conversacion] = []   // la más reciente primero
    @Published private(set) var actual = UUID()   // la que se ve en «Asistente»; se crea al llegar su primera respuesta
    @Published var respondiendo: UUID?            // la que espera respuesta del asistente

    private let clave = "historial.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: clave),
           let c = try? JSONDecoder().decode([Conversacion].self, from: d) {
            conversaciones = c
        }
        if let ultima = conversaciones.first { actual = ultima.id }
    }

    var mensajesActuales: [Mensaje] { conversaciones.first { $0.id == actual }?.mensajes ?? [] }

    var guardados: [Mensaje] {
        conversaciones.flatMap(\.mensajes).filter(\.guardado).sorted { $0.fecha > $1.fecha }
    }

    func nueva() { actual = UUID() }
    func abrir(_ id: UUID) { actual = id }

    func agregar(_ m: Mensaje, a id: UUID) {
        if let i = conversaciones.firstIndex(where: { $0.id == id }) {
            var c = conversaciones.remove(at: i)
            c.mensajes.append(m)
            conversaciones.insert(c, at: 0)
        } else {
            conversaciones.insert(Conversacion(id: id, mensajes: [m]), at: 0)
        }
        guardar()
    }

    func alternarGuardado(_ mensaje: UUID) {
        for i in conversaciones.indices {
            if let j = conversaciones[i].mensajes.firstIndex(where: { $0.id == mensaje }) {
                conversaciones[i].mensajes[j].guardado.toggle()
                guardar()
                return
            }
        }
    }

    func borrar(_ id: UUID) {
        conversaciones.removeAll { $0.id == id }
        if actual == id { nueva() }
        guardar()
    }

    func borrarTodo() {
        conversaciones = []
        nueva()
        guardar()
    }

    private func guardar() {
        if let d = try? JSONEncoder().encode(conversaciones) {
            UserDefaults.standard.set(d, forKey: clave)
        }
    }
}
