import SwiftUI

@main
struct ApagonApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    // Un solo asistente para toda la app: si se creara otra vez, volvería a cargar los 2 GB del modelo.
    @StateObject private var a = Asistente()
    @StateObject private var historial = Historial()
    @StateObject private var conexion = Conexion()

    var body: some View {
        TabView {
            ChatsView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            GuardadasView()
                .tabItem { Label("Guardadas", systemImage: "bookmark") }
            InventarioView()
                .tabItem { Label("Inventario", systemImage: "shippingbox") }
        }
        .tint(Tema.ambar)
        .environmentObject(a)
        .environmentObject(historial)
        .environmentObject(conexion)
        .preferredColorScheme(.dark)   // pantalla oscura: gasta menos batería
        .task { await a.cargar() }
    }
}

/// Lista de chats. El lápiz abre uno nuevo y tocar una fila lo reabre, los dos en una hoja.
struct ChatsView: View {
    @EnvironmentObject private var a: Asistente
    @EnvironmentObject private var historial: Historial
    @EnvironmentObject private var conexion: Conexion
    @State private var chatAbierto = false
    @State private var verComprobacion = false
    @State private var confirmarBorrado = false

    var body: some View {
        NavigationStack {
            List {
                switch a.estado {
                case .faltanModelos, .descargando:
                    Section { TarjetaDescarga() }
                default:
                    EmptyView()
                }

                if historial.conversaciones.isEmpty {
                    Section {
                        Button { abrir(nil) } label: {
                            Label("Haz tu primera pregunta", systemImage: "square.and.pencil")
                        }
                    } footer: {
                        Text("El modelo y las guías oficiales están en el móvil: funciona sin conexión. Los chats se guardan aquí.")
                    }
                } else {
                    Section {
                        ForEach(historial.conversaciones) { c in
                            Button { abrir(c.id) } label: { fila(c) }
                                .foregroundStyle(.primary)
                        }
                        .onDelete { indices in
                            for id in indices.map({ historial.conversaciones[$0].id }) { historial.borrar(id) }
                        }
                    }
                }
            }
            .tituloConEstado("Chats")
            .overlay(alignment: .bottomTrailing) { Boton112().padding() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { menu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { abrir(nil) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Nuevo chat")
                }
            }
            .sheet(isPresented: $chatAbierto) {
                ChatView()
                    .environmentObject(a)
                    .environmentObject(historial)
                    .environmentObject(conexion)
            }
            .sheet(isPresented: $verComprobacion) {
                NavigationStack {
                    ScrollView {
                        Text(a.comprobacion ?? "").font(.footnote.monospaced()).padding().textSelection(.enabled)
                    }
                    .navigationTitle("Autocomprobación")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cerrar") { verComprobacion = false } }
                }
            }
            .confirmationDialog("Se borrarán todos los chats y las respuestas guardadas.",
                                isPresented: $confirmarBorrado, titleVisibility: .visible) {
                Button("Borrar todos los chats", role: .destructive) { historial.borrarTodo() }
            }
        }
    }

    private func abrir(_ id: UUID?) {
        if let id { historial.abrir(id) } else { historial.nueva() }
        chatAbierto = true
    }

    private var menu: some View {
        Menu {
            Button {
                Task { await a.autocomprobar(); verComprobacion = true }
            } label: { Label("Autocomprobación", systemImage: "checkmark.seal") }
                .disabled(a.ocupado)
            Button(role: .destructive) { confirmarBorrado = true } label: {
                Label("Borrar todos los chats", systemImage: "trash")
            }
            .disabled(historial.conversaciones.isEmpty)
            Button(role: .destructive) {
                Task { await a.borrarModelos() }
            } label: { Label("Borrar modelos descargados", systemImage: "externaldrive.badge.minus") }
                .disabled(a.ocupado && a.estado != .faltanModelos)
        } label: { Image(systemName: "ellipsis") }
    }

    private func fila(_ c: Conversacion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(c.titulo).lineLimit(2)
            HStack {
                Text(c.mensajes.count == 1 ? "1 pregunta" : "\(c.mensajes.count) preguntas")
                if c.mensajes.contains(where: \.guardado) { Image(systemName: "bookmark.fill") }
                Spacer()
                Text(c.fecha.formatted(.relative(presentation: .named)))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Un chat, en una hoja. Si se cierra mientras responde, la respuesta se guarda igual al terminar.
struct ChatView: View {
    @EnvironmentObject private var a: Asistente
    @EnvironmentObject private var historial: Historial
    @Environment(\.dismiss) private var cerrar
    @State private var texto = ""
    @FocusState private var enfocado: Bool

    private let sugerencias = [
        "Se ha ido la luz hace 3 horas, ¿la comida de la nevera sigue siendo segura?",
        "Somos 4 en casa, ¿cuánta agua necesitamos para 3 días?",
        "¿Qué emisora de radio sigo durante el apagón y cómo la escucho sin luz?",
    ]

    /// La conversación que se ve es la que está esperando respuesta.
    private var enCurso: Bool { historial.respondiendo == historial.actual }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if historial.mensajesActuales.isEmpty && !enCurso { sugerenciasVista }

                        ForEach(historial.mensajesActuales) { m in
                            BurbujaPregunta(texto: m.pregunta)
                            VistaRespuesta(m: m)
                        }

                        if enCurso {
                            BurbujaPregunta(texto: a.pregunta)
                            respuestaEnCurso
                        }

                        estadoVista

                        Text("No sustituye a los servicios de emergencia. Si hay riesgo para la vida, llama al 112.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                        Color.clear.frame(height: 1).id("fin")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: a.respuesta) { proxy.scrollTo("fin", anchor: .bottom) }
                .onChange(of: historial.respondiendo) { proxy.scrollTo("fin", anchor: .bottom) }
                .onAppear { if !historial.mensajesActuales.isEmpty { proxy.scrollTo("fin", anchor: .bottom) } }
            }
            .overlay(alignment: .bottomTrailing) { Boton112().padding() }   // queda encima de la caja de texto
            .safeAreaInset(edge: .bottom) {
                entrada
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))   // color fijo, sin desenfoque: no recalcula nada al desplazar
            }
            .tituloConEstado(historial.mensajesActuales.isEmpty && !enCurso ? "Nuevo chat" : "Chat")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cerrar") { cerrar() } }
            }
        }
        .onAppear { if historial.mensajesActuales.isEmpty && !a.ocupado { enfocado = true } }
    }

    private var sugerenciasVista: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prueba con").font(.footnote).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(sugerencias.enumerated()), id: \.offset) { i, s in
                    if i > 0 { Divider().padding(.leading) }
                    Button { enviar(s) } label: {
                        Text(s)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(a.ocupado)
                    .foregroundStyle(a.ocupado ? .secondary : .primary)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private var respuestaEnCurso: some View {
        if a.respuesta.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                switch a.estado {
                case .leyendo(let desde):
                    TimelineView(.periodic(from: desde, by: 1)) { ctx in
                        Text("Leyendo las guías… \(Int(ctx.date.timeIntervalSince(desde))) s")
                    }
                default:
                    Text("Buscando en las guías…")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } else {
            Text(a.respuesta)
        }
    }

    @ViewBuilder private var estadoVista: some View {
        switch a.estado {
        case .cargando:
            Label { Text("Cargando el modelo…") } icon: { ProgressView() }
                .font(.subheadline).foregroundStyle(.secondary)
        case .error(let m):
            Label(m, systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(.orange)
        case .faltanModelos, .descargando:
            TarjetaDescarga()
        case .comprobando(let t):
            Label { Text(t) } icon: { ProgressView() }
                .font(.subheadline).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var entrada: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Escribe tu pregunta…", text: $texto, axis: .vertical)
                .lineLimit(1...4)
                .focused($enfocado)
                .submitLabel(.send)
                .onSubmit { enviar(texto) }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            Button { enviar(texto) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(!puedeEnviar)
            .accessibilityLabel("Enviar")
        }
    }

    private var puedeEnviar: Bool { !a.ocupado && !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func enviar(_ q: String) {
        guard !a.ocupado, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = historial.actual
        historial.respondiendo = id
        texto = ""
        enfocado = false
        Task {
            if let m = await a.preguntar(q) {
                historial.agregar(m, a: id)
            } else if texto.isEmpty {
                texto = q   // si falla, la pregunta vuelve a la caja para reintentar
            }
            historial.respondiendo = nil
        }
    }
}

/// Aviso para descargar los modelos (o su progreso), en la lista de chats y dentro del chat.
struct TarjetaDescarga: View {
    @EnvironmentObject private var a: Asistente
    @EnvironmentObject private var conexion: Conexion

    var body: some View {
        switch a.estado {
        case .descargando(let texto, let fraccion):
            VStack(alignment: .leading, spacing: 8) {
                Label("Descargando el asistente", systemImage: "arrow.down.circle").font(.headline)
                ProgressView(value: fraccion)
                Text(texto).font(.footnote.monospacedDigit())
                Text("No cierres la app hasta que termine.").font(.caption).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                Label("Falta descargar el asistente", systemImage: "arrow.down.circle").font(.headline)
                Text("Para funcionar sin conexión necesita descargar \(a.pendiente) una sola vez. Hazlo ahora, con Wi-Fi y con la app abierta: durante un apagón ya no se podrá.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !conexion.enLinea {
                    Label("Sin conexión. Conéctate a una Wi-Fi para descargarlo.", systemImage: "wifi.slash")
                        .font(.footnote).foregroundStyle(.orange)
                } else if conexion.datosMoviles {
                    Label("Estás con datos móviles: mejor con Wi-Fi.", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let e = a.errorDescarga {
                    Text(e).font(.footnote).foregroundStyle(.orange)
                }
                Button(a.errorDescarga == nil ? "Descargar ahora" : "Reintentar") {
                    Task { await a.descargar() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!conexion.enLinea)
            }
        }
    }
}

/// Botón flotante y redondo para llamar al 112, siempre abajo a la derecha.
struct Boton112: View {
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
