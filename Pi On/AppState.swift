//
//  AppState.swift
//  Pi On
//
//  Shared application state — manages the Pi RPC bridge,
//  chat messages, streaming state, and quick actions.
//

import SwiftUI
import Observation
import UniformTypeIdentifiers

@Observable
final class AppState {
    // MARK: - Connection
    var isConnected = false
    var isStreaming = false
    var bridgeStatus: String = "Disconnected"

    // MARK: - Chat
    var messages: [ChatMessage] = []
    var currentStreamingText: String = ""

    // MARK: - Token usage
    var tokenStats: TokenStats?

    struct TokenStats {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let cost: Double

        var inputDisplay: String { formatTokens(input) }
        var outputDisplay: String { formatTokens(output) }
        var cacheReadDisplay: String { formatTokens(cacheRead) }
        var cacheWriteDisplay: String { formatTokens(cacheWrite) }
        var costDisplay: String { String(format: "$%.3f", cost) }

        private func formatTokens(_ n: Int) -> String {
            if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
            if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
            return "\(n)"
        }
    }

    // MARK: - Model selection
    var selectedModel: String = ""
    var availableModels: [PiModel] = []

    /// Represents a model returned by pi's get_available_models RPC command.
    struct PiModel: Identifiable, Hashable {
        let id: String
        let name: String
        let provider: String

        /// Display label: "provider / name"
        var displayName: String { "\(provider) / \(name)" }
    }

    // MARK: - Sessions
    var sessions: [PiSession] = []
    var showSessionBrowser = false
    var isSwitchingSession = false
    private var switchSessionNonce: UInt64 = 0

    // MARK: - Settings
    var piPath: String = ""
    var workingDirectory: String = NSHomeDirectory()

    // MARK: - Paste mode: when true, AI result gets pasted into the previously active app
    var pasteMode = false
    var previousApp: NSRunningApplication?

    // MARK: - Bridge
    private(set) var bridge: PiBridge?

    init() {
        detectPiPath()
        startBridge()
    }

    // MARK: - Pi Path Detection

    private func detectPiPath() {
        let candidates = [
            "/usr/local/bin/pi",
            "/opt/homebrew/bin/pi",
            "\(NSHomeDirectory())/.nvm/versions/node/v20.19.2/bin/pi",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                piPath = path
                return
            }
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "which pi"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                piPath = path
            }
        } catch {
            piPath = "pi"
        }
    }

    // MARK: - Bridge Lifecycle

    func startBridge() {
        bridge = PiBridge(piPath: piPath, cwd: workingDirectory.isEmpty ? nil : workingDirectory)
        bridge?.onStateChange = { [weak self] connected, streaming in
            Task { @MainActor in
                self?.isConnected = connected
                self?.isStreaming = streaming
                self?.bridgeStatus = connected ? (streaming ? "Streaming..." : "Connected") : "Disconnected"
                // Fetch available models once connected (and not yet loaded)
                if connected && !streaming && (self?.availableModels.isEmpty ?? false) {
                    self?.bridge?.getAvailableModels()
                }
            }
        }
        bridge?.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleBridgeMessage(message)
            }
        }
        bridge?.start()
    }

    func restartBridge() {
        bridge?.stop()
        messages = []
        currentStreamingText = ""
        availableModels = []
        startBridge()
    }

    func setWorkingDirectory(_ path: String) {
        workingDirectory = path
        restartBridge()
    }

    // MARK: - Send

    func sendPrompt(_ text: String, images: [ImageAttachment] = []) {
        guard !isSwitchingSession else {
            print("[appstate] ignoring prompt while switching session")
            return
        }
        let userMsg = ChatMessage(role: .user, content: text, images: images)
        messages.append(userMsg)
        bridge?.sendPrompt(text, images: images)
    }

    func abort() {
        bridge?.abort()
    }

    func newSession() {
        // Invalidate any pending session switch
        switchSessionNonce &+= 1
        isSwitchingSession = false
        messages = []
        currentStreamingText = ""
        tokenStats = nil
        bridge?.abort()
        bridge?.newSession()
    }

    // MARK: - Quick Actions

    func executeQuickAction(_ action: QuickAction, context: String = "") {
        let prompt: String
        switch action {
        case .rewriteToTweet:
            prompt = "Rewrite the following text as a tweet (max 280 characters). Only output the tweet, nothing else:\n\n\(context)"
        case .summarise:
            prompt = "Summarise the following text concisely. Only output the summary:\n\n\(context)"
        case .convertToTailwind:
            prompt = "Convert the following CSS/HTML to Tailwind CSS classes. Only output the converted code:\n\n\(context)"
        case .writeEmail:
            prompt = context.isEmpty ? "Write a professional email" : "Write a professional email about: \(context)"
        }
        sendPrompt(prompt)
    }

    // MARK: - Paste into active app

    func pasteResultIntoApp() {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else { return }
        let text = lastAssistant.content

        // Copy to clipboard
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Activate previous app and paste
        if let app = previousApp {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Simulate Cmd+V
                let source = CGEventSource(stateID: .hidSystemState)
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
                keyDown?.flags = .maskCommand
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
                keyUp?.flags = .maskCommand
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Message Handling

    private func handleBridgeMessage(_ event: PiEvent) {
        switch event.type {
        case "agent_start":
            currentStreamingText = ""

        case "message_update":
            if let delta = event.textDelta {
                currentStreamingText += delta
                if let lastIdx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                    messages[lastIdx].content = currentStreamingText
                } else {
                    let msg = ChatMessage(role: .assistant, content: currentStreamingText, isStreaming: true)
                    messages.append(msg)
                }
            }

        case "agent_end":
            if let lastIdx = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                messages[lastIdx].isStreaming = false
            }
            currentStreamingText = ""
            bridge?.getSessionStats()

        case "tool_execution_start":
            let toolName = event.toolName ?? "tool"
            let msg = ChatMessage(role: .tool, content: "Running \(toolName)...")
            messages.append(msg)

        case "tool_execution_end":
            if let lastIdx = messages.lastIndex(where: { $0.role == .tool }) {
                let toolName = event.toolName ?? "tool"
                let result = event.resultText ?? ""
                messages[lastIdx].content = "✓ \(toolName): \(result.prefix(200))"
            }

        case "response":
            handleRpcResponse(event)

        default:
            break
        }
    }

    private func handleRpcResponse(_ event: PiEvent) {
        let command = event.raw["command"] as? String ?? ""
        let success = event.raw["success"] as? Bool ?? false

        switch command {
        case "get_available_models":
            guard success,
                  let data = event.raw["data"] as? [String: Any],
                  let models = data["models"] as? [[String: Any]] else {
                print("[appstate] failed to get models: \(event.raw["error"] ?? "unknown")")
                return
            }
            availableModels = models.compactMap { dict in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String,
                      let provider = dict["provider"] as? String else { return nil }
                return PiModel(id: id, name: name, provider: provider)
            }
            // Select first model if none selected
            if selectedModel.isEmpty, let first = availableModels.first {
                selectedModel = first.id
            }
            print("[appstate] loaded \(availableModels.count) models")

        case "set_model":
            if success {
                print("[appstate] model set successfully")
            } else {
                print("[appstate] failed to set model: \(event.raw["error"] ?? "unknown")")
            }

        case "switch_session":
            let nonce = switchSessionNonce
            if success && isSwitchingSession && nonce == switchSessionNonce {
                print("[appstate] session switched, loading messages…")
                bridge?.getMessages()
            } else if !success {
                print("[appstate] failed to switch session: \(event.raw["error"] ?? "unknown")")
                isSwitchingSession = false
            } else {
                // Nonce changed — switch was cancelled
                print("[appstate] session switch cancelled, ignoring")
            }

        case "get_messages":
            // Ignore if switch was cancelled
            guard isSwitchingSession else {
                print("[appstate] get_messages arrived but no switch pending, ignoring")
                return
            }
            guard success,
                  let data = event.raw["data"] as? [String: Any],
                  let rawMessages = data["messages"] as? [[String: Any]] else {
                print("[appstate] failed to get messages: \(event.raw["error"] ?? "unknown")")
                isSwitchingSession = false
                return
            }
            messages = rawMessages.compactMap { msg in
                guard let role = msg["role"] as? String else { return nil }
                let text = extractMessageText(msg)
                guard !text.isEmpty else { return nil }
                let chatRole: MessageRole = switch role {
                case "user": .user
                case "assistant": .assistant
                case "system": .system
                default: .tool
                }
                return ChatMessage(role: chatRole, content: text)
            }
            print("[appstate] loaded \(messages.count) messages from session")
            isSwitchingSession = false

        case "get_session_stats":
            guard success,
                  let data = event.raw["data"] as? [String: Any],
                  let tokens = data["tokens"] as? [String: Any] else { return }
            let cost = data["cost"] as? Double ?? 0
            tokenStats = TokenStats(
                input: tokens["input"] as? Int ?? 0,
                output: tokens["output"] as? Int ?? 0,
                cacheRead: tokens["cacheRead"] as? Int ?? 0,
                cacheWrite: tokens["cacheWrite"] as? Int ?? 0,
                cost: cost
            )

        default:
            break
        }
    }

    /// Call this when the user picks a model from the UI.
    func selectModel(_ model: PiModel) {
        selectedModel = model.id
        bridge?.setModel(provider: model.provider, modelId: model.id)
    }

    private func extractMessageText(_ msg: [String: Any]) -> String {
        // String content
        if let content = msg["content"] as? String {
            return content
        }
        // Array content [{type: "text", text: "..."}]
        if let parts = msg["content"] as? [[String: Any]] {
            return parts.compactMap { part in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Sessions

    func loadSessions() {
        Task.detached {
            let list = SessionBrowser.listAll()
            await MainActor.run {
                self.sessions = list
            }
        }
    }

    func switchSession(_ session: PiSession) {
        switchSessionNonce &+= 1
        isSwitchingSession = true
        messages = []
        currentStreamingText = ""
        bridge?.switchSession(path: session.path)
        showSessionBrowser = false
    }
}

// MARK: - Data Types

struct ChatMessage: Identifiable {
    let id = UUID()
    var role: MessageRole
    var content: String
    var images: [ImageAttachment] = []
    var isStreaming: Bool = false
    let timestamp = Date()
}

enum MessageRole {
    case user, assistant, tool, system
}

struct ImageAttachment: Identifiable {
    let id = UUID()
    let data: Data
    let mimeType: String
    let name: String

    var base64: String {
        data.base64EncodedString()
    }
}

enum QuickAction: String, CaseIterable {
    case rewriteToTweet = "Rewrite to Tweet"
    case summarise = "Summarise"
    case convertToTailwind = "Convert to Tailwind"
    case writeEmail = "Write Email"

    var icon: String {
        switch self {
        case .rewriteToTweet: return "bird"
        case .summarise: return "sparkles"
        case .convertToTailwind: return "chevron.left.forwardslash.chevron.right"
        case .writeEmail: return "envelope"
        }
    }

    var color: Color {
        switch self {
        case .rewriteToTweet: return .cyan
        case .summarise: return .purple
        case .convertToTailwind: return .green
        case .writeEmail: return .blue
        }
    }
}
