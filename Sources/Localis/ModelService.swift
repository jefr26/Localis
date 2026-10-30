import Foundation
import FoundationModels
import Observation

struct AttachedFile {
    let url: URL
    let text: String
    let truncated: Bool

    var name: String { url.lastPathComponent }
    var characters: Int { text.count }
}

@MainActor
@Observable
final class ModelService {
    var prompt = ""
    var response = ""
    var errorMessage: String?
    var isGenerating = false
    var status: String?
    var lastInfo: String?
    var attachment: AttachedFile?
    /// Modo rápido: en archivos largos lee solo una muestra repartida de partes.
    var fastMode = false
    /// Cómo se procesa un archivo largo: leer todo, buscar fragmentos o automático.
    var fileMode: FileMode = .auto
    /// Se incrementa cada vez que el panel se muestra, para devolver el foco al campo.
    var focusRequest = 0

    private var task: Task<Void, Never>?
    private let model = SystemLanguageModel.default

    /// Partes que se procesan a la vez. Si ves errores o no mejora el tiempo, ponlo en 1.
    private static let parallelism = 2
    /// Partes que se leen en modo rápido.
    private static let sampleChunks = 4
    /// Máximo de tokens de fragmentos que se envían al modelo en modo búsqueda.
    private static let retrievalTokens = 3500

    private let instructions = """
        Eres Localis, un asistente que corre localmente en el Mac del usuario. \
        Responde en el mismo idioma del usuario, de forma clara y breve.
        """
    private let defaultTask = "Haz un resumen claro y breve del contenido."

    // MARK: - Disponibilidad

    /// nil si el modelo está listo; si no, un mensaje para mostrar al usuario.
    var availabilityMessage: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Este Mac no es compatible con Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Activa Apple Intelligence en Ajustes del Sistema."
            case .modelNotReady:
                return "El modelo aún se está descargando. Inténtalo en unos minutos."
            default:
                return "El modelo no está disponible."
            }
        }
    }

    // MARK: - Conteo de tokens (con comprobación de versión)

    /// Conteo exacto en macOS 26.4 o posterior; en versiones anteriores, una
    /// estimación conservadora (3 caracteres por token) para no pasarse del contexto.
    private func tokens(_ text: String) async throws -> Int {
        if #available(macOS 26.4, *) {
            return try await model.tokenCount(for: text)
        }
        return max(1, Int((Double(text.count) / 3.0).rounded(.up)))
    }

    // MARK: - Archivos adjuntos

    func attach(_ url: URL) {
        errorMessage = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FileReader.read(url)
                }.value
                attachment = AttachedFile(url: url, text: result.text,
                                          truncated: result.truncated)
            } catch {
                attachment = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func removeAttachment() {
        attachment = nil
    }

    // MARK: - Acciones

    func send(mode: FileMode? = nil) {
        let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating, availabilityMessage == nil,
              !typed.isEmpty || attachment != nil else { return }

        let userTask = typed.isEmpty ? defaultTask : typed
        let file = attachment
        let chosenMode = mode ?? fileMode
        let hasTyped = !typed.isEmpty

        response = ""
        errorMessage = nil
        lastInfo = nil
        status = nil
        isGenerating = true
        let start = Date()

        task = Task {
            do {
                var info = ""
                if let file {
                    info = try await runWithFile(file, task: userTask,
                                                 mode: chosenMode, typed: hasTyped)
                } else {
                    try await stream(prompt: userTask)
                }
                let secs = String(format: "%.1f s", Date().timeIntervalSince(start))
                lastInfo = info.isEmpty ? secs : "\(info) · \(secs)"
            } catch is CancellationError {
                // El usuario pulsó Detener.
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize:
                    errorMessage = "El texto es demasiado largo para el modelo (límite de contexto)."
                case .guardrailViolation:
                    errorMessage = "El modelo no puede responder a esta petición."
                default:
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            status = nil
            isGenerating = false
        }
    }

    func stop() {
        task?.cancel()
    }

    func clear() {
        stop()
        prompt = ""
        response = ""
        errorMessage = nil
        lastInfo = nil
        status = nil
        attachment = nil
    }

    // MARK: - Generación

    /// Respuesta en streaming con una sesión nueva (sin historial).
    private func stream(prompt: String) async throws {
        let session = LanguageModelSession(instructions: instructions)
        for try await partial in session.streamResponse(to: prompt) {
            response = partial.content
        }
    }

    /// Ejecuta una plantilla. Con archivo adjunto la lanza de inmediato (leyendo todo
    /// el archivo); sin archivo, rellena el campo y espera a que escribas tu texto.
    func runTemplate(_ template: TaskTemplate) {
        prompt = template.prompt
        if template.forFile && attachment != nil {
            send(mode: .full)
        } else {
            focusRequest += 1
        }
    }

    /// Plantillas que se muestran según haya o no un archivo adjunto.
    var availableTemplates: [TaskTemplate] {
        TaskTemplate.all.filter { $0.forFile == (attachment != nil) }
    }

    /// Procesa un archivo. Si cabe en el contexto, lo envía entero. Si es largo:
    /// - «Leer todo»: lo divide en partes, extrae notas de cada una y responde con ellas.
    /// - «Buscar»: localiza los fragmentos más relevantes y responde solo con ellos.
    /// Devuelve una etiqueta de lo que se hizo, para mostrar en la interfaz.
    private func runWithFile(_ file: AttachedFile, task userTask: String,
                             mode: FileMode, typed: Bool) async throws -> String {
        let contextSize = model.contextSize  // disponible desde macOS 26.0
        let instructionTokens = try await tokens(instructions)
        let taskTokens = try await tokens(userTask)
        // Reserva para la plantilla del prompt, la respuesta y un margen de seguridad.
        let budget = max(contextSize - instructionTokens - taskTokens - 1400, 600)

        status = "Preparando el archivo…"
        let wholeTokens = try await tokens(file.text)
        try Task.checkCancellation()

        // Caso simple: todo cabe en una sola consulta.
        if wholeTokens <= budget {
            status = "Generando…"
            try await stream(prompt: filePrompt(file.name, file.text, userTask))
            return ""
        }

        // Archivo largo: ¿leer todo o buscar fragmentos?
        let effective: FileMode
        if mode == .auto {
            effective = (typed && !looksLikeOverview(userTask)) ? .search : .full
        } else {
            effective = mode
        }

        if effective == .search {
            if let label = try await runRetrieval(file, question: userTask, budget: budget) {
                return label
            }
            if mode == .search {
                response = "No encontré fragmentos relacionados con tu pregunta. Prueba con otras palabras o usa «Leer todo»."
                return "sin coincidencias"
            }
            // En automático, si la búsqueda no encuentra nada, se lee todo.
        }

        let chunks = try await split(file.text, budget: budget)
        try Task.checkCancellation()

        if chunks.count == 1 {
            status = "Generando…"
            try await stream(prompt: filePrompt(file.name, chunks[0], userTask))
            return ""
        }

        // Qué partes se leen: todas, o una muestra repartida en modo rápido.
        let selected = fastMode
            ? sampleIndices(count: chunks.count, take: Self.sampleChunks)
            : Array(chunks.indices)
        let sampled = selected.count < chunks.count

        // Fase 1 (map): notas de cada parte, con paralelismo limitado.
        var notes = try await mapChunks(chunks, indices: selected,
                                        name: file.name, task: userTask)

        // Fase 2 (reduce): si las notas no caben, se condensan por grupos.
        var combined = joinNotes(notes)
        var round = 0
        while round < 3 {
            let count = try await tokens(combined)
            if count <= budget { break }
            round += 1
            let groups = try await split(combined, budget: budget)
            var condensed: [String] = []
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                status = "Condensando notas (\(index + 1)/\(groups.count))…"
                condensed.append(try await condense(group, task: userTask))
            }
            notes = condensed
            combined = joinNotes(notes)
        }

        // Respuesta final en streaming.
        try Task.checkCancellation()
        status = "Generando respuesta final…"
        let origin = sampled
            ? "El archivo es muy largo: solo se leyeron \(selected.count) de \(chunks.count) partes, repartidas a lo largo del archivo (una muestra)."
            : "El archivo se leyó completo en \(chunks.count) partes."
        let finalPrompt = """
            A continuación hay notas de un archivo llamado «\(file.name)». \(origin)

            \(combined)

            Con base en esas notas, cumple esta tarea: \(userTask)
            """
        try await stream(prompt: finalPrompt)
        return sampled
            ? "\(selected.count) de \(chunks.count) partes (muestra)"
            : "\(chunks.count) partes"
    }

    private func filePrompt(_ name: String, _ body: String, _ task: String) -> String {
        """
        Archivo: «\(name)»
        ---
        \(body)
        ---
        Tarea: \(task)
        """
    }

    /// Modo búsqueda: elige los fragmentos más relevantes para la pregunta y
    /// responde solo con ellos (una única llamada al modelo). Devuelve nil si
    /// ningún fragmento coincide con la pregunta.
    private func runRetrieval(_ file: AttachedFile, question: String,
                              budget: Int) async throws -> String? {
        status = "Buscando fragmentos relevantes…"
        let text = file.text
        let found = await Task.detached(priority: .userInitiated) {
            () -> (passages: [String], ranking: [Retrieval.Ranked]) in
            let passages = Retrieval.passages(from: text)
            return (passages, Retrieval.rank(query: question, passages: passages))
        }.value
        try Task.checkCancellation()

        let passages = found.passages
        guard let best = found.ranking.first else { return nil }

        // Se eligen los mejores hasta llenar el presupuesto (3 caracteres por token,
        // estimación conservadora), descartando los poco relacionados.
        let charCap = min(budget, Self.retrievalTokens) * 3
        var chosen: [Int] = []
        var used = 0
        for item in found.ranking {
            if item.score < best.score * 0.3 { break }
            let length = passages[item.index].count + 24
            if used + length > charCap { continue }
            chosen.append(item.index)
            used += length
            if chosen.count >= 12 { break }
        }
        guard !chosen.isEmpty else { return nil }
        chosen.sort()  // orden original del documento

        let context = chosen
            .map { "[Fragmento \($0 + 1) de \(passages.count)]\n\(passages[$0])" }
            .joined(separator: "\n\n")
        let prompt = """
            Fragmentos del archivo «\(file.name)» más relacionados con la pregunta \
            (no es el archivo completo):

            \(context)

            ---
            Pregunta: \(question)
            Responde usando solo la información de los fragmentos. Si la respuesta \
            no está en ellos, dilo claramente.
            """
        status = "Generando…"
        try await stream(prompt: prompt)
        return "búsqueda · \(chosen.count) de \(passages.count) fragmentos"
    }

    /// ¿La petición pide una visión general (resumen) en vez de una pregunta concreta?
    private func looksLikeOverview(_ task: String) -> Bool {
        let folded = task.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let keys = ["resum", "puntos clave", "de que trata", "de que se trata", "sintesis",
                    "idea principal", "ideas principales", "overview", "summar", "key points"]
        return keys.contains { folded.contains($0) }
    }

    /// Extrae notas de las partes indicadas, procesando varias a la vez.
    /// Mantiene el orden original del archivo.
    private func mapChunks(_ chunks: [String], indices: [Int],
                           name: String, task userTask: String) async throws -> [String] {
        var results = [String](repeating: "", count: indices.count)
        var done = 0
        status = "Leyendo partes (0/\(indices.count))…"

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            let limit = min(Self.parallelism, indices.count)

            while next < limit {
                let slot = next
                let chunkIndex = indices[slot]
                let text = chunks[chunkIndex]
                let total = chunks.count
                group.addTask {
                    let note = try await self.extractNotesRetrying(
                        text, index: chunkIndex + 1, total: total,
                        name: name, task: userTask)
                    return (slot, note)
                }
                next += 1
            }

            for try await (slot, note) in group {
                results[slot] = note
                done += 1
                status = "Leyendo partes (\(done)/\(indices.count))…"

                if next < indices.count {
                    let newSlot = next
                    let chunkIndex = indices[newSlot]
                    let text = chunks[chunkIndex]
                    let total = chunks.count
                    group.addTask {
                        let note = try await self.extractNotesRetrying(
                            text, index: chunkIndex + 1, total: total,
                            name: name, task: userTask)
                        return (newSlot, note)
                    }
                    next += 1
                }
            }
        }
        return results
    }

    /// Reintenta una vez si la llamada falla (por ejemplo, por concurrencia).
    private func extractNotesRetrying(_ text: String, index: Int, total: Int,
                                      name: String, task: String) async throws -> String {
        do {
            return try await extractNotes(text, index: index, total: total,
                                          name: name, task: task)
        } catch let error as CancellationError {
            throw error
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error { throw error }
            try await Task.sleep(for: .seconds(1))
            return try await extractNotes(text, index: index, total: total,
                                          name: name, task: task)
        }
    }

    private func extractNotes(_ text: String, index: Int, total: Int,
                              name: String, task: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
            Parte \(index) de \(total) del archivo «\(name)». \
            Extrae solo la información relevante para esta tarea: \(task)
            Responde con notas muy breves (máximo 80 palabras).
            ---
            \(text)
            ---
            """
        do {
            let result = try await session.respond(
                to: prompt, options: GenerationOptions(maximumResponseTokens: 220))
            return result.content
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error {
                return "(parte omitida por el filtro de contenido del modelo)"
            }
            throw error
        }
    }

    private func condense(_ notes: String, task: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
            Condensa estas notas en menos de 100 palabras, conservando lo \
            relevante para esta tarea: \(task)
            ---
            \(notes)
            ---
            """
        let result = try await session.respond(
            to: prompt, options: GenerationOptions(maximumResponseTokens: 260))
        return result.content
    }

    private func joinNotes(_ notes: [String]) -> String {
        notes.enumerated()
            .map { "Parte \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n\n")
    }

    /// Elige `take` posiciones repartidas de forma uniforme (siempre incluye la
    /// primera y la última parte).
    private func sampleIndices(count: Int, take: Int) -> [Int] {
        guard take >= 2, count > take else { return Array(0..<count) }
        return (0..<take).map {
            Int((Double($0) * Double(count - 1) / Double(take - 1)).rounded())
        }
    }

    // MARK: - División por tokens

    /// Divide el texto en trozos que caben en `budget` tokens, cortando en
    /// límites naturales (párrafo, línea o fin de frase).
    private func split(_ text: String, budget: Int) async throws -> [String] {
        let total = try await tokens(text)
        if total <= budget || text.count < 2 { return [text] }

        let parts = max(2, Int((Double(total) / Double(budget)).rounded(.up)))
        let pieces = cut(text, into: parts)
        if pieces.count < 2 { return [text] }  // no se puede dividir más

        var result: [String] = []
        for piece in pieces {
            try Task.checkCancellation()
            let count = try await tokens(piece)
            if count <= budget {
                result.append(piece)
            } else {
                result += try await split(piece, budget: budget)
            }
        }
        return result
    }

    /// Corta el texto en `n` trozos de tamaño parecido, buscando hacia atrás
    /// un salto de párrafo, de línea o un fin de frase cerca de cada corte.
    private func cut(_ text: String, into n: Int) -> [String] {
        let chars = Array(text)
        var pieces: [String] = []
        var start = 0

        for i in 1..<n {
            let target = chars.count * i / n
            let lowerBound = max(start + 1, target - chars.count / (n * 5))
            var cutAt = target
            var found = false

            for marker in [["\n", "\n"], ["\n"], [".", " "]] as [[Character]] {
                var j = target
                while j > lowerBound {
                    if matches(chars, endingAt: j, marker: marker) {
                        cutAt = j
                        found = true
                        break
                    }
                    j -= 1
                }
                if found { break }
            }

            if cutAt > start {
                pieces.append(String(chars[start..<cutAt]))
                start = cutAt
            }
        }
        pieces.append(String(chars[start...]))
        return pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func matches(_ chars: [Character], endingAt end: Int, marker: [Character]) -> Bool {
        let begin = end - marker.count
        guard begin >= 0, end <= chars.count else { return false }
        return Array(chars[begin..<end]) == marker
    }
}
