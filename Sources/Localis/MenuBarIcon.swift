import AppKit

/// Ícono de la barra de menú: la gota de Localis con la «L» de nodos conectados,
/// dibujada como imagen template para que macOS la tiña según el tema.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()

            // Contorno de la gota: punta arriba, cuerpo redondo abajo.
            let center = NSPoint(x: 9, y: 6.4)
            let radius: CGFloat = 5.4
            let drop = NSBezierPath()
            drop.move(to: NSPoint(x: 9, y: 16.3))
            drop.curve(to: NSPoint(x: center.x + radius, y: center.y),
                       controlPoint1: NSPoint(x: 10.4, y: 14.0),
                       controlPoint2: NSPoint(x: center.x + radius, y: 10.6))
            drop.appendArc(withCenter: center, radius: radius,
                           startAngle: 0, endAngle: 180, clockwise: true)
            drop.curve(to: NSPoint(x: 9, y: 16.3),
                       controlPoint1: NSPoint(x: center.x - radius, y: 10.6),
                       controlPoint2: NSPoint(x: 7.6, y: 14.0))
            drop.close()
            drop.lineWidth = 1.3
            drop.lineJoinStyle = .round
            drop.stroke()

            // «L» de red: nodos unidos por líneas.
            let nodes = [NSPoint(x: 7.4, y: 10.9), NSPoint(x: 7.4, y: 7.6),
                         NSPoint(x: 7.4, y: 4.3), NSPoint(x: 10.0, y: 4.3),
                         NSPoint(x: 11.6, y: 6.1)]
            let links = NSBezierPath()
            links.move(to: nodes[0])
            for node in nodes.dropFirst() { links.line(to: node) }
            links.lineWidth = 0.8
            links.lineJoinStyle = .round
            links.stroke()

            for node in nodes {
                NSBezierPath(ovalIn: NSRect(x: node.x - 0.85, y: node.y - 0.85,
                                            width: 1.7, height: 1.7)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Localis"
        return image
    }
}
