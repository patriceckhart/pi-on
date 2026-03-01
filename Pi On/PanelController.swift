//
//  PanelController.swift
//  Pi On
//
//  Floating panel that appears centered on screen (like Spotlight / Raycast).
//  Dismisses on click outside or Escape.
//

import AppKit
import SwiftUI

// MARK: - KeyablePanel

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - PanelController

final class PanelController: NSObject {
    private var panel: KeyablePanel!
    private let appState: AppState
    private var isVisible = false
    private var escapeMonitor: Any?

    // Panel dimensions — centered floating bar + expandable chat
    private let defaultWidth: CGFloat = 680
    private let defaultHeight: CGFloat = 520

    init(appState: AppState) {
        self.appState = appState
        super.init()
        setupPanel()
    }

    // MARK: - Setup

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.frame
        let x = (screenFrame.width - defaultWidth) / 2 + screenFrame.origin.x
        let y = (screenFrame.height - defaultHeight) / 2 + screenFrame.origin.y + 100 // slightly above center

        let contentRect = NSRect(x: x, y: y, width: defaultWidth, height: defaultHeight)

        panel = KeyablePanel(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 400, height: 300)
        panel.maxSize = NSSize(width: 1200, height: 900)

        let hostView = NSHostingView(
            rootView: PanelChatView(
                appState: appState,
                onClose: { [weak self] in self?.hide() }
            )
        )
        panel.contentView = hostView
    }

    // MARK: - Toggle

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    // MARK: - Show

    func show() {
        guard !isVisible else { return }

        // Remember the currently active app so we can paste back into it
        appState.previousApp = NSWorkspace.shared.frontmostApplication

        guard let screen = NSScreen.main else { return }

        // Keep the user's resized dimensions, just re-center
        let currentSize = panel.frame.size
        let screenFrame = screen.frame
        let x = (screenFrame.width - currentSize.width) / 2 + screenFrame.origin.x
        let y = (screenFrame.height - currentSize.height) / 2 + screenFrame.origin.y + 100

        panel.setFrame(
            NSRect(x: x, y: y, width: currentSize.width, height: currentSize.height),
            display: true
        )

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        isVisible = true
        installEventMonitors()
    }

    // MARK: - Hide

    func hide() {
        guard isVisible else { return }

        removeEventMonitors()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })

        isVisible = false
    }

    // MARK: - Event monitors

    private func installEventMonitors() {
        removeEventMonitors()

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.keyCode == 53 { // Escape
                self.hide()
                return nil
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}
