import Foundation
import llama

// Minimal llama.cpp wrapper: the model that writes (fine-tuned Ministral 3 3B) and the one that turns text into
// vectors to search the guides (EmbeddingGemma). Based on llama.cpp's examples/llama.swiftui.

enum LlamaError: LocalizedError {
    case model(String), context, read, vector

    var errorDescription: String? {
        switch self {
        case .model(let path): return "No se pudo cargar el modelo: \(path)"
        case .context: return "No se pudo crear el contexto del modelo."
        case .read: return "Error al leer el mensaje (llama_decode)."
        case .vector: return "No se pudo calcular el vector de la pregunta."
        }
    }
}

enum LlamaBackend {
    private static var initialized = false
    static func start() {
        if !initialized { llama_backend_init(); initialized = true }
    }
}

private func threadCount() -> Int32 { Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2))) }

private func modelParams() -> llama_model_params {
    var p = llama_model_default_params()
    #if targetEnvironment(simulator)
    p.n_gpu_layers = 0   // the simulator has no usable Metal GPU: everything runs on CPU
    #endif
    return p
}

private func tokenize(_ vocab: OpaquePointer, _ text: String, addSpecial: Bool) -> [llama_token] {
    let n = Int32(text.utf8.count)
    var toks = [llama_token](repeating: 0, count: Int(n) + 8)
    var k = llama_tokenize(vocab, text, n, &toks, Int32(toks.count), addSpecial, true)
    if k < 0 {
        toks = [llama_token](repeating: 0, count: Int(-k))
        k = llama_tokenize(vocab, text, n, &toks, Int32(toks.count), addSpecial, true)
    }
    return Array(toks.prefix(Int(max(k, 0))))
}

private func addToken(_ batch: inout llama_batch, _ token: llama_token, _ pos: Int32, output: Bool) {
    let i = Int(batch.n_tokens)
    batch.token[i] = token
    batch.pos[i] = pos
    batch.n_seq_id[i] = 1
    batch.seq_id[i]![0] = 0
    batch.logits[i] = output ? 1 : 0
    batch.n_tokens += 1
}

// MARK: - Model that writes

struct Metrics {
    var inputTokens = 0          // message tokens (system + question with guides)
    var reusedTokens = 0     // system message tokens that were already read
    var timeToFirstToken: Double = 0 // seconds from starting to read until the first token
    var outputTokens = 0
    var writingSeconds: Double = 0
    var tokensPerSecond: Double { writingSeconds > 0 ? Double(outputTokens) / writingSeconds : 0 }
}

final class LlamaGenerator {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private var batch: llama_batch
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private var cachedPrefix: [llama_token] = []   // system message already read: reused between questions
    private let nCtx: Int32 = 4096
    private let nBatch: Int32 = 512

    init(path: String) throws {
        LlamaBackend.start()
        guard let m = llama_model_load_from_file(path, modelParams()) else { throw LlamaError.model(path) }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(nCtx)
        cp.n_batch = UInt32(nBatch)
        cp.n_ubatch = UInt32(nBatch)
        cp.n_threads = threadCount()
        cp.n_threads_batch = threadCount()
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw LlamaError.context }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        batch = llama_batch_init(nBatch, 0, 1)
        sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())   // temperature 0, as in the evaluation
    }

    deinit {
        llama_sampler_free(sampler)
        llama_batch_free(batch)
        llama_free(ctx)
        llama_model_free(model)
    }

    private func read(_ toks: [llama_token], from pos0: Int, outputAtEnd: Bool) throws {
        var i = 0
        while i < toks.count {
            let end = min(i + Int(nBatch), toks.count)
            batch.n_tokens = 0
            for j in i..<end {
                addToken(&batch, toks[j], Int32(pos0 + j), output: outputAtEnd && j == toks.count - 1)
            }
            if llama_decode(ctx, batch) != 0 { throw LlamaError.read }
            i = end
        }
    }

    private func piece(_ t: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }

    /// Same format as the Ministral 3 template in Ollama: <s>[SYSTEM_PROMPT]…[/SYSTEM_PROMPT][INST]…[/INST]
    func generate(system: String, user: String, maxTokens: Int = 256, onToken: (String) -> Void) throws -> Metrics {
        var m = Metrics()
        let t0 = Date()
        let pref = tokenize(vocab, "[SYSTEM_PROMPT]" + system + "[/SYSTEM_PROMPT]", addSpecial: true)
        let remaining = tokenize(vocab, "[INST]" + user + "[/INST]", addSpecial: false)
        let memory = llama_get_memory(ctx)
        if !cachedPrefix.isEmpty && pref == cachedPrefix {
            _ = llama_memory_seq_rm(memory, 0, Int32(pref.count), -1)   // removes only the previous question
            m.reusedTokens = pref.count
        } else {
            llama_memory_clear(memory, true)
            cachedPrefix = []
            try read(pref, from: 0, outputAtEnd: false)
            cachedPrefix = pref
        }
        do {
            try read(remaining, from: pref.count, outputAtEnd: true)
        } catch {
            cachedPrefix = []   // memory is left in an uncertain state: everything is reread next time
            throw error
        }
        m.inputTokens = pref.count + remaining.count

        var pos = Int32(m.inputTokens)
        var pending: [UInt8] = []
        var writingStart = Date()
        for _ in 0..<maxTokens {
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            if m.outputTokens == 0 {
                m.timeToFirstToken = Date().timeIntervalSince(t0)
                writingStart = Date()
            }
            m.outputTokens += 1
            pending += piece(tok)
            if let s = String(bytes: pending, encoding: .utf8) {   // wait for complete UTF-8 characters
                onToken(s)
                pending = []
            }
            if pos >= nCtx - 1 { break }
            batch.n_tokens = 0
            addToken(&batch, tok, pos, output: true)
            pos += 1
            if llama_decode(ctx, batch) != 0 { cachedPrefix = []; throw LlamaError.read }
        }
        m.writingSeconds = m.outputTokens > 0 ? Date().timeIntervalSince(writingStart) : 0
        return m
    }
}

// MARK: - Model that turns text into vectors (EmbeddingGemma)

final class LlamaEmbedder {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let dimension: Int
    private let maxTokens = 1024

    init(path: String) throws {
        LlamaBackend.start()
        guard let m = llama_model_load_from_file(path, modelParams()) else { throw LlamaError.model(path) }
        var cp = llama_context_default_params()
        cp.embeddings = true
        cp.n_ctx = UInt32(maxTokens)
        cp.n_batch = UInt32(maxTokens)
        cp.n_ubatch = UInt32(maxTokens)   // embedding models read the whole sentence at once
        cp.n_threads = threadCount()
        cp.n_threads_batch = threadCount()
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw LlamaError.context }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        let output = Int(llama_model_n_embd_out(m))
        dimension = output > 0 ? output : Int(llama_model_n_embd(m))
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    /// Normalized vector (length 1), like those in rag/index.json.
    func vector(_ text: String) throws -> [Float] {
        let toks = Array(tokenize(vocab, text, addSpecial: true).prefix(maxTokens))
        var b = llama_batch_init(Int32(toks.count), 0, 1)
        defer { llama_batch_free(b) }
        for (i, t) in toks.enumerated() { addToken(&b, t, Int32(i), output: true) }
        if let memory = llama_get_memory(ctx) { llama_memory_clear(memory, true) }
        var r = llama_encode(ctx, b)
        if r != 0 { r = llama_decode(ctx, b) }
        guard r == 0, let p = llama_get_embeddings_seq(ctx, 0) else { throw LlamaError.vector }
        var v = Array(UnsafeBufferPointer(start: p, count: dimension))
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { v = v.map { $0 / norm } }
        return v
    }
}
