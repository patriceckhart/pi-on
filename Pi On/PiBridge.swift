//
//  PiBridge.swift
//  Pi On
//
//  Spawns `pi --mode rpc --no-session` as a child process and communicates
//  via JSON-line stdin/stdout. Direct process communication.
//

import Foundation

/// Represents events coming from the Pi RPC process.
struct PiEvent {
    let type: String
    let raw: [String: Any]

    var textDelta: String? {
        if let ame = raw["assistantMessageEvent"] as? [String: Any],
           ame["type"] as? String == "text_delta",
           let delta = ame["delta"] as? String {
            return delta
        }
        return nil
    }

    var toolName: String? {
        raw["toolName"] as? String
    }

    var resultText: String? {
        if let content = raw["result"] as? [[String: Any]],
           let first = content.first,
           first["type"] as? String == "text" {
            return first["text"] as? String
        }
        if let content = raw["content"] as? [[String: Any]],
           let first = content.first,
           first["type"] as? String == "text" {
            return first["text"] as? String
        }
        return nil
    }
}

final class PiBridge: @unchecked Sendable {
    private let piPath: String
    private(set) var cwd: String?
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readBuffer = ""

    var onStateChange: ((_ connected: Bool, _ streaming: Bool) -> Void)?
    var onMessage: ((PiEvent) -> Void)?

    private var isStreaming = false

    init(piPath: String, cwd: String? = nil) {
        self.piPath = piPath
        self.cwd = cwd
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "\(piPath) --mode rpc --no-session"]
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.environment = ProcessInfo.processInfo.environment
        if let cwd {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.handleOutput(text)
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                print("[pi stderr] \(text)")
            }
        }

        proc.terminationHandler = { [weak self] _ in
            print("[bridge] pi process terminated")
            self?.onStateChange?(false, false)
            self?.process = nil
        }

        do {
            try proc.run()
            print("[bridge] pi started (pid: \(proc.processIdentifier))")
            onStateChange?(true, false)
        } catch {
            print("[bridge] failed to start pi: \(error)")
            onStateChange?(false, false)
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        readBuffer = ""
        onStateChange?(false, false)
    }

    // MARK: - Send Commands

    func sendCommand(_ command: [String: Any]) {
        guard let pipe = stdinPipe else {
            print("[bridge] pi not running, can't send command")
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: command)
            var line = data
            line.append(contentsOf: "\n".utf8)
            pipe.fileHandleForWriting.write(line)

            let type = command["type"] as? String ?? "?"
            print("[ext → pi] \(type)")
        } catch {
            print("[bridge] failed to serialize command: \(error)")
        }
    }

    func sendPrompt(_ text: String, images: [ImageAttachment] = []) {
        var cmd: [String: Any] = [
            "type": "prompt",
            "message": text,
        ]

        if !images.isEmpty {
            cmd["images"] = images.map { img in
                [
                    "type": "image",
                    "data": img.base64,
                    "mimeType": img.mimeType,
                ] as [String: Any]
            }
        }

        sendCommand(cmd)
    }

    func abort() {
        sendCommand(["type": "abort"])
    }

    func newSession() {
        sendCommand(["type": "new_session"])
    }

    func getAvailableModels() {
        sendCommand(["type": "get_available_models", "id": "get_models"])
    }

    func setModel(provider: String, modelId: String) {
        sendCommand([
            "type": "set_model",
            "id": "set_model",
            "provider": provider,
            "modelId": modelId,
        ])
    }

    func switchSession(path: String) {
        sendCommand([
            "type": "switch_session",
            "id": "switch_session",
            "sessionPath": path,
        ])
    }

    func getMessages() {
        sendCommand(["type": "get_messages", "id": "get_messages"])
    }

    func getSessionStats() {
        sendCommand(["type": "get_session_stats", "id": "get_session_stats"])
    }

    // MARK: - Output Parsing

    private func handleOutput(_ text: String) {
        readBuffer += text

        while let newlineRange = readBuffer.range(of: "\n") {
            let line = String(readBuffer[readBuffer.startIndex..<newlineRange.lowerBound])
            readBuffer = String(readBuffer[newlineRange.upperBound...])

            guard !line.isEmpty else { continue }

            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            let event = PiEvent(type: type, raw: json)

            if type == "agent_start" {
                isStreaming = true
                onStateChange?(true, true)
            } else if type == "agent_end" {
                isStreaming = false
                onStateChange?(true, false)
            }

            onMessage?(event)
        }
    }
}
