import Network
import SwiftUI

// Internet connection state. The assistant does not need it: it only matters for downloading the models.

@MainActor
final class Connectivity: ObservableObject {
    @Published private(set) var isOnline = true
    @Published private(set) var isCellular = false

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            let onCellular = path.usesInterfaceType(.cellular)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.isOnline = isOnline
                    self?.isCellular = onCellular
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "conexion"))
    }

    deinit { monitor.cancel() }
}

/// Navigation bar title with the connection state below it, like Mail's “Updated just now”.
struct TitleWithStatus: View {
    @EnvironmentObject private var connectivity: Connectivity
    let title: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.headline)
            // HStack rather than Label: in the bar, Label shows only the icon
            HStack(spacing: 4) {
                Image(systemName: connectivity.isOnline ? "wifi" : "wifi.slash")
                Text(connectivity.isOnline ? (connectivity.isCellular ? "En línea · datos móviles" : "En línea") : "Sin conexión · funciona igual")
            }
            .font(.caption2)
            .foregroundStyle(connectivity.isOnline ? Theme.online : Theme.offline)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Screen title with the connection state, the same on every tab.
    func titleWithStatus(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { TitleWithStatus(title: title) } }
    }
}
