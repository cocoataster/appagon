import Foundation

// Conversations and saved answers, stored on the phone (UserDefaults, as JSON).
// History is display-only: each question is answered independently, as in the evaluation.

struct Message: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var question: String
    var answer: String
    var calculations: [String] = []
    var sources: [String] = []
    var correction: [String] = []   // «Dato calculado»: stored with the answer so the safety net is not lost
    var metrics = ""
    var isSaved = false

    // Stored on the phone with these Spanish keys: changing them would lose the user's chats.
    enum CodingKeys: String, CodingKey {
        case id, date = "fecha", question = "pregunta", answer = "respuesta", calculations = "calculos"
        case sources = "fuentes", correction = "correccion", metrics = "medidas", isSaved = "guardado"
    }
}

struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var messages: [Message] = []
    var title: String { messages.first?.question ?? "Conversación nueva" }
    var date: Date { messages.last?.date ?? Date() }

    enum CodingKeys: String, CodingKey {   // stored on the phone: see Message
        case id, messages = "mensajes"
    }
}

@MainActor
final class History: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []   // most recent first
    @Published private(set) var currentID = UUID()   // the one on screen; created when its first answer arrives
    @Published var respondingID: UUID?            // the one waiting for the assistant's answer

    private let key = "historial.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let c = try? JSONDecoder().decode([Conversation].self, from: d) {
            conversations = c
        }
        if let latest = conversations.first { currentID = latest.id }
    }

    var currentMessages: [Message] { conversations.first { $0.id == currentID }?.messages ?? [] }

    var saved: [Message] {
        conversations.flatMap(\.messages).filter(\.isSaved).sorted { $0.date > $1.date }
    }

    /// Saved answers by category, in Category order; within each, most recent first.
    var savedByCategory: [(category: Category, messages: [Message])] {
        let groups = Dictionary(grouping: saved) { Category.from($0.question) }
        return Category.allCases.compactMap { c in groups[c].map { (c, $0) } }
    }

    /// Chats by day, most recent first; within each day, by time.
    var chatsByDay: [(day: Date, chats: [Conversation])] {
        Dictionary(grouping: conversations) { Calendar.current.startOfDay(for: $0.date) }
            .map { (day: $0.key, chats: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    func newChat() { currentID = UUID() }
    func open(_ id: UUID) { currentID = id }

    func add(_ m: Message, to id: UUID) {
        if let i = conversations.firstIndex(where: { $0.id == id }) {
            var c = conversations.remove(at: i)
            c.messages.append(m)
            conversations.insert(c, at: 0)
        } else {
            conversations.insert(Conversation(id: id, messages: [m]), at: 0)
        }
        save()
    }

    func toggleSaved(_ message: UUID) {
        for i in conversations.indices {
            if let j = conversations[i].messages.firstIndex(where: { $0.id == message }) {
                conversations[i].messages[j].isSaved.toggle()
                save()
                return
            }
        }
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { newChat() }
        save()
    }

    func deleteAll() {
        conversations = []
        newChat()
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}
