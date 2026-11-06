import Foundation
import llama

// Envoltorio mínimo de llama.cpp: el modelo que escribe (Ministral 3 3B afinado) y el que convierte texto en
// vectores para buscar en las guías (EmbeddingGemma). Basado en examples/llama.swiftui de llama.cpp.

enum ErrorIA: LocalizedError {
    case modelo(String), contexto, leer, vector

    var errorDescription: String? {
        switch self {
        case .modelo(let ruta): return "No se pudo cargar el modelo: \(ruta)"
        case .contexto: return "No se pudo crear el contexto del modelo."
        case .leer: return "Error al leer el mensaje (llama_decode)."
        case .vector: return "No se pudo calcular el vector de la pregunta."
        }
    }
}

enum LlamaBackend {
    private static var iniciado = false
    static func iniciar() {
        if !iniciado { llama_backend_init(); iniciado = true }
    }
}

private func hilos() -> Int32 { Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2))) }

private func parametrosModelo() -> llama_model_params {
    var p = llama_model_default_params()
    #if targetEnvironment(simulator)
    p.n_gpu_layers = 0   // el simulador no tiene GPU Metal utilizable: todo en CPU
    #endif
    return p
}

private func tokenizar(_ vocab: OpaquePointer, _ texto: String, inicio: Bool) -> [llama_token] {
    let n = Int32(texto.utf8.count)
    var toks = [llama_token](repeating: 0, count: Int(n) + 8)
    var k = llama_tokenize(vocab, texto, n, &toks, Int32(toks.count), inicio, true)
    if k < 0 {
        toks = [llama_token](repeating: 0, count: Int(-k))
        k = llama_tokenize(vocab, texto, n, &toks, Int32(toks.count), inicio, true)
    }
    return Array(toks.prefix(Int(max(k, 0))))
}

private func ponerToken(_ batch: inout llama_batch, _ token: llama_token, _ pos: Int32, salida: Bool) {
    let i = Int(batch.n_tokens)
    batch.token[i] = token
    batch.pos[i] = pos
    batch.n_seq_id[i] = 1
    batch.seq_id[i]![0] = 0
    batch.logits[i] = salida ? 1 : 0
    batch.n_tokens += 1
}

// MARK: - Modelo que escribe

struct Medidas {
    var tokensEntrada = 0          // tokens del mensaje (sistema + pregunta con guías)
    var tokensReutilizados = 0     // tokens del mensaje de sistema que ya estaban leídos
    var primeraPalabra: Double = 0 // segundos desde que empieza a leer hasta el primer token
    var tokensSalida = 0
    var segundosEscribiendo: Double = 0
    var tokPorSeg: Double { segundosEscribiendo > 0 ? Double(tokensSalida) / segundosEscribiendo : 0 }
}

final class LlamaGenerador {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private var batch: llama_batch
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private var prefijo: [llama_token] = []   // mensaje de sistema ya leído: se reutiliza entre preguntas
    private let nCtx: Int32 = 4096
    private let nBatch: Int32 = 512

    init(ruta: String) throws {
        LlamaBackend.iniciar()
        guard let m = llama_model_load_from_file(ruta, parametrosModelo()) else { throw ErrorIA.modelo(ruta) }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(nCtx)
        cp.n_batch = UInt32(nBatch)
        cp.n_ubatch = UInt32(nBatch)
        cp.n_threads = hilos()
        cp.n_threads_batch = hilos()
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw ErrorIA.contexto }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        batch = llama_batch_init(nBatch, 0, 1)
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())   // temperatura 0, como en la evaluación
    }

    deinit {
        llama_sampler_free(sampler)
        llama_batch_free(batch)
        llama_free(ctx)
        llama_model_free(model)
    }

    private func leer(_ toks: [llama_token], desde pos0: Int, salidaAlFinal: Bool) throws {
        var i = 0
        while i < toks.count {
            let fin = min(i + Int(nBatch), toks.count)
            batch.n_tokens = 0
            for j in i..<fin {
                ponerToken(&batch, toks[j], Int32(pos0 + j), salida: salidaAlFinal && j == toks.count - 1)
            }
            if llama_decode(ctx, batch) != 0 { throw ErrorIA.leer }
            i = fin
        }
    }

    private func pieza(_ t: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }

    /// Mismo formato que la plantilla de Ministral 3 en Ollama: <s>[SYSTEM_PROMPT]…[/SYSTEM_PROMPT][INST]…[/INST]
    func generar(sistema: String, usuario: String, maxTokens: Int = 256, alEscribir: (String) -> Void) throws -> Medidas {
        var m = Medidas()
        let t0 = Date()
        let pref = tokenizar(vocab, "[SYSTEM_PROMPT]" + sistema + "[/SYSTEM_PROMPT]", inicio: true)
        let resto = tokenizar(vocab, "[INST]" + usuario + "[/INST]", inicio: false)
        let memoria = llama_get_memory(ctx)
        if !prefijo.isEmpty && pref == prefijo {
            _ = llama_memory_seq_rm(memoria, 0, Int32(pref.count), -1)   // borra solo la pregunta anterior
            m.tokensReutilizados = pref.count
        } else {
            llama_memory_clear(memoria, true)
            prefijo = []
            try leer(pref, desde: 0, salidaAlFinal: false)
            prefijo = pref
        }
        do {
            try leer(resto, desde: pref.count, salidaAlFinal: true)
        } catch {
            prefijo = []   // la memoria queda en un estado dudoso: la próxima vez se relee todo
            throw error
        }
        m.tokensEntrada = pref.count + resto.count

        var pos = Int32(m.tokensEntrada)
        var pendientes: [UInt8] = []
        var inicioEscritura = Date()
        for _ in 0..<maxTokens {
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            if m.tokensSalida == 0 {
                m.primeraPalabra = Date().timeIntervalSince(t0)
                inicioEscritura = Date()
            }
            m.tokensSalida += 1
            pendientes += pieza(tok)
            if let s = String(bytes: pendientes, encoding: .utf8) {   // espera a tener caracteres UTF-8 completos
                alEscribir(s)
                pendientes = []
            }
            if pos >= nCtx - 1 { break }
            batch.n_tokens = 0
            ponerToken(&batch, tok, pos, salida: true)
            pos += 1
            if llama_decode(ctx, batch) != 0 { prefijo = []; throw ErrorIA.leer }
        }
        m.segundosEscribiendo = m.tokensSalida > 0 ? Date().timeIntervalSince(inicioEscritura) : 0
        return m
    }
}

// MARK: - Modelo que convierte texto en vectores (EmbeddingGemma)

final class LlamaVectores {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let dimension: Int
    private let maxTokens = 1024

    init(ruta: String) throws {
        LlamaBackend.iniciar()
        guard let m = llama_model_load_from_file(ruta, parametrosModelo()) else { throw ErrorIA.modelo(ruta) }
        var cp = llama_context_default_params()
        cp.embeddings = true
        cp.n_ctx = UInt32(maxTokens)
        cp.n_batch = UInt32(maxTokens)
        cp.n_ubatch = UInt32(maxTokens)   // los modelos de vectores leen toda la frase de una vez
        cp.n_threads = hilos()
        cp.n_threads_batch = hilos()
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw ErrorIA.contexto }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        let salida = Int(llama_model_n_embd_out(m))
        dimension = salida > 0 ? salida : Int(llama_model_n_embd(m))
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    /// Vector normalizado (longitud 1), como los de rag/index.json.
    func vector(_ texto: String) throws -> [Float] {
        let toks = Array(tokenizar(vocab, texto, inicio: true).prefix(maxTokens))
        var b = llama_batch_init(Int32(toks.count), 0, 1)
        defer { llama_batch_free(b) }
        for (i, t) in toks.enumerated() { ponerToken(&b, t, Int32(i), salida: true) }
        if let memoria = llama_get_memory(ctx) { llama_memory_clear(memoria, true) }
        var r = llama_encode(ctx, b)
        if r != 0 { r = llama_decode(ctx, b) }
        guard r == 0, let p = llama_get_embeddings_seq(ctx, 0) else { throw ErrorIA.vector }
        var v = Array(UnsafeBufferPointer(start: p, count: dimension))
        let norma = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norma > 0 { v = v.map { $0 / norma } }
        return v
    }
}
