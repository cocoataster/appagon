import Network
import SwiftUI

// Estado de la conexión a internet. El asistente no la necesita: solo importa para descargar los modelos.

@MainActor
final class Conexion: ObservableObject {
    @Published private(set) var enLinea = true
    @Published private(set) var datosMoviles = false

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] ruta in
            let enLinea = ruta.status == .satisfied
            let moviles = ruta.usesInterfaceType(.cellular)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.enLinea = enLinea
                    self?.datosMoviles = moviles
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "conexion"))
    }

    deinit { monitor.cancel() }
}

/// Título de la barra de navegación con el estado de la conexión debajo, como el «Actualizado ahora» de Mail.
struct TituloConEstado: View {
    @EnvironmentObject private var conexion: Conexion
    let titulo: String

    var body: some View {
        VStack(spacing: 1) {
            Text(titulo).font(.headline)
            // HStack y no Label: en la barra, Label se queda solo con el icono
            HStack(spacing: 4) {
                Image(systemName: conexion.enLinea ? "wifi" : "wifi.slash")
                Text(conexion.enLinea ? (conexion.datosMoviles ? "En línea · datos móviles" : "En línea") : "Sin conexión · funciona igual")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Título de la pantalla con el estado de la conexión, igual en todas las pestañas.
    func tituloConEstado(_ titulo: String) -> some View {
        navigationTitle(titulo)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { TituloConEstado(titulo: titulo) } }
    }
}
