import Foundation
import FoundationModels
import Observation
import Security

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
    /// Preferencia del usuario: usar Private Cloud Compute cuando esté disponible.
    var usePCC = UserDefaults.standard.bool(forKey: "usePCC") {
        didSet { UserDefaults.standard.set(usePCC, forKey: "usePCC") }
    }

    private var task: Task<Void, Never>?
    private let model = SystemLanguageModel.default
    /// Modelo de Private Cloud Compute (macOS 27 o posterior). Se guarda sin tipo
    /// porque una propiedad almacenada no puede depender de la versión del sistema.
    private let pccStorage: AnyObject? = {
        if #available(macOS 27.0, *) { return PrivateCloudComputeLanguageModel() }
        return nil
    }()
    /// Si la generación en curso usa PCC. Se fija al enviar para no mezclar modelos.
    private var runOnCloud = false
    /// PCC exige el entitlement restringido com.apple.developer.private-cloud-compute,
    /// que solo vale si la app se firma con un perfil de aprovisionamiento. Sin él,
    /// el sistema informa PCC como disponible pero rechaza cada petición.
    private static let hasPCCEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.private-cloud-compute" as CFString, nil)
        return (value as? Bool) == true
    }()

    /// Partes que se procesan a la vez. Si ves errores o no mejora el tiempo, ponlo en 1.
    private static let parallelism = 2
    /// Partes que se leen en modo rápido.
    private static let sampleChunks = 4
    /// Máximo de tokens de fragmentos que se envían al modelo en modo búsqueda.
    private static let retrievalTokens = 3500

    // Los textos para el modelo se traducen como la interfaz: así la petición, las
    // instrucciones y la respuesta quedan en el mismo idioma.
    private let instructions = String(
        localized: "prompt.instructions",
        defaultValue: "Eres Localis, un asistente en el Mac del usuario. Responde en el idioma en que está escrita la petición del usuario, de forma clara y breve.")
    private let defaultTask = String(
        localized: "prompt.defaultTask",
        defaultValue: "Haz un resumen claro y breve del contenido.")

    // MARK: - Disponibilidad

    /// nil si el modelo está listo; si no, un mensaje para mostrar al usuario.
    var availabilityMessage: String? {
        if usingPCC { return nil }
        switch model.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return String(localized: "Este Mac no es compatible con Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return String(localized: "Activa Apple Intelligence en Ajustes del Sistema.")
            case .modelNotReady:
                return String(localized: "El modelo aún se está descargando. Inténtalo en unos minutos.")
            default:
                return String(localized: "El modelo no está disponible.")
            }
        }
    }

    // MARK: - Private Cloud Compute

    @available(macOS 27.0, *)
    private var pcc: PrivateCloudComputeLanguageModel? {
        pccStorage as? PrivateCloudComputeLanguageModel
    }

    /// true si esta copia de la app está firmada con el permiso de PCC.
    var pccEntitled: Bool { Self.hasPCCEntitlement }

    /// true si PCC se puede usar ahora mismo (sistema compatible y cuota disponible).
    var pccAvailable: Bool {
        if #available(macOS 27.0, *), let pcc, Self.hasPCCEntitlement {
            return pcc.isAvailable && !pcc.quotaUsage.isLimitReached
        }
        return false
    }

    /// true si la próxima consulta irá a PCC.
    var usingPCC: Bool { usePCC && pccAvailable }

    /// Texto de ayuda del botón de PCC, con el motivo si no está disponible.
    var pccHelp: String {
        guard #available(macOS 27.0, *), let pcc else {
            return String(localized: "Private Cloud Compute requiere macOS 27 o posterior.")
        }
        guard Self.hasPCCEntitlement else {
            return String(localized: "Esta copia de Localis no tiene el permiso de Private Cloud Compute. Compílala firmada con tu cuenta de desarrollador (ver build_app.sh).")
        }
        if case .unavailable(let reason) = pcc.availability {
            switch reason {
            case .deviceNotEligible:
                return String(localized: "Este Mac no es compatible con Private Cloud Compute.")
            case .systemNotReady:
                return String(localized: "Private Cloud Compute aún no está listo. Revisa Apple Intelligence en Ajustes del Sistema.")
            default:
                return String(localized: "Private Cloud Compute no está disponible.")
            }
        }
        if pcc.quotaUsage.isLimitReached {
            return quotaMessage(pcc.quotaUsage.resetDate)
        }
        return usePCC
            ? String(localized: "Usando Private Cloud Compute (modelo más grande en servidores de Apple)")
            : String(localized: "Usar Private Cloud Compute (modelo más grande en servidores de Apple)")
    }

    private func quotaMessage(_ reset: Date?) -> String {
        guard let reset else {
            return String(localized: "Alcanzaste el límite de uso de Private Cloud Compute.")
        }
        let date = reset.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Alcanzaste el límite de uso de Private Cloud Compute hasta \(date).")
    }

    /// Sesión nueva (sin historial) con el modelo de la generación en curso.
    private func makeSession() -> LanguageModelSession {
        if runOnCloud, #available(macOS 27.0, *), let pcc {
            return LanguageModelSession(model: pcc, instructions: instructions)
        }
        return LanguageModelSession(instructions: instructions)
    }

    private func contextSize() async throws -> Int {
        if runOnCloud, #available(macOS 27.0, *), let pcc {
            return try await pcc.contextSize
        }
        return model.contextSize  // disponible desde macOS 26.0
    }

    // MARK: - Conteo de tokens (con comprobación de versión)

    /// Conteo exacto con el modelo local en macOS 26.4 o posterior; en versiones
    /// anteriores o con PCC (que no ofrece conteo), una estimación conservadora
    /// (3 caracteres por token) para no pasarse del contexto.
    private func tokens(_ text: String) async throws -> Int {
        if !runOnCloud, #available(macOS 26.4, *) {
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
        runOnCloud = usingPCC
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
                var parts = runOnCloud ? ["PCC"] : []
                if !info.isEmpty { parts.append(info) }
                parts.append(secs)
                lastInfo = parts.joined(separator: " · ")
            } catch is CancellationError {
                // El usuario pulsó Detener.
            } catch {
                errorMessage = describe(error)
            }
            status = nil
            isGenerating = false
        }
    }

    func stop() {
        task?.cancel()
    }

    // MARK: - Errores

    /// Mensaje para el usuario. Cubre los errores del modelo local y los de PCC.
    private func describe(_ error: Error) -> String {
        if isContextOverflow(error) {
            return String(localized: "El texto es demasiado largo para el modelo (límite de contexto).")
        }
        if isGuardrail(error) {
            return String(localized: "El modelo no puede responder a esta petición.")
        }
        if #available(macOS 27.0, *) {
            if let error = error as? PrivateCloudComputeLanguageModel.Error {
                switch error {
                case .networkFailure:
                    return String(localized: "No hay conexión con Private Cloud Compute. Revisa tu red o desactiva PCC.")
                case .quotaLimitReached(let info):
                    return quotaMessage(info.resetDate)
                case .serviceUnavailable:
                    return String(localized: "Private Cloud Compute no está disponible en este momento. Inténtalo más tarde o desactiva PCC.")
                default:
                    return error.localizedDescription
                }
            }
            if case LanguageModelError.rateLimited = error {
                return String(localized: "Demasiadas solicitudes seguidas. Espera un momento e inténtalo de nuevo.")
            }
        }
        return error.localizedDescription
    }

    private func isContextOverflow(_ error: Error) -> Bool {
        if case LanguageModelSession.GenerationError.exceededContextWindowSize = error {
            return true
        }
        if #available(macOS 27.0, *), case LanguageModelError.contextSizeExceeded = error {
            return true
        }
        return false
    }

    private func isGuardrail(_ error: Error) -> Bool {
        if case LanguageModelSession.GenerationError.guardrailViolation = error {
            return true
        }
        if #available(macOS 27.0, *), case LanguageModelError.guardrailViolation = error {
            return true
        }
        return false
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
        let session = makeSession()
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
        let context = try await contextSize()
        let instructionTokens = try await tokens(instructions)
        let taskTokens = try await tokens(userTask)
        // Reserva para la plantilla del prompt, la respuesta y un margen de seguridad.
        let budget = max(context - instructionTokens - taskTokens - 1400, 600)

        status = String(localized: "Preparando el archivo…")
        let wholeTokens = try await tokens(file.text)
        try Task.checkCancellation()

        // Caso simple: todo cabe en una sola consulta.
        if wholeTokens <= budget {
            status = String(localized: "Generando…")
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
                response = String(localized: "No encontré fragmentos relacionados con tu pregunta. Prueba con otras palabras o usa «Leer todo».")
                return String(localized: "sin coincidencias")
            }
            // En automático, si la búsqueda no encuentra nada, se lee todo.
        }

        let chunks = try await split(file.text, budget: budget)
        try Task.checkCancellation()

        if chunks.count == 1 {
            status = String(localized: "Generando…")
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
                status = String(localized: "Condensando notas (\(index + 1)/\(groups.count))…")
                condensed.append(try await condense(group, task: userTask))
            }
            notes = condensed
            combined = joinNotes(notes)
        }

        // Respuesta final en streaming.
        try Task.checkCancellation()
        status = String(localized: "Generando respuesta final…")
        let origin = sampled
            ? String(localized: "prompt.origin.sampled", defaultValue: "El archivo es muy largo: solo se leyeron \(selected.count) de \(chunks.count) partes, repartidas a lo largo del archivo (una muestra).")
            : String(localized: "prompt.origin.full", defaultValue: "El archivo se leyó completo en \(chunks.count) partes.")
        let finalPrompt = String(localized: "prompt.final", defaultValue: """
            A continuación hay notas de un archivo llamado «\(file.name)». \(origin)

            \(combined)

            Con base en esas notas, cumple esta tarea: \(userTask)
            """)
        try await stream(prompt: finalPrompt)
        return sampled
            ? String(localized: "\(selected.count) de \(chunks.count) partes (muestra)")
            : String(localized: "\(chunks.count) partes")
    }

    private func filePrompt(_ name: String, _ body: String, _ task: String) -> String {
        String(localized: "prompt.file", defaultValue: """
            Archivo: «\(name)»
            ---
            \(body)
            ---
            Tarea: \(task)
            """)
    }

    /// Modo búsqueda: elige los fragmentos más relevantes para la pregunta y
    /// responde solo con ellos (una única llamada al modelo). Devuelve nil si
    /// ningún fragmento coincide con la pregunta.
    private func runRetrieval(_ file: AttachedFile, question: String,
                              budget: Int) async throws -> String? {
        status = String(localized: "Buscando fragmentos relevantes…")
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
            .map { index in
                let passage = passages[index]
                return String(localized: "prompt.fragment",
                              defaultValue: "[Fragmento \(index + 1) de \(passages.count)]\n\(passage)")
            }
            .joined(separator: "\n\n")
        let prompt = String(localized: "prompt.retrieval", defaultValue: """
            Fragmentos del archivo «\(file.name)» más relacionados con la pregunta \
            (no es el archivo completo):

            \(context)

            ---
            Pregunta: \(question)
            Responde usando solo la información de los fragmentos. Si la respuesta \
            no está en ellos, dilo claramente.
            """)
        status = String(localized: "Generando…")
        try await stream(prompt: prompt)
        return String(localized: "búsqueda · \(chosen.count) de \(passages.count) fragmentos")
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
        status = String(localized: "Leyendo partes (\(0)/\(indices.count))…")

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
                status = String(localized: "Leyendo partes (\(done)/\(indices.count))…")

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

    /// Reintenta una vez si la llamada falla (por ejemplo, por concurrencia o red).
    private func extractNotesRetrying(_ text: String, index: Int, total: Int,
                                      name: String, task: String) async throws -> String {
        do {
            return try await extractNotes(text, index: index, total: total,
                                          name: name, task: task)
        } catch let error as CancellationError {
            throw error
        } catch {
            if isContextOverflow(error) { throw error }
            try await Task.sleep(for: .seconds(1))
            return try await extractNotes(text, index: index, total: total,
                                          name: name, task: task)
        }
    }

    private func extractNotes(_ text: String, index: Int, total: Int,
                              name: String, task: String) async throws -> String {
        let session = makeSession()
        let prompt = String(localized: "prompt.notes", defaultValue: """
            Parte \(index) de \(total) del archivo «\(name)». \
            Extrae solo la información relevante para esta tarea: \(task)
            Responde con notas muy breves (máximo 80 palabras).
            ---
            \(text)
            ---
            """)
        do {
            let result = try await session.respond(
                to: prompt, options: GenerationOptions(maximumResponseTokens: 220))
            return result.content
        } catch {
            if isGuardrail(error) {
                return String(localized: "prompt.skippedPart",
                              defaultValue: "(parte omitida por el filtro de contenido del modelo)")
            }
            throw error
        }
    }

    private func condense(_ notes: String, task: String) async throws -> String {
        let session = makeSession()
        let prompt = String(localized: "prompt.condense", defaultValue: """
            Condensa estas notas en menos de 100 palabras, conservando lo \
            relevante para esta tarea: \(task)
            ---
            \(notes)
            ---
            """)
        let result = try await session.respond(
            to: prompt, options: GenerationOptions(maximumResponseTokens: 260))
        return result.content
    }

    private func joinNotes(_ notes: [String]) -> String {
        notes.enumerated()
            .map { String(localized: "prompt.notePart",
                          defaultValue: "Parte \($0.offset + 1): \($0.element)") }
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
