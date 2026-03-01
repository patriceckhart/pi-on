//
//  SessionBrowser.swift
//  Pi On
//
//  Reads pi session files from ~/.pi/agent/sessions/ and provides
//  a list of previous sessions for switching.
//
//  Only reads the first few KB of each file for speed — session files
//  can be tens of MB.
//

import Foundation

struct PiSession: Identifiable, Comparable {
    let id: String
    let path: String
    let name: String?
    let cwd: String
    let firstMessage: String
    let modified: Date
    let messageCount: Int

    var displayName: String {
        if let name, !name.isEmpty { return name }
        let trimmed = firstMessage.prefix(80)
        return trimmed.isEmpty ? "(empty session)" : String(trimmed)
    }

    var cwdShort: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    static func < (lhs: PiSession, rhs: PiSession) -> Bool {
        lhs.modified > rhs.modified // newest first
    }
}

nonisolated enum SessionBrowser {

    /// Max bytes to read from each session file — enough for header + first few entries.
    private static let headReadSize = 8192

    /// Scans ~/.pi/agent/sessions/ and returns all sessions, newest first.
    static func listAll() -> [PiSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sessionsDir = "\(home)/.pi/agent/sessions"
        let fm = FileManager.default

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            return []
        }

        var sessions: [PiSession] = []
        sessions.reserveCapacity(256)

        for dir in projectDirs {
            let dirPath = "\(sessionsDir)/\(dir)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }

            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = "\(dirPath)/\(file)"
                if let session = parseSessionHead(filePath) {
                    sessions.append(session)
                }
            }
        }

        sessions.sort()
        return sessions
    }

    /// Read only the head of the file to extract header, session name, and first user message.
    private static func parseSessionHead(_ path: String) -> PiSession? {
        // Get file attributes for modification date + size
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? UInt64,
              fileSize > 0 else { return nil }

        let modified = attrs[.modificationDate] as? Date ?? Date.distantPast

        // Read only the first chunk
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }

        let readSize = min(Int(fileSize), headReadSize)
        let data = fh.readData(ofLength: readSize)
        guard let chunk = String(data: data, encoding: .utf8) else { return nil }

        let lines = chunk.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }

        // Parse header (first line)
        guard let headerData = lines[0].data(using: .utf8),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["type"] as? String == "session",
              let sessionId = header["id"] as? String else { return nil }

        let cwd = header["cwd"] as? String ?? ""

        // Quick scan remaining lines for name + first user message
        var sessionName: String?
        var firstMessage = ""
        var messageCount = 0
        var gotName = false
        var gotFirstMessage = false

        for line in lines.dropFirst() {
            // Stop early once we have what we need
            if gotName && gotFirstMessage { break }

            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = entry["type"] as? String

            if !gotName, type == "session_info",
               let name = entry["name"] as? String, !name.isEmpty {
                sessionName = name.trimmingCharacters(in: .whitespaces)
                gotName = true
            }

            if type == "message" {
                messageCount += 1
                if !gotFirstMessage, let message = entry["message"] as? [String: Any],
                   message["role"] as? String == "user" {
                    let text = extractText(from: message)
                    if !text.isEmpty {
                        firstMessage = String(text.prefix(200))
                        gotFirstMessage = true
                    }
                }
            }
        }

        // For message count: estimate from file size if we only read the head.
        // Actual count from head is a lower bound; use file-size heuristic.
        let estimatedMessages: Int
        if Int(fileSize) <= headReadSize {
            estimatedMessages = messageCount
        } else {
            // Rough heuristic: ~2KB per message on average
            estimatedMessages = max(messageCount, Int(fileSize / 2048))
        }

        return PiSession(
            id: sessionId,
            path: path,
            name: sessionName,
            cwd: cwd,
            firstMessage: firstMessage.isEmpty ? "(no messages)" : firstMessage,
            modified: modified,
            messageCount: estimatedMessages
        )
    }

    private static func extractText(from message: [String: Any]) -> String {
        if let content = message["content"] as? String {
            return content
        }
        if let parts = message["content"] as? [[String: Any]] {
            for part in parts {
                if part["type"] as? String == "text",
                   let text = part["text"] as? String {
                    return text
                }
            }
        }
        return ""
    }
}
