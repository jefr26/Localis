import Foundation

/// Búsqueda léxica (BM25) sobre fragmentos de un archivo. Corre 100% local, sin
/// modelo: sirve para localizar las partes relevantes de un documento largo y
/// enviar solo esas al modelo en lugar de leerlo entero.
enum Retrieval {
    struct Ranked {
        let index: Int
        let score: Double
    }

    /// Palabras muy comunes (español e inglés) que no ayudan a distinguir fragmentos.
    private static let stopwords: Set<String> = [
        "el", "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "al", "en", "y", "o", "u",
        "que", "se", "su", "sus", "por", "para", "con", "sin", "sobre", "es", "son", "fue", "ser",
        "como", "mas", "pero", "si", "no", "lo", "le", "les", "me", "mi", "tu", "te", "nos",
        "este", "esta", "estos", "estas", "ese", "esa", "eso", "cual", "cuales", "cuando", "donde",
        "quien", "quienes", "cuanto", "hay", "ha", "han",
        "the", "an", "of", "to", "in", "and", "or", "is", "are", "was", "were", "be", "for", "on",
        "with", "as", "by", "at", "from", "this", "it", "its", "what", "which", "who", "when",
        "where", "how", "do", "does", "did"
    ]

    // MARK: - Fragmentos

    /// Divide el texto en fragmentos de ~1.200 a 1.600 caracteres, respetando
    /// los saltos de línea cuando es posible.
    static func passages(from text: String, target: Int = 1200, maxChars: Int = 1600) -> [String] {
        var atoms: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.count > maxChars {
                atoms += splitLong(trimmed, limit: target)
            } else {
                atoms.append(trimmed)
            }
        }

        var result: [String] = []
        var current = ""
        for atom in atoms {
            if !current.isEmpty && current.count + atom.count + 1 > maxChars {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + atom
            if current.count >= target {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Parte una línea muy larga en trozos por palabras.
    private static func splitLong(_ text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if !current.isEmpty && current.count + word.count + 1 > limit {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + word
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: - Términos

    /// Minúsculas, sin acentos, sin palabras vacías y recortadas a 5 letras para
    /// que "aprobado" y "aprobó", o "entrega" y "entregar", coincidan.
    static func terms(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result: [String] = []
        for word in folded.components(separatedBy: CharacterSet.alphanumerics.inverted) {
            guard word.count >= 2, !stopwords.contains(word) else { continue }
            result.append(String(word.prefix(5)))
        }
        return result
    }

    // MARK: - Ranking BM25

    /// Fragmentos que contienen alguna palabra de la consulta, de más a menos
    /// relevante. Lista vacía si ninguno coincide.
    static func rank(query: String, passages: [String]) -> [Ranked] {
        let queryTerms = Set(terms(query))
        guard !queryTerms.isEmpty, !passages.isEmpty else { return [] }

        let docs = passages.map { terms($0) }
        let n = Double(docs.count)
        let averageLength = max(1.0, Double(docs.reduce(0) { $0 + $1.count }) / n)

        var documentFrequency: [String: Int] = [:]
        for doc in docs {
            for term in Set(doc) where queryTerms.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }

        let k1 = 1.5
        let b = 0.75
        var ranked: [Ranked] = []

        for (index, doc) in docs.enumerated() {
            var frequency: [String: Int] = [:]
            for term in doc where queryTerms.contains(term) {
                frequency[term, default: 0] += 1
            }
            if frequency.isEmpty { continue }

            var score = 0.0
            for (term, count) in frequency {
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let tf = Double(count)
                let lengthNorm = 1 - b + b * Double(doc.count) / averageLength
                score += idf * tf * (k1 + 1) / (tf + k1 * lengthNorm)
            }
            ranked.append(Ranked(index: index, score: score))
        }
        return ranked.sorted { $0.score > $1.score }
    }
}
