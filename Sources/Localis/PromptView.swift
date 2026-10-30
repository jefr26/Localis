import SwiftUI
import AppKit

struct PromptView: View {
    @Bindable var service: ModelService
    var onClose: () -> Void = {}

    @FocusState private var focused: Bool
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let message = service.availabilityMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            TextField(placeholder, text: $service.prompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { service.send() }
                .disabled(service.availabilityMessage != nil)

            if let file = service.attachment {
                attachmentRow(file)
            }

            templateRow

            controls
            responseArea
        }
        .padding(16)
        .frame(width: FloatingPanel.size.width, height: FloatingPanel.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay { dropOverlay }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            service.attach(url)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .onAppear { focused = true }
        .onChange(of: service.focusRequest) { _, _ in focused = true }
        .onExitCommand { onClose() }
    }

    // MARK: - Partes

    private var placeholder: String {
        service.attachment == nil
            ? String(localized: "¿Qué necesitas?")
            : String(localized: "¿Qué hago con el archivo? (vacío = resumen)")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(nsImage: MenuBarIcon.make())
                .renderingMode(.template)
                .foregroundStyle(.tint)
            Text("Localis").font(.headline)
            (service.usingPCC ? Text(verbatim: "Private Cloud Compute") : Text("100% en tu Mac"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Oculto mientras la app no esté firmada con el permiso de PCC.
            if service.pccEntitled {
                Toggle(isOn: pccBinding) {
                    Label("Private Cloud Compute", systemImage: "cloud")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(!service.pccAvailable || service.isGenerating)
                .help(service.pccHelp)
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Cerrar (Esc)")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Salir de Localis")
        }
    }

    /// Se muestra apagado si PCC no está disponible, aunque la preferencia esté activa.
    private var pccBinding: Binding<Bool> {
        Binding(get: { service.usingPCC }, set: { service.usePCC = $0 })
    }

    private func attachmentRow(_ file: AttachedFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachmentDetail(file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Modo", selection: $service.fileMode) {
                ForEach(FileMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(service.isGenerating)
            .help(service.fileMode.help)
            Button {
                service.removeAttachment()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(service.isGenerating)
            .help("Quitar archivo")
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var templateRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(service.availableTemplates) { template in
                    Button {
                        service.runTemplate(template)
                    } label: {
                        Label(template.title, systemImage: template.icon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(service.isGenerating || service.availabilityMessage != nil)
                }
            }
        }
    }

    private func attachmentDetail(_ file: AttachedFile) -> String {
        let base = String(localized: "\(file.characters.formatted()) caracteres")
        let limit = FileReader.maxCharacters.formatted()
        return file.truncated
            ? String(localized: "\(base) · truncado a \(limit)")
            : base
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if service.isGenerating {
                Button("Detener", systemImage: "stop.fill") { service.stop() }
                ProgressView().controlSize(.small)
                if let status = service.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Button("Enviar", systemImage: "paperplane.fill") { service.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
            Spacer()
            if let info = service.lastInfo {
                Text(info)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if service.attachment != nil && service.fileMode != .search {
                Toggle(isOn: $service.fastMode) {
                    Label("Modo rápido", systemImage: "bolt.fill")
                }
                .toggleStyle(.button)
                .disabled(service.isGenerating)
                .help("Modo rápido: en archivos largos lee solo una muestra de 4 partes")
            }
            Button("Adjuntar", systemImage: "paperclip") { pickFile() }
                .disabled(service.isGenerating)
                .help("Adjuntar archivo")
            Button("Copiar", systemImage: "doc.on.doc") { copy() }
                .disabled(service.response.isEmpty)
                .help("Copiar respuesta")
            Button("Limpiar", systemImage: "trash") { service.clear() }
                .disabled(service.prompt.isEmpty && service.response.isEmpty
                          && service.attachment == nil)
                .help("Limpiar todo")
        }
        .labelStyle(.iconOnly)
    }

    private var canSend: Bool {
        let hasPrompt = !service.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasPrompt || service.attachment != nil) && service.availabilityMessage == nil
    }

    private var responseArea: some View {
        ScrollView {
            Group {
                if let error = service.errorMessage {
                    Text(error).foregroundStyle(.red)
                } else if service.response.isEmpty {
                    Text("La respuesta aparecerá aquí. Puedes arrastrar un archivo desde Finder.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(rendered(service.response))
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(Color.accentColor.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    Label("Suelta el archivo aquí", systemImage: "arrow.down.doc.fill")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                }
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Utilidades

    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service.response, forType: .string)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            service.attach(url)
        }
    }
}
