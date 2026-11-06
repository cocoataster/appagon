import Foundation

/// Categories for saved answers: the same as the golden set (data/golden_set_final.csv).
/// Inferred from the question with keywords, without the model, so they also work for answers already saved.
enum Category: String, CaseIterable, Identifiable {
    // Order matters: the first match wins («agua para el kit» is Preparación), and it is also the on-screen order.
    case safety = "Seguridad"
    case preparedness = "Preparación"
    case temperature = "Frío y calor"
    case food = "Comida y nevera"
    case water = "Agua"
    case communication = "Comunicación"
    case energy = "Energía"
    case other = "Otras"

    var id: Self { self }

    private var pattern: String? {
        switch self {
        case .safety:
            return #"generador|grupo electr|monoxido|barbacoa|brasero|huele a gas|olor a gas|fuga de gas|insulina|medicament|antibiotico|pastilla|dosis|oxigeno|concentrador|respirador|dialisis|ascensor|velas? de forma|extintor|incendio|fuego|cable|lejia.*amon|amon.*lejia|pila de bot|desmay|inconsciente|herida|dolor|pecho|engancho|vecino|humo|incendi|quemado|electrocut|paracetamol|ibuprofeno|fiebre|no responde|respira|vomit|salfuman|inundad|confin"#
        case .preparedness:
            return #"\bkit\b|inventario|mochila|documentos|efectivo|mascota|prepar|\bguardo\b|\bsalgo\b"#
        case .temperature:
            return #"\bfrio\b|\bcalor\b|calent|caliente|calefacci|estufa|chimenea|hipotermia|ventilador|aire acondicionado|abrig|fresca"#
        case .food:
            return #"nevera|frigorifico|congel|comida|comer\b|alimento|leche|carne|pollo|pescado|huevo"#
        case .water:
            return #"\bagua\b|lejia|potab|grifo|vater|hervi"#
        case .energy:
            return #"power ?bank|\bmah\b|bateria|\bcarga|linterna|alumbr|velas?\b|desenchuf|enchuf|electrodomestic|alargador|\bpilas?\b|placas solares|contador|volver.*luz|vuelto la luz|noticias|\bmovil\b"#
        case .communication:
            return #"\bradio\b|emisora|\b112\b|emergencias|internet|informa|mensaje|rumor|llam|familia|cobertura|modo avion"#
        case .other:
            return nil
        }
    }

    static func from(_ question: String) -> Category {
        let q = question.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
        return allCases.first { c in
            c.pattern.map { q.range(of: $0, options: .regularExpression) != nil } ?? false
        } ?? .other
    }
}
