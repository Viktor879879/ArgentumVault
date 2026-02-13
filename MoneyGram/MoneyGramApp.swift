//
//  MoneyGramApp.swift
//  MoneyGram
//
//  Created by Viktor Parshyn on 2026-02-04.
//

import SwiftUI
import SwiftData

@main
struct MoneyGramApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Category.self,
            Transaction.self,
            Asset.self,
            Wallet.self,
            WalletFolder.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
