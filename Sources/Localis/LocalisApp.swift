import SwiftUI
import AppKit

@main
struct LocalisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // La interfaz vive en un panel propio (ver AppDelegate); SwiftUI exige
        // al menos una escena, así que dejamos una vacía.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service = ModelService()
    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // sin ícono en el Dock

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.make()
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        let root = PromptView(service: service, onClose: { [weak self] in
            self?.hidePanel()
        })
        panel = FloatingPanel(rootView: root)
    }

    @objc private func togglePanel() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func showPanel() {
        guard let panel, let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        // Colocar el panel justo debajo del ícono de la barra de menú.
        let iconRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = iconRect.midX - panel.frame.width / 2
        var y = iconRect.minY - panel.frame.height - 6

        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            y = max(y, visible.minY + 8)
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        service.focusRequest += 1
    }
}

/// Panel flotante sin borde. No activa la app ni se oculta al perder el foco,
/// así que permanece abierto mientras arrastras archivos desde Finder.
final class FloatingPanel: NSPanel {
    static let size = NSSize(width: 440, height: 560)

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        contentView = hosting
    }

    // Un panel sin borde no puede recibir teclado a menos que lo permitamos.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Esc cierra el panel.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
