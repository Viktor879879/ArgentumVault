import Combine
import Foundation
import SwiftUI

@MainActor
final class MoneyRuntimeDebugStore: ObservableObject {
    static let shared = MoneyRuntimeDebugStore()

    @Published var activeRuntimePath = ""
    @Published var liveFieldText = ""
    @Published var liveParsedText = "nil"
    @Published var lastSavePath = ""
    @Published var lastSaveRawText = ""
    @Published var lastSaveParsedText = "nil"
    @Published var lastSavedSyncID = ""
    @Published var lastPersistedText = ""
    @Published var lastPersistedCurrency = ""
    @Published var lastRenderedSyncID = ""
    @Published var lastRenderedText = ""

    private init() {}
}

enum MoneyRuntimeDebug {
    static let marker = "MI-RUNTIME-TRACE-1"

    static func recordLiveField(path: String, text: String, parsed: Decimal?) {
        Task { @MainActor in
            let store = MoneyRuntimeDebugStore.shared
            store.activeRuntimePath = path
            store.liveFieldText = text
            store.liveParsedText = parsed.map { DecimalFormatter.exportString(from: $0, maximumFractionDigits: 6) } ?? "nil"
        }
    }

    static func recordSaveAttempt(path: String, rawText: String, parsed: Decimal) {
        Task { @MainActor in
            let store = MoneyRuntimeDebugStore.shared
            store.lastSavePath = path
            store.lastSaveRawText = rawText
            store.lastSaveParsedText = DecimalFormatter.exportString(from: parsed, maximumFractionDigits: 6)
        }
    }

    static func recordPersist(syncID: String, amount: Decimal, currency: String) {
        Task { @MainActor in
            let store = MoneyRuntimeDebugStore.shared
            store.lastSavedSyncID = syncID
            store.lastPersistedText = DecimalFormatter.exportString(from: amount, maximumFractionDigits: 6)
            store.lastPersistedCurrency = currency
        }
    }

    static func recordRendered(syncID: String, rendered: String) {
        Task { @MainActor in
            let store = MoneyRuntimeDebugStore.shared
            store.lastRenderedSyncID = syncID
            store.lastRenderedText = rendered
        }
    }
}

struct MoneyRuntimeDebugPanel: View {
    let runtimePath: String
    let fieldText: String
    let parsedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Runtime: \(MoneyRuntimeDebug.marker)")
                .accessibilityIdentifier("money_runtime_debug.marker")
            Text("Path: \(runtimePath)")
                .accessibilityIdentifier("money_runtime_debug.path")
            Text("Field: \(fieldText.isEmpty ? "<empty>" : fieldText)")
                .accessibilityIdentifier("money_runtime_debug.field")
            Text("Parsed: \(parsedText)")
                .accessibilityIdentifier("money_runtime_debug.parsed")
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("money_runtime_debug.panel")
    }
}
