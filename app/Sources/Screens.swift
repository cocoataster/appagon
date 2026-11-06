import SwiftUI

// The answer (same in chat and in saved answers) and the screens other than the chat.

/// The user's question, on the right as in Messages.
struct QuestionBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
    }
}

struct AnswerView: View {
    @EnvironmentObject private var history: History
    let m: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(m.answer).textSelection(.enabled)

            // safety net: if the model got the figure wrong, it always shows below
            ForEach(m.correction, id: \.self) { c in
                Label("Dato calculado: " + c, systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }

            if !m.calculations.isEmpty {
                DetailSection(title: "Cálculo", lines: m.calculations)
            }

            if !m.sources.isEmpty || !m.metrics.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        if !m.sources.isEmpty { DetailSection(title: "Fuentes consultadas", lines: m.sources) }
                        if !m.metrics.isEmpty {
                            Text(m.metrics).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
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
                Text(m.date.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Button { history.toggleSaved(m.id) } label: {
                    Image(systemName: m.isSaved ? "bookmark.fill" : "bookmark")
                        .font(.title2)
                        .foregroundStyle(m.isSaved ? Theme.accent : .secondary)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(m.isSaved ? "Quitar de guardadas" : "Guardar")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

struct DetailSection: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

struct SavedView: View {
    @EnvironmentObject private var history: History
    @State private var collapsed: Set<Category> = []

    var body: some View {
        NavigationStack {
            Group {
                if history.saved.isEmpty {
                    ContentUnavailableView("Nada guardado", systemImage: "bookmark",
                                           description: Text("Toca el marcador debajo de una respuesta para tenerla aquí."))
                } else {
                    List {
                        ForEach(history.savedByCategory, id: \.category) { group in
                            Section {
                                if !collapsed.contains(group.category) {
                                    ForEach(group.messages) { m in
                                        NavigationLink {
                                            ScrollView {
                                                VStack(alignment: .leading, spacing: 20) {
                                                    QuestionBubble(text: m.question)
                                                    AnswerView(m: m)
                                                }
                                                .padding()
                                            }
                                            .navigationBarTitleDisplayMode(.inline)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(m.question).lineLimit(2)
                                                Text(m.answer).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            .padding(.vertical, 2)
                                        }
                                        .swipeActions {
                                            Button("Quitar", role: .destructive) { history.toggleSaved(m.id) }
                                        }
                                    }
                                }
                            } header: {
                                header(group.category, total: group.messages.count)
                            }
                        }
                    }
                }
            }
            .titleWithStatus("Guardadas")
        }
    }

    /// Header that collapses or expands the category; when collapsed, it still shows how many it holds.
    private func header(_ c: Category, total: Int) -> some View {
        let isCollapsed = collapsed.contains(c)
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                if isCollapsed { collapsed.remove(c) } else { collapsed.insert(c) }
            }
        } label: {
            HStack {
                Text(c.rawValue)
                Spacer()
                Text("\(total)").monospacedDigit()
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(c.rawValue), \(total)")
        .accessibilityValue(isCollapsed ? "Plegada" : "Desplegada")
    }
}

/// Home inventory (water, food, batteries…). Screen only for now: the logic comes later.
struct InventoryView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Próximamente", systemImage: "shippingbox",
                                   description: Text("Aquí podrás apuntar el agua, la comida y el material de emergencia que tienes en casa."))
                .titleWithStatus("Inventario")
        }
    }
}
