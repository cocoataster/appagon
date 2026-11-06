import Foundation
import SwiftUI
import UIKit

// Une las piezas: pipeline (reglas, calculadoras, búsqueda) + los dos modelos de llama.cpp.
// Todo lo pesado ocurre en el actor Motor, fuera del hilo de la interfaz.

enum Recursos {
    // Dentro de la app solo va lo ligero (~5 MB): índice de las guías, reglas y casos de prueba.
    // Los modelos se descargan la primera vez (Modelos.swift).
    static var carpeta: URL { Bundle.main.resourceURL!.appendingPathComponent("Contenido") }
    static var datos: URL { carpeta.appendingPathComponent("datos") }
}

actor Motor {
    let pipeline: Pipeline
    private let generador: LlamaGenerador
    private let vectores: LlamaVectores

    init(generador rutaGenerador: URL, vectores rutaVectores: URL) throws {
        pipeline = try Pipeline(carpeta: Recursos.datos)
        vectores = try LlamaVectores(ruta: rutaVectores.path)
        generador = try LlamaGenerador(ruta: rutaGenerador.path)
    }

    func preparar(_ q: String) throws -> Preparado {
        let v = try vectores.vector(pipeline.textoConsulta(q))
        return pipeline.preparar(q, trozos: pipeline.recuperar(v))
    }

    func responder(_ preparado: Preparado, alEscribir: @escaping (String) -> Void) throws -> Medidas {
        try generador.generar(sistema: pipeline.datos.system_rag, usuario: preparado.usuario, alEscribir: alEscribir)
    }

    func limpiar(_ t: String) -> String { pipeline.limpiar(t) }

    func datosQueFaltan(_ respuesta: String, _ calculos: [String]) -> [String] {
        pipeline.datosQueFaltan(respuesta: respuesta, calculos: calculos)
    }

    /// Compara la app con Python: reglas, calculadoras y sinónimos (todas las preguntas) y búsqueda (las 40 primeras).
    func autocomprobar() throws -> String {
        let casos = try JSONDecoder().decode([Caso].self, from: Data(contentsOf: Recursos.datos.appendingPathComponent("casos.json")))
        var texto = Comprobacion.puras(pipeline, casos).texto
        texto += "\n\n" + Comprobacion.redSeguridad(pipeline).texto
        let conBusqueda = casos.filter { $0.top != nil }.prefix(40)
        if !conBusqueda.isEmpty {
            var coinciden = 0, total = 0, iguales = 0
            for c in conBusqueda {
                let mios = Set(pipeline.recuperar(try vectores.vector(pipeline.textoConsulta(c.q))))
                let suyos = Set(c.top ?? [])
                coinciden += mios.intersection(suyos).count
                total += suyos.count
                if mios == suyos { iguales += 1 }
            }
            texto += "\n\nBúsqueda en las guías (\(conBusqueda.count) preguntas): \(coinciden) de \(total) trozos iguales que con Ollama"
            texto += " (\(iguales) preguntas con los 6 trozos idénticos). Pequeñas diferencias son normales: el vector se calcula con llama.cpp y no con Ollama."
        }
        return texto
    }
}

@MainActor
final class Asistente: ObservableObject {
    enum Estado: Equatable {
        case cargando, listo, buscando, leyendo(desde: Date), escribiendo, error(String)
        case faltanModelos, descargando(texto: String, fraccion: Double), comprobando(String)
    }

    @Published var estado: Estado = .cargando
    @Published var pregunta = ""
    @Published var respuesta = ""
    @Published var calculos: [String] = []
    @Published var fuentes: [String] = []
    @Published var medidas = ""
    @Published var correccion: [String] = []   // datos calculados que el modelo no recogió bien
    @Published var comprobacion: String?
    @Published var errorDescarga: String?
    @Published var pendiente = ""            // tamaño que falta por descargar, en texto

    private var motor: Motor?

    func cargar() async {
        guard motor == nil else { return }
        let lista = Modelos.lista()
        guard !lista.isEmpty else { estado = .error(ErrorDescarga.sinLista.localizedDescription); return }
        let faltan = Modelos.pendientes()
        if !faltan.isEmpty {
            pendiente = Modelos.texto(faltan.reduce(0) { $0 + $1.bytes })
            estado = .faltanModelos
            return
        }
        guard let g = lista.first(where: { $0.id == "generador" }).flatMap(Modelos.ruta),
              let v = lista.first(where: { $0.id == "vectores" }).flatMap(Modelos.ruta) else {
            estado = .error(ErrorDescarga.sinLista.localizedDescription); return
        }
        estado = .cargando
        do {
            let m = try await Task.detached(priority: .userInitiated) { try Motor(generador: g, vectores: v) }.value
            motor = m
            estado = .listo
        } catch {
            estado = .error(error.localizedDescription)
        }
    }

    /// Descarga los modelos que falten, uno detrás de otro, con progreso; si se corta, «Reintentar» sigue donde iba.
    private var reanudar: [String: Data] = [:]

    func descargar() async {
        errorDescarga = nil
        UIApplication.shared.isIdleTimerDisabled = true   // que la pantalla no se apague a mitad de descarga
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let faltan = Modelos.pendientes()
        let total = faltan.reduce(0) { $0 + $1.bytes }
        guard Modelos.espacioLibre() > total + 500_000_000 else {
            errorDescarga = ErrorDescarga.espacio(total + 500_000_000 - Modelos.espacioLibre()).localizedDescription
            estado = .faltanModelos
            return
        }
        var hechos: Int64 = 0
        for (i, m) in faltan.enumerated() {
            let cabecera = "Descargando \(i + 1) de \(faltan.count): \(m.nombre)"
            estado = .descargando(texto: cabecera, fraccion: Double(hechos) / Double(max(total, 1)))
            let base = hechos
            let d = Descarga { escritos, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let f = Double(base + escritos) / Double(max(total, 1))
                        self.estado = .descargando(texto: "\(cabecera)\n\(Modelos.texto(base + escritos)) de \(Modelos.texto(total))", fraccion: f)
                    }
                }
            }
            do {
                guard let url = URL(string: m.url) else { throw ErrorDescarga.sinLista }
                let tmp = try await d.ejecutar(url, reanudar: reanudar[m.id])
                reanudar[m.id] = nil
                estado = .comprobando("Comprobando que \(m.nombre) ha llegado entero…")
                try await Task.detached(priority: .userInitiated) { try Modelos.instalar(m, desde: tmp) }.value
                hechos += m.bytes
            } catch {
                if let r = d.datosReanudar { reanudar[m.id] = r }
                errorDescarga = error.localizedDescription
                pendiente = Modelos.texto(Modelos.pendientes().reduce(0) { $0 + $1.bytes })
                estado = .faltanModelos
                return
            }
        }
        await cargar()
    }

    /// Borra los modelos descargados (para volver a probar la descarga).
    func borrarModelos() async {
        guard !ocupado || estado == .faltanModelos else { return }
        motor = nil
        Modelos.borrar()
        await cargar()
    }

    var ocupado: Bool {
        switch estado {
        case .listo, .error: return false
        default: return true
        }
    }

    /// Responde y devuelve el mensaje terminado (ya limpio y con la red de seguridad) para guardarlo en el historial.
    @discardableResult
    func preguntar(_ q: String) async -> Mensaje? {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let motor, !q.isEmpty, !ocupado else { return nil }
        pregunta = q
        respuesta = ""
        calculos = []
        fuentes = []
        medidas = ""
        correccion = []
        estado = .buscando
        do {
            let t0 = Date()
            let prep = try await motor.preparar(q)
            let tBusqueda = Date().timeIntervalSince(t0)
            calculos = prep.calculos
            var vistas: [String] = []
            for t in prep.trozos where !vistas.contains(t.fuente) { vistas.append(t.fuente) }
            fuentes = vistas
            estado = .leyendo(desde: Date())
            let m = try await motor.responder(prep) { trozo in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if case .leyendo = self.estado { self.estado = .escribiendo }
                        self.respuesta += trozo
                    }
                }
            }
            // espera a que lleguen los últimos trozos encolados en el hilo principal
            await Task.yield()
            respuesta = await motor.limpiar(respuesta)
            correccion = await motor.datosQueFaltan(respuesta, prep.calculos)   // red de seguridad: lo exacto, en código
            medidas = String(format: "Búsqueda %.1f s · 1.ª palabra %.1f s · %.0f tokens/s · %ld tokens leídos (%ld reutilizados) · %ld escritos",
                             tBusqueda, m.primeraPalabra, m.tokPorSeg, m.tokensEntrada, m.tokensReutilizados, m.tokensSalida)
                .replacingOccurrences(of: ".", with: ",")
                .replacingOccurrences(of: "1,ª", with: "1.ª")
            estado = .listo
            return Mensaje(pregunta: q, respuesta: respuesta, calculos: calculos, fuentes: fuentes,
                           correccion: correccion, medidas: medidas)
        } catch {
            estado = .error(error.localizedDescription)
            return nil
        }
    }

    func autocomprobar() async {
        guard let motor, !ocupado else { return }
        estado = .buscando
        do {
            comprobacion = try await motor.autocomprobar()
        } catch {
            comprobacion = "Error: \(error.localizedDescription)"
        }
        estado = .listo
    }
}
