//
//  ScreenCapture.swift
//  Pi On
//
//  Captures screenshots using ScreenCaptureKit (macOS 14+).
//

import AppKit
import ScreenCaptureKit

struct ScreenCapture {

    static func captureScreen() async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width) * 2
            config.height = Int(display.height) * 2
            config.capturesAudio = false
            config.showsCursor = true

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            let bitmap = NSBitmapImageRep(cgImage: image)
            return bitmap.representation(using: .png, properties: [:])
        } catch {
            print("[screenshot] capture failed: \(error)")
            return nil
        }
    }

    static func captureWindow(_ window: SCWindow) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, including: [window])
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width) * 2
            config.height = Int(window.frame.height) * 2
            config.capturesAudio = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            let bitmap = NSBitmapImageRep(cgImage: image)
            return bitmap.representation(using: .png, properties: [:])
        } catch {
            print("[screenshot] window capture failed: \(error)")
            return nil
        }
    }

    static func captureFrontmostWindow() async -> (data: Data, appName: String, windowTitle: String)? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            for window in content.windows {
                guard let app = window.owningApplication,
                      app.processID == frontApp.processIdentifier,
                      window.isOnScreen,
                      window.frame.width > 100, window.frame.height > 100
                else { continue }

                if let data = await captureWindow(window) {
                    let appName = app.applicationName
                    let title = window.title ?? "Untitled"
                    return (data: data, appName: appName, windowTitle: title)
                }
            }
        } catch {
            print("[screenshot] frontmost capture failed: \(error)")
        }

        return nil
    }

    static func captureScreenForLLM(maxDimension: Int = 1568) async -> Data? {
        guard let pngData = await captureScreen(),
              let image = NSImage(data: pngData) else { return nil }

        let size = image.size
        let scale: CGFloat
        if size.width > size.height {
            scale = CGFloat(maxDimension) / size.width
        } else {
            scale = CGFloat(maxDimension) / size.height
        }

        if scale >= 1.0 {
            return pngData
        }

        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()

        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [.compressionFactor: 0.8])
    }
}
