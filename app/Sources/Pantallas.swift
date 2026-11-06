import SwiftUI

// La respuesta (igual en el chat y en las guardadas) y las pantallas que no son el chat.

/// Pregunta del usuario, a la derecha como en Mensajes.
struct BurbujaPregunta: View {
    let texto: String
    var body: some View {
        Text(texto)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
    }
}

struct VistaRespuesta: View {
    @EnvironmentObject private var historial: Historial
    let m: Mensaje

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.respuesta).textSelection(.enabled)

            // red de seguridad: si el modelo no recogió bien la cifra, se ve siempre debajo
            ForEach(m.correccion, id: \.self) { c in
                Label("Dato calculado: " + c, systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tema.ambar)
            }

            if !m.calculos.isEmpty {
                Detalle(titulo: "Cálculo", lineas: m.calculos)
            }

            if !m.fuentes.isEmpty || !m.medidas.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        if !m.fuentes.isEmpty { Detalle(titulo: "Fuentes consultadas", lineas: m.fuentes) }
                        if !m.medidas.isEmpty {
                            Text(m.medidas).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                } label: {
                    Text("Fuentes y tiempos").font(.footnote).foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }

            HStack {
                Text(m.fecha.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Button { historial.alternarGuardado(m.id) } label: {
                    Image(systemName: m.guardado ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(m.guardado ? Tema.ambar : .secondary)
                }
                .accessibilityLabel(m.guardado ? "Quitar de guardadas" : "Guardar")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

struct Detalle: View {
    let titulo: String
    let lineas: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titulo).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(lineas, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

struct GuardadasView: View {
    @EnvironmentObject private var historial: Historial

    var body: some View {
        NavigationStack {
            Group {
                if historial.guardados.isEmpty {
                    ContentUnavailableView("Nada guardado", systemImage: "bookmark",
                                           description: Text("Toca el marcador debajo de una respuesta para tenerla aquí."))
                } else {
                    List(historial.guardados) { m in
                        NavigationLink {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 20) {
                                    BurbujaPregunta(texto: m.pregunta)
                                    VistaRespuesta(m: m)
                                }
                                .padding()
                            }
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(m.pregunta).lineLimit(2)
                                Text(m.respuesta).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                        .swipeActions {
                            Button("Quitar", role: .destructive) { historial.alternarGuardado(m.id) }
                        }
                    }
                }
            }
            .tituloConEstado("Guardadas")
        }
    }
}

/// Inventario de casa (agua, comida, pilas…). De momento solo la pantalla: la lógica llegará más adelante.
struct InventarioView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Próximamente", systemImage: "shippingbox",
                                   description: Text("Aquí podrás apuntar el agua, la comida y el material de emergencia que tienes en casa."))
                .tituloConEstado("Inventario")
        }
    }
}
