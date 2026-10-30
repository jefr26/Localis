import Foundation
import AppKit
import PDFKit

enum FileReaderError: LocalizedError {
    case unsupported(String)
    case empty
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext):
            return ext.isEmpty
                ? String(localized: "No puedo leer este archivo.")
                : String(localized: "No puedo leer archivos .\(ext).")
        case .empty:
            return String(localized: "No encontré texto en el archivo (¿es un PDF escaneado?).")
        case .tooLarge:
            return String(localized: "El archivo es demasiado grande (máximo 20 MB).")
        }
    }
}

enum FileReader {
    static let maxCharacters = 300_000
    static let maxBytes = 20_000_000

    /// Devuelve el texto del archivo y si hubo que truncarlo.
    static func read(_ url: URL) throws -> (text: String, truncated: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxBytes {
            throw FileReaderError.tooLarge
        }

        let ext = url.pathExtension.lowercased()
        var text: String

        switch ext {
        case "pdf":
            guard let document = PDFDocument(url: url) else {
                throw FileReaderError.unsupported(ext)
            }
            text = document.string ?? ""

        case "rtf", "rtfd", "doc", "docx", "odt":
            guard let attributed = try? NSAttributedString(
                url: url, options: [:], documentAttributes: nil) else {
                throw FileReaderError.unsupported(ext)
            }
            text = attributed.string

        default:
            // Texto plano, Markdown, código, JSON, CSV, HTML, etc.
            let data = try Data(contentsOf: url)
            if data.prefix(4096).contains(0) {
                throw FileReaderError.unsupported(ext)  // parece binario
            }
            if let utf8 = String(data: data, encoding: .utf8) {
                text = utf8
            } else if let latin = String(data: data, encoding: .isoLatin1) {
                text = latin
            } else {
                throw FileReaderError.unsupported(ext)
            }
        }

        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FileReaderError.empty
        }

        if text.count > maxCharacters {
            return (String(text.prefix(maxCharacters)), true)
        }
        return (text, false)
    }
}
