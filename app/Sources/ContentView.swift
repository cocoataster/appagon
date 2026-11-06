import SwiftUI

@main
struct ApagonApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    // A single assistant for the whole app: creating another would load the 2 GB model again.
    @StateObject private var assistant = Assistant()
    @StateObject private var history = History()
    @StateObject private var connectivity = Connectivity()

    var body: some View {
        TabView {
            ChatsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            SavedView()
                .tabItem { Label("Guardadas", systemImage: "bookmark") }
            InventoryView()
                .tabItem { Label("Inventario", systemImage: "shippingbox") }
            SettingsView()
                .tabItem { Label("Ajustes", systemImage: "gearshape") }
        }
        .tint(Theme.accent)
        .environmentObject(assistant)
        .environmentObject(history)
        .environmentObject(connectivity)
        .preferredColorScheme(.dark)   // dark screen: uses less battery
        .task { await assistant.load() }
    }
}

/// Chat list. The pencil opens a new chat and tapping a row reopens one, both in a sheet.
struct ChatsView: View {
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var history: History
    @EnvironmentObject private var connectivity: Connectivity
    @State private var isChatOpen = false

    var body: some View {
        NavigationStack {
            List {
                switch assistant.status {
                case .modelsMissing, .downloading:
                    Section { DownloadCard() }
                default:
                    EmptyView()
                }

                if history.conversations.isEmpty {
                    Section {
                        Button { open(nil) } label: {
                            Label("Haz tu primera pregunta", systemImage: "square.and.pencil")
                        }
                    } footer: {
                        Text("El modelo y las guías oficiales están en el móvil: funciona sin conexión. Los chats se guardan aquí.")
                    }
                } else {
                    ForEach(history.chatsByDay, id: \.day) { group in
                        Section(title(group.day)) {
                            ForEach(group.chats) { c in
                                Button { open(c.id) } label: { row(c) }
                                    .foregroundStyle(.primary)
                            }
                            .onDelete { indices in
                                for id in indices.map({ group.chats[$0].id }) { history.delete(id) }
                            }
                        }
                    }
                }
            }
            .titleWithStatus("Chats")
            .overlay(alignment: .bottomTrailing) { EmergencyCallButton().padding() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { open(nil) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Nuevo chat")
                }
            }
            .sheet(isPresented: $isChatOpen) {
                ChatView()
                    .environmentObject(assistant)
                    .environmentObject(history)
                    .environmentObject(connectivity)
            }
        }
    }

    private func open(_ id: UUID?) {
        if let id { history.open(id) } else { history.newChat() }
        isChatOpen = true
    }

    private func title(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoy" }
        if calendar.isDateInYesterday(day) { return "Ayer" }
        var format = Date.FormatStyle(locale: Locale(identifier: "es_ES")).weekday(.wide).day().month(.wide)
        if !calendar.isDate(day, equalTo: Date(), toGranularity: .year) { format = format.year() }
        return day.formatted(format)
    }

    private func row(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(c.title).lineLimit(2)
            HStack {
                if c.messages.contains(where: \.isSaved) { Image(systemName: "bookmark.fill") }
                Spacer()
                Text(c.date.formatted(date: .omitted, time: .shortened))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// A chat, in a sheet: a single question and its answer. If closed while answering, the answer is still saved when it finishes.
struct ChatView: View {
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var history: History
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var justAnswered = false   // answered in this visit, not an old chat being reread
    @FocusState private var isInputFocused: Bool

    private let suggestions = [
        "Se ha ido la luz hace 3 horas, ¿la comida de la nevera sigue siendo segura?",
        "Somos 4 en casa, ¿cuánta agua necesitamos para 3 días?",
        "¿Qué emisora de radio sigo durante el apagón y cómo la escucho sin luz?",
    ]

    /// The visible conversation is the one waiting for an answer.
    private var isResponding: Bool { history.respondingID == history.currentID }
    /// Each chat takes one question: if it fails, nothing is saved and it can be retried.
    private var acceptsQuestion: Bool { history.currentMessages.isEmpty && !isResponding }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if acceptsQuestion { suggestionsView }

                        ForEach(history.currentMessages) { m in
                            QuestionBubble(text: m.question)
                            AnswerView(m: m)
                        }

                        if isResponding {
                            QuestionBubble(text: assistant.question)
                            streamingAnswer
                        }

                        statusView

                        Text("No sustituye a los servicios de emergencia. Si hay riesgo para la vida, llama al 112.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        Color.clear.frame(height: 1).id("fin")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { isInputFocused = false }
                .onChange(of: assistant.answer) { proxy.scrollTo("fin", anchor: .bottom) }
                .onChange(of: history.respondingID) { proxy.scrollTo("fin", anchor: .bottom) }
                .onAppear { if !history.currentMessages.isEmpty { proxy.scrollTo("fin", anchor: .bottom) } }
            }
            .safeAreaInset(edge: .bottom) {
                if acceptsQuestion {
                    inputBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(.systemBackground))   // solid color, no blur: nothing is recomputed while scrolling
                } else if !isResponding, let answered = history.currentMessages.last {
                    actionBar(answered)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(.systemBackground))
                }
            }
            .titleWithStatus(acceptsQuestion ? "Nuevo chat" : "Chat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cerrar")
                }
            }
        }
        .task {
            // Focusing while the sheet is still sliding in does not bring up the keyboard.
            try? await Task.sleep(for: .milliseconds(500))
            if acceptsQuestion { isInputFocused = true }
        }
    }

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prueba con").font(.footnote).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                    if i > 0 { Divider().padding(.leading) }
                    Button { send(s) } label: {
                        Text(s)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(assistant.isBusy)
                    .foregroundStyle(assistant.isBusy ? .secondary : .primary)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private var streamingAnswer: some View {
        if assistant.answer.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                switch assistant.status {
                case .reading(let since):
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text("Leyendo las guías… \(Int(ctx.date.timeIntervalSince(since))) s")
                    }
                default:
                    Text("Buscando en las guías…")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
            Text(assistant.answer)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch assistant.status {
        case .loading:
            Label { Text("Cargando el modelo…") } icon: { ProgressView() }
                .font(.subheadline).foregroundStyle(.secondary)
        case .error(let m):
            Label(m, systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.orange)
        case .modelsMissing, .downloading:
            DownloadCard()
        case .verifying(let t):
            Label { Text(t) } icon: { ProgressView() }
                .font(.subheadline).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Escribe tu pregunta…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .submitLabel(.send)
                .onSubmit { send(text) }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            Button { send(text) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(!canSend)
            .accessibilityLabel("Enviar")
        }
    }

    /// Save is always available; «Entendido» only appears right after the answer finishes, not when rereading a chat.
    private func actionBar(_ m: Message) -> some View {
        VStack(spacing: 8) {
            Button { history.toggleSaved(m.id) } label: {
                Label(m.isSaved ? "Guardada" : "Guardar pregunta", systemImage: m.isSaved ? "bookmark.fill" : "bookmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.save)
            if justAnswered {
                Button { dismiss() } label: {
                    Text("Entendido").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
    }

    private var canSend: Bool { !assistant.isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send(_ q: String) {
        guard !assistant.isBusy, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = history.currentID
        history.respondingID = id
        text = ""
        isInputFocused = false
        Task {
            if let m = await assistant.ask(q) {
                history.add(m, to: id)
                justAnswered = true
            } else if text.isEmpty {
                text = q   // on failure, the question goes back in the box to retry
            }
            history.respondingID = nil
        }
    }
}

/// Prompt to download the models (or their progress), in the chat list and inside a chat.
struct DownloadCard: View {
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var connectivity: Connectivity

    var body: some View {
        switch assistant.status {
        case .downloading(let text, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                Label("Descargando el asistente", systemImage: "arrow.down.circle").font(.headline)
                ProgressView(value: fraction)
                Text(text).font(.footnote.monospacedDigit())
                Text("No cierres la app hasta que termine.").font(.caption).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                Label("Falta descargar el asistente", systemImage: "arrow.down.circle").font(.headline)
                Text("Para funcionar sin conexión necesita descargar \(assistant.pendingSize) una sola vez. Hazlo ahora, con Wi-Fi y con la app abierta: durante un apagón ya no se podrá.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !connectivity.isOnline {
                    Label("Sin conexión. Conéctate a una Wi-Fi para descargarlo.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.orange)
                } else if connectivity.isCellular {
                    Label("Estás con datos móviles: mejor con Wi-Fi.", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let e = assistant.downloadError {
                    Text(e).font(.footnote).foregroundStyle(.orange)
                }
                Button(assistant.downloadError == nil ? "Descargar ahora" : "Reintentar") {
                    Task { await assistant.download() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!connectivity.isOnline)
            }
        }
    }
}

/// Round floating button to call 112, always at the bottom right.
struct EmergencyCallButton: View {
    var body: some View {
        Link(destination: URL(string: "tel:112")!) {
            Label("112", systemImage: "phone.fill")
                .font(.headline)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(Color.red, in: Capsule())
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .accessibilityLabel("Llamar al 112")
    }
}
