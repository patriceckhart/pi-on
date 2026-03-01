//
//  HotkeyMonitor.swift
//  Pi On
//
//  Monitors for long-press of the Right Option key (≈ 0.4s hold).
//  Uses CGEvent tap to detect flagsChanged events globally.
//  Requires Accessibility permission.
//

import AppKit
import CoreGraphics

final class HotkeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDownTime: Date?
    private var otherKeyPressed = false
    private let holdDuration: TimeInterval = 0.4
    private let onActivate: () -> Void

    // Track if we already fired for this press to avoid repeat
    private var hasFired = false

    init(onActivate: @escaping () -> Void) {
        self.onActivate = onActivate
    }

    func start() {
        // We need to use a global event tap for flagsChanged
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.keyDown.rawValue)

        // Use a pointer to self for the callback
        let refcon = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: hotkeyCallback,
            userInfo: refcon
        ) else {
            print("[hotkey] Failed to create event tap. Accessibility permission needed.")
            // Fall back to NSEvent global monitor
            startFallbackMonitor()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[hotkey] Event tap installed — long-press Right Option to summon Pi On")
    }

    // Fallback using NSEvent if CGEvent tap can't be created
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private func startFallbackMonitor() {
        print("[hotkey] Using fallback NSEvent monitor")

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        // Also monitor keyDown to cancel
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.otherKeyPressed = true
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags

        // Right Option key: keyCode 61
        if event.keyCode == 61 {
            if flags.contains(.option) {
                // Right Option pressed down
                rightOptionDownTime = Date()
                otherKeyPressed = false
                hasFired = false

                // Schedule a check after holdDuration
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { [weak self] in
                    self?.checkAndFire()
                }
            } else {
                // Right Option released
                rightOptionDownTime = nil
            }
        } else {
            // Some other modifier changed — might be combo
            if rightOptionDownTime != nil {
                otherKeyPressed = true
            }
        }
    }

    func handleEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) {
        if type == .keyDown {
            otherKeyPressed = true
            return
        }

        guard type == .flagsChanged else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = CGEventFlags(rawValue: event.flags.rawValue)

        // Right Option = keyCode 61
        if keyCode == 61 {
            if flags.contains(.maskAlternate) {
                // Right Option pressed
                rightOptionDownTime = Date()
                otherKeyPressed = false
                hasFired = false

                DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { [weak self] in
                    self?.checkAndFire()
                }
            } else {
                // Right Option released
                rightOptionDownTime = nil
            }
        } else {
            if rightOptionDownTime != nil {
                otherKeyPressed = true
            }
        }
    }

    private func checkAndFire() {
        guard let downTime = rightOptionDownTime,
              !otherKeyPressed,
              !hasFired,
              Date().timeIntervalSince(downTime) >= holdDuration else {
            return
        }

        hasFired = true
        onActivate()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
    }
}

// C callback for CGEvent tap
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passRetained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    monitor.handleEvent(proxy, type: type, event: event)
    return Unmanaged.passRetained(event)
}
