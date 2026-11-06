import SwiftUI

/// Settings: which models the app uses and their state, plus the developer tools.
struct SettingsView: View {
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var history: History
    @State private var showReport = false
    @State private var confirmChats = false
    @State private var confirmModels = false

    var body: some View {
        NavigationStack {
            List {
                Section("Modelos") {
                    ForEach(Models.list()) { ModelRow(m: $0) }
                }
                Section("Fuentes") {
                    NavigationLink("Guías consultadas") { SourcesView() }
                }
                Section("Desarrollador") {
                    Button {
                        Task {
                            await assistant.selfCheck()
                            showReport = assistant.verificationReport != nil
                        }
                    } label: { Label("Autocomprobación", systemImage: "checkmark.seal") }
                        .disabled(assistant.isBusy)
                    Button(role: .destructive) { confirmChats = true } label: {
                        Label("Borrar todos los chats", systemImage: "trash")
                    }
                    .disabled(history.conversations.isEmpty)
                    Button(role: .destructive) { confirmModels = true } label: {
                        Label("Borrar modelos descargados", systemImage: "externaldrive.badge.minus")
                    }
                    .disabled(assistant.isBusy && assistant.status != .modelsMissing)
                }
                .tint(Color.accentColor)   // iOS blue: these are tools, not part of the app
            }
            .titleWithStatus("Ajustes")
            .sheet(isPresented: $showReport) {
                NavigationStack {
                    ScrollView {
                        Text(assistant.verificationReport ?? "").font(.footnote.monospaced()).padding().textSelection(.enabled)
                    }
                    .navigationTitle("Autocomprobación")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button { showReport = false } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Cerrar")
                    }
                }
            }
            .confirmationDialog("Se borrarán todos los chats y las respuestas guardadas.",
                                isPresented: $confirmChats, titleVisibility: .visible) {
                Button("Borrar todos los chats", role: .destructive) { history.deleteAll() }
            }
            .confirmationDialog("Para volver a usar el asistente habrá que descargar los modelos otra vez, con conexión.",
                                isPresented: $confirmModels, titleVisibility: .visible) {
                Button("Borrar modelos descargados", role: .destructive) {
                    Task { await assistant.deleteModels() }
                }
            }
        }
    }
}

/// One model: name, size, state and an info button explaining what it is for.
private struct ModelRow: View {
    @EnvironmentObject private var assistant: Assistant
    let m: RemoteModel
    @State private var showInfo = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title)
                Text(Models.sizeText(m.bytes)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            status.font(.footnote)
            Button { showInfo = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Para qué sirve \(m.title)")
        }
        .alert(m.title, isPresented: $showInfo) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text(m.explanation)
        }
    }

    @ViewBuilder private var status: some View {
        if assistant.downloadingID == m.id {
            HStack(spacing: 6) {
                ProgressView()
                Text("Descargando").foregroundStyle(.secondary)
            }
        } else if let path = Models.path(m) {
            if path.path.hasPrefix(Models.folder.path) {
                Label("Descargado", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                Label("En el Mac", systemImage: "laptopcomputer").foregroundStyle(.secondary)   // only when launched from Xcode
            }
        } else {
            Label("No descargado", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        }
    }
}

/// One of the guides the answers come from.
struct Source: Decodable, Identifiable {
    let source: String
    let url: String?
    var id: String { source }

    enum CodingKeys: String, CodingKey {   // index.json keeps its Spanish keys
        case source = "fuente", url
    }

    /// Read from index.json, like the chunks the assistant uses, so the list cannot go stale.
    static func list() -> [Source] {
        let u = Resources.data.appendingPathComponent("index.json")
        guard let d = try? Data(contentsOf: u), let chunks = try? JSONDecoder().decode([Source].self, from: d) else { return [] }
        let unique = Dictionary(chunks.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first }).values
        return unique.sorted { $0.source.localizedStandardCompare($1.source) == .orderedAscending }
    }
}

/// List of guides, each linking to the original.
private struct SourcesView: View {
    @State private var sources: [Source]?

    var body: some View {
        List {
            if let sources {
                Section {
                    ForEach(sources) { f in
                        if let text = f.url, let url = URL(string: text) {
                            Link(destination: url) {
                                HStack {
                                    Text(f.source).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text(f.source)
                        }
                    }
                } footer: {
                    Text("Las respuestas salen de estas \(sources.count) guías, que ya están en el móvil. Solo hace falta conexión para abrir el original.")
                }
            }
        }
        .overlay { if sources == nil { ProgressView() } }
        .navigationTitle("Guías consultadas")
        .navigationBarTitleDisplayMode(.inline)
        .task { sources = await Task.detached(priority: .userInitiated) { Source.list() }.value }   // index.json is a few MB
    }
}

extension RemoteModel {
    var title: String {
        switch id {
        case "generador": return "Ministral 3 3B"
        case "vectores": return "EmbeddingGemma"
        default: return fileName
        }
    }

    var explanation: String {
        switch id {
        case "generador":
            return "Escribe las respuestas. Lee los trozos de las guías oficiales que encuentra el buscador y redacta la respuesta en el propio móvil, sin conexión. Está afinado para este asistente."
        case "vectores":
            return "Es el buscador de las guías. Convierte tu pregunta en un vector, una lista de números que resume su significado, y la compara con las guías para encontrar los trozos que mejor la responden. No escribe texto."
        default:
            return name
        }
    }
}
