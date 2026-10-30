import Foundation

/// Tarea predefinida que aparece como botón en la ventana.
struct TaskTemplate: Identifiable {
    let id: String
    let title: String
    let icon: String
    let prompt: String
    /// true: se ejecuta de inmediato sobre el archivo adjunto.
    /// false: rellena el campo con un comienzo de frase y espera tu texto.
    let forFile: Bool

    static let all: [TaskTemplate] = [
        // Con archivo adjunto
        TaskTemplate(id: "resumir", title: "Resumir", icon: "text.alignleft",
                     prompt: "Haz un resumen claro y breve del contenido.",
                     forFile: true),
        TaskTemplate(id: "puntos", title: "Puntos clave", icon: "list.bullet",
                     prompt: "Lista los 5 a 7 puntos clave del contenido, en viñetas cortas.",
                     forFile: true),
        TaskTemplate(id: "facil", title: "Explicar fácil", icon: "lightbulb",
                     prompt: "Explica el contenido con palabras simples, como si se lo contaras a alguien sin conocimientos del tema.",
                     forFile: true),
        TaskTemplate(id: "codigo", title: "Revisar código", icon: "chevron.left.forwardslash.chevron.right",
                     prompt: "Este archivo es código. Explica qué hace, señala posibles errores y sugiere mejoras de legibilidad.",
                     forFile: true),
        TaskTemplate(id: "datos", title: "Datos clave", icon: "number",
                     prompt: "Extrae las fechas, nombres, cifras y montos más importantes, en una lista.",
                     forFile: true),

        // Sin archivo: el usuario completa la frase
        TaskTemplate(id: "trad-en", title: "Traducir al inglés", icon: "globe",
                     prompt: "Traduce al inglés: ", forFile: false),
        TaskTemplate(id: "trad-es", title: "Traducir al español", icon: "character.bubble",
                     prompt: "Traduce al español: ", forFile: false),
        TaskTemplate(id: "corregir", title: "Corregir", icon: "textformat.abc",
                     prompt: "Corrige la ortografía y la gramática de este texto, sin cambiar su sentido: ",
                     forFile: false),
        TaskTemplate(id: "correo", title: "Redactar correo", icon: "envelope",
                     prompt: "Redacta un correo breve y profesional sobre: ",
                     forFile: false),
        TaskTemplate(id: "explicar", title: "Explicar", icon: "questionmark.bubble",
                     prompt: "Explica con palabras simples: ",
                     forFile: false)
    ]
}

/// Cómo se procesa un archivo que no cabe en el contexto del modelo.
enum FileMode: String, CaseIterable, Identifiable {
    case auto
    case full
    case search

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automático"
        case .full: return "Leer todo"
        case .search: return "Buscar"
        }
    }

    var help: String {
        switch self {
        case .auto: return "Resúmenes y plantillas leen todo; las preguntas concretas buscan los fragmentos relevantes"
        case .full: return "Lee el archivo completo por partes (más lento, cubre todo)"
        case .search: return "Busca los fragmentos relacionados con tu pregunta (mucho más rápido)"
        }
    }
}
