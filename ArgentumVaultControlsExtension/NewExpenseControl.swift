import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct NewExpenseControl: ControlWidget {
    static let kind = "com.argentumvault.app.controls.new-expense"
    private static let title: LocalizedStringResource = "control.new_expense.title"
    private static let description: LocalizedStringResource = "control.new_expense.description"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { _ in
            ControlWidgetButton(action: OpenQuickExpenseIntent()) {
                Label {
                    Text(Self.title)
                } icon: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .displayName(Self.title)
        .description(Self.description)
    }
}

@available(iOS 18.0, *)
extension NewExpenseControl {
    struct Provider: ControlValueProvider {
        var previewValue: Bool {
            false
        }

        func currentValue() async throws -> Bool {
            false
        }
    }
}
