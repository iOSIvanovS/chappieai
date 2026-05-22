//
//  ChappieApp.swift
//  Chappie
//
//  Created by   Сергей on 21.05.2026.
//

import SwiftUI
import SwiftData
import ChappieCore

@main
struct ChappieApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(MemoryManager.shared.container)
    }
}
