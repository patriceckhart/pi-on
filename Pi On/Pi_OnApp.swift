//
//  Pi_OnApp.swift
//  Pi On
//
//  Menu-bar-only AI assistant. Lives in the menu bar.
//  Long-press Right Option key to summon from anywhere.
//

import SwiftUI

@main
struct Pi_OnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
