//
//  PanelChatView.swift
//  Pi On
//
//  The SwiftUI view inside the floating panel.
//  Styled like the screenshot: dark pill input bar with model selector,
//  quick action buttons, chat area, and drag-drop for images/PDFs.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Fonts

private let mono: Font = .system(size: 13, design: .monospaced)
private let monoSmall: Font = .system(size: 11, design: .monospaced)
private let monoTitle: Font = .system(size: 14, weight: .semibold, design: .monospaced)
private let monoLabel: Font = .system(size: 10, weight: .medium, design: .monospaced)
private let monoInput: Font = .system(size: 14, design: .monospaced)

struct PanelChatView: View {
    var appState: AppState
    var onClose: () -> Void

    @State private var inputText = ""
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isInputFocused: Bool
    @State private var attachedImages: [ImageAttachment] = []
    @State private var isDragOver = false
    @State private var showPreview = false
    @State private var previewContent: String = ""

    @State private var showSessionBrowser = false
    @State private var sessionSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ─────────────────────────────────────────
            topBar
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 4)

            // ── Chat messages or empty state ────────────────────
            if appState.messages.isEmpty {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            } else {
                chatArea
            }

            Spacer(minLength: 0)

            // ── Attachment previews ─────────────────────────────
            if !attachedImages.isEmpty {
                attachmentBar
            }

            // ── Main input bar (pill style) ─────────────────────
            inputPill
                .padding(.horizontal, 16)
                .padding(.bottom, 14)


        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .stroke(isDragOver ? Color.blue.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 32))
        .environment(\.colorScheme, .dark)
        .onAppear {
            isInputFocused = true
        }
        .onDrop(of: [.image, .pdf, .fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
            return true
        }
        // Preview sheet
        .sheet(isPresented: $showPreview) {
            PreviewSheet(content: previewContent, onDismiss: { showPreview = false })
        }
        .sheet(isPresented: $showSessionBrowser) {
            SessionBrowserSheet(
                sessions: appState.sessions,
                onSelect: { session in
                    appState.switchSession(session)
                    showSessionBrowser = false
                },
                onDismiss: { showSessionBrowser = false }
            )
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // Sessions button
            Button {
                appState.loadSessions()
                showSessionBrowser = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, design: .monospaced))
                    Text("Sessions")
                        .font(monoSmall)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            // Token stats
            if let stats = appState.tokenStats {
                HStack(spacing: 6) {
                    Text("↑\(stats.inputDisplay)")
                    Text("↓\(stats.outputDisplay)")
                    Text("R\(stats.cacheReadDisplay)")
                    Text("W\(stats.cacheWriteDisplay)")
                    Text(stats.costDisplay)
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
            }

            Spacer()

            // New session
            Button {
                appState.newSession()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, design: .monospaced))
                    Text("New")
                        .font(monoSmall)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            if appState.isSwitchingSession {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white.opacity(0.3))

                Text("Loading session…")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            } else {
                Image("PiAvatar")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .opacity(0.15)

                Text("Ask Pi...")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.15))

                Text("Drop images here or type below")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.08))
            }
        }
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(appState.messages) { message in
                        MessageBubble(message: message, onCopy: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        }, onPaste: {
                            appState.pasteResultIntoApp()
                            onClose()
                        }, onPreview: {
                            previewContent = message.content
                            showPreview = true
                        })
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: appState.messages.count) {
                if let last = appState.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Pill (matches screenshot design)

    private var inputPill: some View {
        HStack(spacing: 10) {
            // Model selector
            modelSelector

            // Working directory picker
            Button {
                pickWorkingDirectory()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, design: .monospaced))
                    if !appState.workingDirectory.isEmpty {
                        Text(cwdDisplayName)
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(appState.workingDirectory.isEmpty ? "Set working directory" : appState.workingDirectory)

            // Text input
            TextField("Ask Pi...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(monoInput)
                .lineLimit(1...5)
                .focused($isInputFocused)
                .onSubmit {
                    send()
                }

            // Send / Stop
            if appState.isStreaming {
                Button {
                    appState.abort()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22, design: .monospaced))
                        .foregroundStyle(canSend ? .white : .gray.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    // MARK: - Model Selector

    private var modelSelector: some View {
        Menu {
            ForEach(appState.availableModels) { model in
                Button {
                    appState.selectModel(model)
                } label: {
                    HStack {
                        Text(model.displayName)
                        if model.id == appState.selectedModel {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, design: .monospaced))
                Text(selectedModelDisplayName)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var selectedModelDisplayName: String {
        appState.availableModels.first(where: { $0.id == appState.selectedModel })?.displayName
            ?? (appState.selectedModel.isEmpty ? "Loading models…" : appState.selectedModel)
    }

    private var cwdDisplayName: String {
        let path = appState.workingDirectory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        // Show last path component, or last two if short enough
        let components = short.split(separator: "/")
        if components.count <= 2 { return String(short) }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            ForEach(QuickAction.allCases, id: \.rawValue) { action in
                Button {
                    // Use clipboard or current input as context
                    let context = inputText.isEmpty ?
                        (NSPasteboard.general.string(forType: .string) ?? "") :
                        inputText
                    inputText = ""
                    appState.executeQuickAction(action, context: context)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: action.icon)
                            .font(.system(size: 11, design: .monospaced))
                        Text(action.rawValue)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color(white: 0.12))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Attachment Bar

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedImages) { img in
                    HStack(spacing: 4) {
                        if let nsImage = NSImage(data: img.data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 32, height: 32)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "doc.fill")
                                .frame(width: 32, height: 32)
                        }
                        Text(img.name)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)

                        Button {
                            attachedImages.removeAll { $0.id == img.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Working Directory Picker

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a directory or file for pi to work in"
        panel.prompt = "Select"
        panel.level = .floating

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            var isDir: ObjCBool = false
            let path: String
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                path = url.path
            } else {
                path = url.deletingLastPathComponent().path
            }
            appState.setWorkingDirectory(path)
        }
    }

    // MARK: - Actions

    private var canSend: Bool {
        !appState.isSwitchingSession && (!inputText.trimmingCharacters(in: .whitespaces).isEmpty || !attachedImages.isEmpty)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }

        let prompt = text.isEmpty ? "Analyse these attachments." : text
        let images = attachedImages
        inputText = ""
        attachedImages = []
        appState.sendPrompt(prompt, images: images)
    }

    // MARK: - Clipboard paste

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general

        // Check for images
        if let imageData = pb.data(forType: .png) {
            attachedImages.append(ImageAttachment(data: imageData, mimeType: "image/png", name: "clipboard.png"))
            return
        }
        if let imageData = pb.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: imageData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            attachedImages.append(ImageAttachment(data: pngData, mimeType: "image/png", name: "clipboard.png"))
            return
        }

        // Check for PDF
        if let pdfData = pb.data(forType: .pdf) {
            // Convert PDF to image for analysis
            if let pngData = pdfToImage(pdfData) {
                attachedImages.append(ImageAttachment(data: pngData, mimeType: "image/png", name: "clipboard.pdf"))
            }
            return
        }

        // Check for file URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls {
                loadFileAsAttachment(url)
            }
            return
        }

        // Fall back to text
        if let text = pb.string(forType: .string) {
            inputText += text
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            // Image
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data = data else { return }
                    let mimeType: String
                    let name: String

                    if provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) {
                        mimeType = "image/jpeg"
                        name = "dropped.jpg"
                    } else {
                        // Convert to PNG
                        if let image = NSImage(data: data),
                           let tiff = image.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: tiff),
                           let pngData = bitmap.representation(using: .png, properties: [:]) {
                            DispatchQueue.main.async {
                                self.attachedImages.append(ImageAttachment(data: pngData, mimeType: "image/png", name: "dropped.png"))
                            }
                            return
                        }
                        mimeType = "image/png"
                        name = "dropped.png"
                    }

                    DispatchQueue.main.async {
                        self.attachedImages.append(ImageAttachment(data: data, mimeType: mimeType, name: name))
                    }
                }
            }

            // PDF
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, error in
                    guard let data = data, let pngData = pdfToImage(data) else { return }
                    DispatchQueue.main.async {
                        self.attachedImages.append(ImageAttachment(data: pngData, mimeType: "image/png", name: "dropped.pdf"))
                    }
                }
            }

            // File URL
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        self.loadFileAsAttachment(url)
                    }
                }
            }
        }
    }

    private func loadFileAsAttachment(_ url: URL) {
        let ext = url.pathExtension.lowercased()

        if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) {
            if let data = try? Data(contentsOf: url) {
                let mimeType = ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/png"
                // Convert non-PNG to PNG
                if mimeType != "image/png",
                   let image = NSImage(data: data),
                   let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    attachedImages.append(ImageAttachment(data: pngData, mimeType: "image/png", name: url.lastPathComponent))
                } else {
                    attachedImages.append(ImageAttachment(data: data, mimeType: mimeType, name: url.lastPathComponent))
                }
            }
        } else if ext == "pdf" {
            if let data = try? Data(contentsOf: url), let pngData = pdfToImage(data) {
                attachedImages.append(ImageAttachment(data: pngData, mimeType: "image/png", name: url.lastPathComponent))
            }
        }
    }
}

// MARK: - PDF to Image conversion

private func pdfToImage(_ pdfData: Data) -> Data? {
    guard let provider = CGDataProvider(data: pdfData as CFData),
          let document = CGPDFDocument(provider),
          let page = document.page(at: 1) else { return nil }

    let pageRect = page.getBoxRect(.mediaBox)
    let scale: CGFloat = 2.0
    let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )

    guard let bitmap = bitmap,
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let ctx = context.cgContext
    ctx.setFillColor(CGColor.white)
    ctx.fill(CGRect(origin: .zero, size: size))
    ctx.scaleBy(x: scale, y: scale)
    ctx.drawPDFPage(page)

    NSGraphicsContext.restoreGraphicsState()

    return bitmap.representation(using: .png, properties: [:])
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    var onPreview: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            if message.role == .assistant {
                Image("PiAvatar")
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(.top, 2)
            }

            if message.role == .tool {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.orange)
                    .frame(width: 22, height: 22)
                    .padding(.top, 2)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // Image attachments
                if !message.images.isEmpty {
                    ForEach(message.images) { img in
                        if let nsImage = NSImage(data: img.data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 200, maxHeight: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                Text(message.content.isEmpty && message.isStreaming ? "..." : message.content)
                    .font(mono)
                    .foregroundStyle(foregroundColor)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                // Action buttons for assistant messages
                if message.role == .assistant && !message.isStreaming {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Button { onCopy() } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Button { onPaste() } label: {
                            Label("Paste into …", systemImage: "doc.on.clipboard.fill")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 12)
                    .padding(.top, 2)
                }

                if message.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 12)
                }
            }

            if message.role != .user {
                Spacer(minLength: 40)
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .assistant: "Pi"
        case .tool: "Tool"
        case .system: "System"
        case .user: "You"
        }
    }

    private var foregroundColor: Color {
        switch message.role {
        case .user: .white
        case .assistant: .white.opacity(0.95)
        case .tool: .white.opacity(0.7)
        case .system: .secondary
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        switch message.role {
        case .user:
            Color.blue.opacity(0.5)
        case .assistant:
            Color.white.opacity(0.1)
        case .tool:
            Color.orange.opacity(0.12)
        case .system:
            Color.gray.opacity(0.1)
        }
    }
}

// MARK: - Preview Sheet

struct PreviewSheet: View {
    let content: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preview")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                Text(content)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 600, height: 400)
    }
}

// MARK: - Session Browser Sheet

struct SessionBrowserSheet: View {
    let sessions: [PiSession]
    let onSelect: (PiSession) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private var filteredSessions: [PiSession] {
        if searchText.isEmpty { return sessions }
        let query = searchText.lowercased()
        return sessions.filter {
            $0.displayName.lowercased().contains(query)
            || $0.cwdShort.lowercased().contains(query)
            || ($0.name?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Sessions")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                Spacer()
                Text("\(sessions.count) total")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Done") { onDismiss() }
                    .font(.system(size: 13, design: .monospaced))
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("Search sessions…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Session list
            if filteredSessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No sessions found")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredSessions) { session in
                            SessionRow(session: session)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(session)
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 600, height: 500)
        .environment(\.colorScheme, .dark)
    }
}

struct SessionRow: View {
    let session: PiSession

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                // Session name / first message
                Text(session.displayName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)

                // CWD
                HStack(spacing: 6) {
                    Text(session.cwdShort)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(.white.opacity(0.15))

                    Text("\(session.messageCount) msgs")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            Spacer()

            // Timestamp
            Text(Self.dateFormatter.localizedString(for: session.modified, relativeTo: Date()))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.03))
        .cornerRadius(0)
    }
}
