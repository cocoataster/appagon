import Foundation

// El asistente sin el modelo: reglas de seguridad, calculadoras, sinónimos, búsqueda en las guías y el mensaje
// que recibe el modelo. Es la versión en Swift de eval/pipeline.py.
//
// Para no copiar a mano lo que puede cambiar, las reglas, los sinónimos, el mensaje de sistema y las constantes
// se leen de Contenido/datos/reglas.json, que genera app/exportar_datos.py a partir de eval/pipeline.py.
// Lo único escrito aquí es la lógica de las calculadoras, y se comprueba contra Python con casos.json
// (app/check o el botón «Autocomprobación» de la app).
//
// No importa llama: así se puede compilar y probar con swiftc en el Mac, sin Xcode ni simulador.

struct Regla: Codable { let patron: String; let texto: String }
struct Sinonimo: Codable { let patron: String; let extra: String }

struct Constantes: Codable {
    let eficiencia_pb: Double
    let eficiencia_pb_txt: String
    let agua: Double
    let agua_txt: String
    let nevera_h: Int
    let congelador_lleno_h: Int
    let congelador_medio_h: Int
}

struct DatosReglas: Codable {
    let system_rag: String
    let reglas: [Regla]
    let sinonimos: [Sinonimo]
    let espana: [String]
    let top_k: Int
    let max_por_fuente: Int
    let prefijo_consulta: String
    let num: String
    let palabras_numero: [String: Double]
    let constantes: Constantes
}

struct Trozo: Codable {
    let fuente: String
    let url: String
    let texto: String
    let vec: [Float]
}

struct Preparado {
    let usuario: String      // mensaje completo que recibe el modelo (reglas + cálculos + guías + pregunta)
    let reglas: [String]
    let calculos: [String]
    let trozos: [Trozo]
}

final class Pipeline {
    let datos: DatosReglas
    let indice: [Trozo]
    private var cache: [String: NSRegularExpression] = [:]

    init(carpeta: URL) throws {
        datos = try JSONDecoder().decode(DatosReglas.self, from: Data(contentsOf: carpeta.appendingPathComponent("reglas.json")))
        indice = try JSONDecoder().decode([Trozo].self, from: Data(contentsOf: carpeta.appendingPathComponent("index.json")))
    }

    // MARK: - Expresiones regulares (equivalentes a re.search de Python)

    private func expresion(_ patron: String, mayusculas: Bool = false) -> NSRegularExpression {
        let clave = (mayusculas ? "i:" : "") + patron
        if let r = cache[clave] { return r }
        let r = try! NSRegularExpression(pattern: patron, options: mayusculas ? [.caseInsensitive] : [])
        cache[clave] = r
        return r
    }

    /// Primera coincidencia: [grupo 0, grupo 1, …] o nil.
    func buscar(_ patron: String, _ texto: String, mayusculas: Bool = false) -> [String]? {
        let rango = NSRange(texto.startIndex..., in: texto)
        guard let m = expresion(patron, mayusculas: mayusculas).firstMatch(in: texto, range: rango) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: texto) else { return "" }
            return String(texto[rr])
        }
    }

    /// Grupo 1 de todas las coincidencias (como re.findall con un grupo).
    func todos(_ patron: String, _ texto: String) -> [String] {
        let rango = NSRange(texto.startIndex..., in: texto)
        return expresion(patron).matches(in: texto, range: rango).compactMap { m in
            guard let rr = Range(m.range(at: 1), in: texto) else { return nil }
            return String(texto[rr])
        }
    }

    // MARK: - 1. Reglas de seguridad

    func indicesReglas(_ q: String) -> [Int] {
        let ql = q.lowercased()
        return datos.reglas.indices.filter { buscar(datos.reglas[$0].patron, ql) != nil }
    }

    // MARK: - 2. Calculadoras deterministas

    func numero(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let w = datos.palabras_numero[t] { return w }
        var u = t
        if buscar(#"^\d{1,3}(\.\d{3})+$"#, u) != nil { u = u.replacingOccurrences(of: ".", with: "") }
        return Double(u.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    func formato(_ x: Double) -> String {
        String(format: "%.1f", x).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: ",0", with: "")
    }

    func calculadoras(_ q: String) -> [String] {
        let ql = q.lowercased()
        let NUM = datos.num
        let c = datos.constantes
        var out: [String] = []

        // Power bank → cargas del móvil
        let mah = todos(#"(\d{1,3}(?:\.\d{3})+|\d+)\s*mah"#, ql)
        if (ql.contains("power bank") || ql.contains("powerbank") || ql.contains("batería externa")) && mah.count >= 2 {
            let vals = mah.map(numero)
            let pb = vals.max()!, movil = vals.min()!
            var cuantas = 1.0
            if let k = buscar(NUM + #"\s+power ?banks?"#, ql), !["un", "una", "uno"].contains(k[1]) { cuantas = numero(k[1]) }
            let total = pb * cuantas
            let cargas = total * c.eficiencia_pb / movil
            out.append("Cargas completas aproximadas = \(Int(total)) mAh × \(c.eficiencia_pb_txt) ÷ \(Int(movil)) mAh = \(formato(cargas)) cargas (una power bank entrega ~70 % de su capacidad nominal).")
        }

        // Horas de nevera / congelador
        let h = buscar(NUM + #"\s*horas"#, ql)
        let perecedero = buscar("nevera|frigor|leche|pollo|carne|pescado|huevo|sobras|yogur", ql) != nil
        let congelador = ql.contains("congelador") || (ql.contains("congel") && buscar("nevera|frigor", ql) == nil)
        if let h = h, perecedero || congelador {
            let horas = numero(h[1])
            let limite: Int
            let nombre: String
            if congelador {
                let medio = ql.contains("medio")
                limite = medio ? c.congelador_medio_h : c.congelador_lleno_h
                nombre = medio ? "congelador medio lleno" : "congelador lleno"
            } else {
                limite = c.nevera_h
                nombre = "nevera"
            }
            let resto = Double(limite) - horas
            if resto > 0 {
                out.append("Margen restante = \(limite) h (\(nombre) sin abrir) − \(formato(horas)) h = \(formato(resto)) h.")
            } else {
                let accion = nombre == "nevera"
                    ? " Tira los perecederos (leche, carne, pescado, huevos, sobras) aunque huelan o parezcan bien."
                    : " Lo que se haya descongelado del todo no se vuelve a congelar."
                out.append("Han pasado \(formato(horas)) h y el límite (\(nombre) sin abrir) es de \(limite) h: el límite ya se ha superado.\(accion)")
            }
        }

        // Agua: necesidad o días que dura
        let personas = buscar(#"somos\s+"# + NUM, ql) ?? buscar(NUM + #"\s+personas"#, ql) ?? buscar(#"somos\s+"# + NUM + #"\s+en casa"#, ql)
        if ql.contains("agua") || ql.contains("litros") {
            let p: Double? = personas.map { numero($0[1]) }
            let litros = buscar(NUM + #"\s*litros"#, ql)
            let dias = buscar(#"para\s+"# + NUM + #"\s*d[ií]as"#, ql)
            if let p = p, p != 0, let litros = litros, ql.contains("cuántos días") || ql.contains("llega") {
                let L = numero(litros[1])
                let d = L / (p * c.agua)
                out.append("Días de agua = \(formato(L)) L ÷ (\(formato(p)) personas × \(c.agua_txt) L/día) = \(formato(d)) días.")
            } else if let p = p, p != 0, let dias = dias {
                let d = numero(dias[1])
                let L = p * d * c.agua
                out.append("Agua necesaria = \(formato(p)) personas × \(formato(d)) días × \(c.agua_txt) L = \(formato(L)) litros como mínimo.")
            }
        }
        return out
    }

    // MARK: - 3. Búsqueda en las guías

    /// Añade a la pregunta las palabras de las guías de EE. UU. (solo para buscar).
    func expandir(_ q: String) -> String {
        let extra = datos.sinonimos.filter { buscar($0.patron, q, mayusculas: true) != nil }.map { $0.extra }
        return extra.isEmpty ? q : q + " (" + extra.joined(separator: ", ") + ")"
    }

    /// Texto que se convierte en vector para buscar (con el prefijo de EmbeddingGemma para consultas).
    func textoConsulta(_ q: String) -> String { datos.prefijo_consulta + expandir(q) }

    func esEspana(_ t: Trozo) -> Bool { datos.espana.contains { t.fuente.contains($0) } }

    /// Los 6 trozos más parecidos, como mucho 2 por guía, con las españolas primero. Devuelve posiciones en el índice.
    func recuperar(_ consulta: [Float]) -> [Int] {
        let puntos: [Double] = indice.map { t in
            var s = 0.0
            for i in 0..<min(consulta.count, t.vec.count) { s += Double(consulta[i]) * Double(t.vec[i]) }
            return s
        }
        let orden = puntos.indices.sorted { puntos[$0] > puntos[$1] }
        var top: [Int] = []
        var porFuente: [String: Int] = [:]
        for i in orden {
            let f = indice[i].fuente
            if porFuente[f, default: 0] < datos.max_por_fuente {
                top.append(i)
                porFuente[f, default: 0] += 1
            }
            if top.count == datos.top_k { break }
        }
        return top.filter { esEspana(indice[$0]) } + top.filter { !esEspana(indice[$0]) }
    }

    // MARK: - 4. Todo junto

    func preparar(_ q: String, trozos posiciones: [Int]) -> Preparado {
        let reglas = indicesReglas(q).map { datos.reglas[$0].texto }
        let calculos = calculadoras(q)
        let docs = posiciones.map { indice[$0] }
        var partes: [String] = []
        if !reglas.isEmpty { partes.append("REGLAS DE SEGURIDAD:\n" + reglas.map { "- " + $0 }.joined(separator: "\n")) }
        if !calculos.isEmpty { partes.append("DATOS CALCULADOS:\n" + calculos.map { "- " + $0 }.joined(separator: "\n")) }
        let guias = docs.enumerated().map { e in
            "[\(e.offset + 1)] (\(e.element.fuente)\(esEspana(e.element) ? " · España" : "")) \(e.element.texto)"
        }
        partes.append("GUÍAS:\n" + guias.joined(separator: "\n\n"))
        partes.append("PREGUNTA: \(q)")
        return Preparado(usuario: partes.joined(separator: "\n\n"), reglas: reglas, calculos: calculos, trozos: docs)
    }

    /// Quita los guiones de corte de línea que el modelo copia de los PDF («in-\nmediato») y los saltos de línea.
    func limpiar(_ respuesta: String) -> String {
        var t = respuesta
        if let r = try? NSRegularExpression(pattern: #"(\w)-\s*\n\s*(\w)"#) {
            t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1$2")
        }
        if let r = try? NSRegularExpression(pattern: #"\s*\n\s*"#) {
            t = r.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 5. Red de seguridad para las cifras

    /// Números que aparecen en un texto, normalizados a coma decimal («1.8» → «1,8»; «una» → «1»).
    func numerosEn(_ texto: String) -> Set<String> {
        var out = Set<String>()
        let t = texto.lowercased()
        let r = expresion(#"\d+(?:[.,]\d+)?"#)
        for m in r.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let rr = Range(m.range, in: t) else { continue }
            var n = String(t[rr]).replacingOccurrences(of: ".", with: ",")
            if n.hasSuffix(",0") { n = String(n.dropLast(2)) }
            out.insert(n)
        }
        let palabras = expresion(#"\b(un|una|uno|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez)\b"#)
        for m in palabras.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let rr = Range(m.range, in: t), let v = datos.palabras_numero[String(t[rr])] else { continue }
            out.insert(formato(v))
        }
        return out
    }

    /// Si hay un dato calculado y la respuesta del modelo no lo recoge (o da otra cifra), devuelve las líneas
    /// que la app debe mostrar con el dato correcto. Lo exacto lo garantiza el código, no el modelo.
    func datosQueFaltan(respuesta: String, calculos: [String]) -> [String] {
        let enRespuesta = numerosEn(respuesta)
        let rl = respuesta.lowercased()
        var faltan: [String] = []
        for c in calculos {
            if c.hasPrefix("Han pasado") {
                // límite superado: la respuesta tiene que decir que se ha superado o que se tire
                let niega = rl.contains("no se ha superado") || rl.contains("no ha superado") || rl.contains("no se han superado")
                let avisa = rl.contains("superad") || rl.contains("tira") || rl.contains("desech") || rl.contains("no la consumas")
                    || rl.contains("no lo consumas") || rl.contains("no los consumas") || rl.contains("no las consumas")
                if niega || !avisa {   // p. ej. «Sí, la leche huele bien y no se ha superado el límite» (fallo real de la evaluación)
                    faltan.append(c)
                }
                continue
            }
            // resultado = último número antes de la unidad («= 1 h.», «= 1,8 cargas», «= 18 litros», «= 1,3 días»)
            let r = expresion(#"=\s*(\d+(?:,\d+)?)\s*(h\b|cargas|días|litros)"#)
            let ms = r.matches(in: c, range: NSRange(c.startIndex..., in: c))
            guard let m = ms.last, let rr = Range(m.range(at: 1), in: c) else { continue }
            if !enRespuesta.contains(String(c[rr])) { faltan.append(c) }
        }
        return faltan
    }
}

// MARK: - Comprobación contra Python (casos.json)

struct Caso: Codable {
    let q: String
    let reglas: [Int]
    let calculos: [String]
    let expandida: String
    let top: [Int]?
}

enum Comprobacion {
    /// Reglas, calculadoras y sinónimos: deben coincidir exactamente con eval/pipeline.py.
    static func puras(_ p: Pipeline, _ casos: [Caso]) -> (fallos: Int, texto: String) {
        var fallos = 0
        var detalle: [String] = []
        for c in casos {
            var errores: [String] = []
            let r = p.indicesReglas(c.q)
            if r != c.reglas { errores.append("reglas \(r) ≠ \(c.reglas)") }
            let k = p.calculadoras(c.q)
            if k != c.calculos { errores.append("cálculo «\(k.joined(separator: " | "))» ≠ «\(c.calculos.joined(separator: " | "))»") }
            let e = p.expandir(c.q)
            if e != c.expandida { errores.append("sinónimos «\(e)» ≠ «\(c.expandida)»") }
            if !errores.isEmpty {
                fallos += 1
                detalle.append("✗ \(c.q)\n   " + errores.joined(separator: "\n   "))
            }
        }
        let cabecera = "Reglas, calculadoras y sinónimos: \(casos.count - fallos) de \(casos.count) iguales que en Python."
        return (fallos, ([cabecera] + detalle).joined(separator: "\n"))
    }

    /// Casos fijos de la red de seguridad: (pregunta, respuesta del modelo, ¿debe añadir el dato?).
    static func redSeguridad(_ p: Pipeline) -> (fallos: Int, texto: String) {
        let nevera = "Se ha ido la luz hace 3 horas, ¿la comida de la nevera sigue siendo segura?"
        let agua = "Somos 4 en casa, ¿cuánta agua necesitamos para 3 días?"
        let leche = "La leche huele bien después de 5 horas sin luz. ¿Me la puedo beber?"
        let pb = "Tengo una power bank de 10.000 mAh y mi móvil tiene 4000 mAh, ¿cuántas cargas me da?"
        let pruebas: [(String, String, Bool)] = [
            (nevera, "Sí, con 4 horas de margen restante la comida sigue siendo segura.", true),   // fallo real del simulador
            (nevera, "Sí, con 1 hora de margen restante la comida de la nevera sigue siendo segura.", false),
            (nevera, "Te queda una hora de margen si no abres la nevera.", false),
            (agua, "Con 4 personas necesitas 18 litros de agua como mínimo para 3 días.", false),
            (agua, "Necesitáis unos 12 litros.", true),
            (leche, "No la consumas aunque huela bien: el límite ya se ha superado.", false),
            (leche, "Sí, la leche huele bien y se puede beber.", true),
            (leche, "Sí, la leche huele bien y no se ha superado los 4 h de límite.", true),   // fallo real (GS005)
            (pb, "Te da unas 1,8 cargas completas.", false),
            (pb, "Unas 2,5 cargas.", true),
        ]
        var fallos = 0
        var detalle: [String] = []
        for (q, r, debe) in pruebas {
            let anade = !p.datosQueFaltan(respuesta: r, calculos: p.calculadoras(q)).isEmpty
            if anade != debe { fallos += 1; detalle.append("✗ «\(r)»: \(anade ? "añade" : "no añade") el dato") }
        }
        let cabecera = "Red de seguridad de las cifras: \(pruebas.count - fallos) de \(pruebas.count) casos bien."
        return (fallos, ([cabecera] + detalle).joined(separator: "\n"))
    }
}
