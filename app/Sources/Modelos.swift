import Foundation
import CryptoKit

// Los modelos (2,4 GB) no van dentro de la app: se descargan la primera vez, con Wi-Fi y antes de un apagón.
// Qué descargar, de dónde, cuánto ocupa y su huella SHA-256 está en Contenido/datos/modelos.json
// (lo genera app/exportar_datos.py a partir de los archivos de app/Modelos).

struct ModeloRemoto: Codable, Identifiable {
    let id: String        // "generador" o "vectores"
    let nombre: String    // texto para la pantalla
    let archivo: String
    let url: String
    let bytes: Int64
    let sha256: String
}

enum ErrorDescarga: LocalizedError {
    case sinLista, espacio(Int64), http(Int), huella(String)

    var errorDescription: String? {
        switch self {
        case .sinLista: return "Falta la lista de modelos (modelos.json)."
        case .espacio(let falta): return "No hay espacio suficiente: libera \(Modelos.texto(falta)) e inténtalo de nuevo."
        case .http(let c): return "El servidor respondió con el código \(c). Comprueba la conexión e inténtalo de nuevo."
        case .huella(let n): return "El archivo de \(n) ha llegado dañado. Vuelve a descargarlo."
        }
    }
}

enum Modelos {
    static func lista() -> [ModeloRemoto] {
        let u = Recursos.datos.appendingPathComponent("modelos.json")
        guard let d = try? Data(contentsOf: u) else { return [] }
        return (try? JSONDecoder().decode([ModeloRemoto].self, from: d)) ?? []
    }

    /// Application Support/Modelos, fuera de la copia de iCloud (son 2,4 GB que se pueden volver a descargar).
    static var carpeta: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var u = base.appendingPathComponent("Modelos", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return u
    }

    private static func marca(_ m: ModeloRemoto) -> URL { carpeta.appendingPathComponent(m.archivo + ".ok") }

    /// Dónde está el modelo: 1) descargado y comprobado; 2) solo al lanzar desde Xcode, la carpeta app/Modelos del Mac.
    static func ruta(_ m: ModeloRemoto) -> URL? {
        let fm = FileManager.default
        let d = carpeta.appendingPathComponent(m.archivo)
        if fm.fileExists(atPath: d.path) && fm.fileExists(atPath: marca(m).path) { return d }
        if let dev = ProcessInfo.processInfo.environment["APAGON_MODELOS"] {
            let p = URL(fileURLWithPath: dev).appendingPathComponent(m.archivo)
            if fm.isReadableFile(atPath: p.path) { return p }
        }
        return nil
    }

    static func pendientes() -> [ModeloRemoto] { lista().filter { ruta($0) == nil } }

    static func espacioLibre() -> Int64 {
        let v = try? carpeta.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }

    static func texto(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 8 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Mueve el archivo descargado a su sitio, comprueba la huella y deja la marca de «comprobado».
    static func instalar(_ m: ModeloRemoto, desde temporal: URL) throws {
        let destino = carpeta.appendingPathComponent(m.archivo)
        try? FileManager.default.removeItem(at: destino)
        try FileManager.default.moveItem(at: temporal, to: destino)
        guard try sha256(destino) == m.sha256 else {
            try? FileManager.default.removeItem(at: destino)
            throw ErrorDescarga.huella(m.nombre)
        }
        try Data().write(to: marca(m))
    }

    /// Para probar la descarga otra vez (menú de la app).
    static func borrar() {
        for m in lista() {
            try? FileManager.default.removeItem(at: carpeta.appendingPathComponent(m.archivo))
            try? FileManager.default.removeItem(at: marca(m))
        }
    }
}

/// Una descarga con progreso y posibilidad de reanudar si se corta.
final class Descarga: NSObject, URLSessionDownloadDelegate {
    private var continuacion: CheckedContinuation<URL, Error>?
    private let alProgresar: (Int64, Int64) -> Void
    private var ultimoAviso = Date.distantPast
    private(set) var datosReanudar: Data?
    private lazy var sesion = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(alProgresar: @escaping (Int64, Int64) -> Void) {
        self.alProgresar = alProgresar
    }

    /// Devuelve la ruta de un archivo temporal propio con lo descargado.
    func ejecutar(_ url: URL, reanudar: Data? = nil) async throws -> URL {
        defer { sesion.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            continuacion = c
            let tarea = reanudar.map { sesion.downloadTask(withResumeData: $0) } ?? sesion.downloadTask(with: url)
            tarea.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard Date().timeIntervalSince(ultimoAviso) > 0.25 else { return }
        ultimoAviso = Date()
        alProgresar(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let r = downloadTask.response as? HTTPURLResponse, !(200...299).contains(r.statusCode) {
            continuacion?.resume(throwing: ErrorDescarga.http(r.statusCode))
            continuacion = nil
            return
        }
        // el archivo temporal se borra al salir de este método: hay que moverlo ya
        let propio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        do {
            try FileManager.default.moveItem(at: location, to: propio)
            continuacion?.resume(returning: propio)
        } catch {
            continuacion?.resume(throwing: error)
        }
        continuacion = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        datosReanudar = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        continuacion?.resume(throwing: error)
        continuacion = nil
    }
}
