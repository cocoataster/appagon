import Foundation
import SwiftUI
import UIKit

// Ties the pieces together: pipeline (rules, calculators, search) + the two llama.cpp models.
// All heavy work happens in the Engine actor, off the UI thread.

enum Resources {
    // Only the lightweight data ships in the app (~5 MB): guide index, rules and test cases.
    // The models are downloaded on first use (Models.swift).
    static var folder: URL { Bundle.main.resourceURL!.appendingPathComponent("Contenido") }
    static var data: URL { folder.appendingPathComponent("datos") }
}

actor Engine {
    let pipeline: Pipeline
    private let generator: LlamaGenerator
    private let embedder: LlamaEmbedder

    init(generator generatorPath: URL, embedder embedderPath: URL) throws {
        pipeline = try Pipeline(folder: Resources.data)
        embedder = try LlamaEmbedder(path: embedderPath.path)
        generator = try LlamaGenerator(path: generatorPath.path)
    }

    func prepare(_ q: String) throws -> PreparedPrompt {
        let v = try embedder.vector(pipeline.queryText(q))
        return pipeline.prepare(q, chunks: pipeline.retrieve(v))
    }

    func respond(_ prepared: PreparedPrompt, onToken: @escaping (String) -> Void) throws -> Metrics {
        try generator.generate(system: pipeline.data.systemPrompt, user: prepared.user, onToken: onToken)
    }

    func clean(_ t: String) -> String { pipeline.clean(t) }

    func missingFigures(_ answer: String, _ calculations: [String]) -> [String] {
        pipeline.missingFigures(answer: answer, calculations: calculations)
    }

    /// Compares the app with Python: rules, calculators and synonyms (all questions) and search (the first 40).
    func selfCheck() throws -> String {
        let cases = try JSONDecoder().decode([TestCase].self, from: Data(contentsOf: Resources.data.appendingPathComponent("casos.json")))
        var text = Verification.pureLogic(pipeline, cases).text
        text += "\n\n" + Verification.safetyNet(pipeline).text
        let withSearch = cases.filter { $0.top != nil }.prefix(40)
        if !withSearch.isEmpty {
            var matching = 0, total = 0, identical = 0
            for c in withSearch {
                let ours = Set(pipeline.retrieve(try embedder.vector(pipeline.queryText(c.q))))
                let theirs = Set(c.top ?? [])
                matching += ours.intersection(theirs).count
                total += theirs.count
                if ours == theirs { identical += 1 }
            }
            text += "\n\nBúsqueda en las guías (\(withSearch.count) preguntas): \(matching) de \(total) trozos iguales que con Ollama"
            text += " (\(identical) preguntas con los 6 trozos idénticos). Pequeñas diferencias son normales: el vector se calcula con llama.cpp y no con Ollama."
        }
        return text
    }
}

@MainActor
final class Assistant: ObservableObject {
    enum Status: Equatable {
        case loading, ready, searching, reading(since: Date), writing, error(String)
        case modelsMissing, downloading(text: String, fraction: Double), verifying(String)
    }

    @Published var status: Status = .loading
    @Published var question = ""
    @Published var answer = ""
    @Published var calculations: [String] = []
    @Published var sources: [String] = []
    @Published var metrics = ""
    @Published var correction: [String] = []   // calculated figures the model did not pick up correctly
    @Published var verificationReport: String?
    @Published var downloadError: String?
    @Published var pendingSize = ""            // size left to download, as text
    @Published var downloadingID: String?    // the model being downloaded right now

    private var engine: Engine?
    private var needsReload = false   // after a llama failure the context stays broken: every later call would fail too

    func load() async {
        guard engine == nil else { return }
        let list = Models.list()
        guard !list.isEmpty else { status = .error(DownloadError.missingList.localizedDescription); return }
        let missing = Models.pending()
        if !missing.isEmpty {
            pendingSize = Models.sizeText(missing.reduce(0) { $0 + $1.bytes })
            status = .modelsMissing
            return
        }
        guard let g = list.first(where: { $0.id == "generador" }).flatMap(Models.path),
              let v = list.first(where: { $0.id == "vectores" }).flatMap(Models.path) else {
            status = .error(DownloadError.missingList.localizedDescription); return
        }
        status = .loading
        do {
            let m = try await Task.detached(priority: .userInitiated) { try Engine(generator: g, embedder: v) }.value
            engine = m
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Downloads the missing models one after another, with progress; if interrupted, «Reintentar» resumes where it left off.
    private var resumeData: [String: Data] = [:]

    func download() async {
        downloadError = nil
        UIApplication.shared.isIdleTimerDisabled = true   // keep the screen on during the download
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            downloadingID = nil
        }
        let missing = Models.pending()
        let total = missing.reduce(0) { $0 + $1.bytes }
        guard Models.freeSpace() > total + 500_000_000 else {
            downloadError = DownloadError.insufficientSpace(total + 500_000_000 - Models.freeSpace()).localizedDescription
            status = .modelsMissing
            return
        }
        var done: Int64 = 0
        for (i, m) in missing.enumerated() {
            downloadingID = m.id
            let header = "Descargando \(i + 1) de \(missing.count): \(m.name)"
            status = .downloading(text: header, fraction: Double(done) / Double(max(total, 1)))
            let base = done
            let d = Download { written, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let f = Double(base + written) / Double(max(total, 1))
                        self.status = .downloading(text: "\(header)\n\(Models.sizeText(base + written)) de \(Models.sizeText(total))", fraction: f)
                    }
                }
            }
            do {
                guard let url = URL(string: m.url) else { throw DownloadError.missingList }
                let tmp = try await d.run(url, resumeData: resumeData[m.id])
                resumeData[m.id] = nil
                status = .verifying("Comprobando que \(m.name) ha llegado entero…")
                try await Task.detached(priority: .userInitiated) { try Models.install(m, from: tmp) }.value
                done += m.bytes
            } catch {
                if let r = d.pendingResumeData { resumeData[m.id] = r }
                downloadError = error.localizedDescription
                pendingSize = Models.sizeText(Models.pending().reduce(0) { $0 + $1.bytes })
                status = .modelsMissing
                return
            }
        }
        await load()
    }

    /// Deletes the downloaded models (to test the download again).
    func deleteModels() async {
        guard !isBusy || status == .modelsMissing else { return }
        engine = nil
        Models.delete()
        await load()
    }

    var isBusy: Bool {
        switch status {
        case .ready, .error: return false
        default: return true
        }
    }

    /// The models are not on the phone yet: nothing can be asked, so no new chats until the download finishes.
    var needsModels: Bool {
        switch status {
        case .modelsMissing, .downloading, .verifying: return true
        default: return false
        }
    }

    /// Answers and returns the finished message (cleaned, with the safety net applied) to store in the history.
    @discardableResult
    func ask(_ q: String) async -> Message? {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isBusy else { return nil }
        if needsReload {
            needsReload = false
            engine = nil
            await load()
        }
        guard let engine, !isBusy else { return nil }
        question = q
        answer = ""
        calculations = []
        sources = []
        metrics = ""
        correction = []
        status = .searching
        do {
            let t0 = Date()
            let prep = try await engine.prepare(q)
            let searchTime = Date().timeIntervalSince(t0)
            calculations = prep.calculations
            var seen: [String] = []
            for t in prep.chunks where !seen.contains(t.source) { seen.append(t.source) }
            sources = seen
            status = .reading(since: Date())
            let m = try await engine.respond(prep) { chunk in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if case .reading = self.status { self.status = .writing }
                        self.answer += chunk
                    }
                }
            }
            // wait for the last pieces queued on the main thread
            await Task.yield()
            answer = await engine.clean(answer)
            correction = await engine.missingFigures(answer, prep.calculations)   // safety net: exact figures come from code
            metrics = String(format: "Búsqueda %.1f s · 1.ª palabra %.1f s · %.0f tokens/s · %ld tokens leídos (%ld reutilizados) · %ld escritos",
                             searchTime, m.timeToFirstToken, m.tokensPerSecond, m.inputTokens, m.reusedTokens, m.outputTokens)
                .replacingOccurrences(of: ".", with: ",")
                .replacingOccurrences(of: "1,ª", with: "1.ª")
            status = .ready
            return Message(question: q, answer: answer, calculations: calculations, sources: sources,
                           correction: correction, metrics: metrics)
        } catch {
            status = .error(error.localizedDescription)
            needsReload = true
            return nil
        }
    }

    func selfCheck() async {
        guard let engine, !isBusy else { return }
        status = .searching
        do {
            verificationReport = try await engine.selfCheck()
        } catch {
            verificationReport = "Error: \(error.localizedDescription)"
        }
        status = .ready
    }
}
