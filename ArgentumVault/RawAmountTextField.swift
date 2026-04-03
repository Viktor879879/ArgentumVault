import SwiftUI

#if canImport(UIKit)
import UIKit

struct RawAmountTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let traceID: String
    var accessibilityIdentifier: String?
    var accessibilityLabel: String?
    var runtimeMarker: String?
    var font: UIFont?
    var isFocused: FocusState<Bool>.Binding?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        MoneyInputTrace.log(
            "field=\(traceID) ui_component=RawAmountTextField runtime_marker=\(runtimeMarker ?? "") phase=make_ui_view"
        )
        textField.delegate = context.coordinator
        textField.keyboardType = .numbersAndPunctuation
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartInsertDeleteType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.autocapitalizationType = .none
        textField.clearButtonMode = .never
        textField.borderStyle = .none
        textField.text = text
        textField.placeholder = placeholder
        textField.accessibilityIdentifier = accessibilityIdentifier
        textField.accessibilityLabel = accessibilityLabel
        textField.adjustsFontForContentSizeCategory = true
        context.coordinator.updateRuntimeMarker(on: textField)
        if let font {
            textField.font = font
        }
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        MoneyInputTrace.log(
            "field=\(traceID) ui_component=RawAmountTextField runtime_marker=\(runtimeMarker ?? "") phase=update_ui_view"
        )
        uiView.placeholder = placeholder
        uiView.accessibilityIdentifier = accessibilityIdentifier
        uiView.accessibilityLabel = accessibilityLabel
        context.coordinator.updateRuntimeMarker(on: uiView)
        if let font {
            uiView.font = font
        }

        if !context.coordinator.isApplyingChange,
           uiView.text != text {
            MoneyInputTrace.log(
                "field=\(traceID) update_ui current_ui_text=\(uiView.text ?? "") binding_text=\(text)"
            )
            uiView.text = text
        }

        if let isFocused {
            if isFocused.wrappedValue, !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            } else if !isFocused.wrappedValue, uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: RawAmountTextField
        var isApplyingChange = false

        init(parent: RawAmountTextField) {
            self.parent = parent
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let currentText = textField.text ?? ""
            guard let swiftRange = Range(range, in: currentText) else {
                MoneyInputTrace.log(
                    "field=\(parent.traceID) key_rejected current=\(currentText) replacement=\(string) reason=invalid_range"
                )
                return false
            }

            let proposedRaw = currentText.replacingCharacters(in: swiftRange, with: string)
            let boundedText = SecurityValidation.boundedAmountInput(proposedRaw)
            let desiredCaretOffset = min(
                range.location + (string as NSString).length,
                (boundedText as NSString).length
            )

            MoneyInputTrace.log(
                """
                field=\(parent.traceID) key_event \
                current=\(currentText) \
                replacement=\(string) \
                range=\(range.location),\(range.length) \
                proposed_raw=\(proposedRaw)
                """
            )
            MoneyInputTrace.log(
                "field=\(parent.traceID) after_bounded raw=\(proposedRaw) bounded=\(boundedText)"
            )

            apply(text: boundedText, to: textField, desiredCaretOffset: desiredCaretOffset)
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused?.wrappedValue = true
            MoneyInputTrace.log(
                "field=\(parent.traceID) ui_component=RawAmountTextField runtime_marker=\(parent.runtimeMarker ?? "") focus=began"
            )
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused?.wrappedValue = false
            MoneyInputTrace.log("field=\(parent.traceID) focus=ended")
        }

        @objc
        func editingChanged(_ textField: UITextField) {
            let liveText = textField.text ?? ""
            MoneyInputTrace.log(
                "field=\(parent.traceID) editing_changed ui_text=\(liveText) binding_text=\(parent.text)"
            )
        }

        private func apply(text newText: String, to textField: UITextField, desiredCaretOffset: Int) {
            isApplyingChange = true
            textField.text = newText
            setCaret(in: textField, utf16Offset: desiredCaretOffset)
            parent.text = newText
            isApplyingChange = false
            MoneyInputTrace.log("field=\(parent.traceID) binding_updated text=\(newText)")
        }

        private func setCaret(in textField: UITextField, utf16Offset: Int) {
            guard let start = textField.beginningOfDocument as UITextPosition? else { return }
            let safeOffset = max(0, utf16Offset)
            guard let position = textField.position(from: start, offset: safeOffset) else { return }
            textField.selectedTextRange = textField.textRange(from: position, to: position)
        }

        func updateRuntimeMarker(on textField: UITextField) {
            guard let runtimeMarker = parent.runtimeMarker, !runtimeMarker.isEmpty else {
                textField.rightView = nil
                textField.rightViewMode = .never
                return
            }

            let label: UILabel
            if let existingLabel = textField.rightView as? UILabel {
                label = existingLabel
            } else {
                label = UILabel()
                label.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
                label.textColor = .systemOrange
                label.numberOfLines = 1
                label.isAccessibilityElement = true
                label.accessibilityIdentifier = "raw_amount_field.runtime_marker"
                textField.rightView = label
            }

            label.text = runtimeMarker
            label.accessibilityLabel = runtimeMarker
            label.sizeToFit()
            textField.rightViewMode = .always
        }
    }
}

#else

struct RawAmountTextField: View {
    let placeholder: String
    @Binding var text: String
    let traceID: String
    var accessibilityIdentifier: String?
    var accessibilityLabel: String?
    var runtimeMarker: String?
    var font: Any?
    var isFocused: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let isFocused {
                    TextField(placeholder, text: $text)
                        .focused(isFocused)
                } else {
                    TextField(placeholder, text: $text)
                }
            }

            if let runtimeMarker, !runtimeMarker.isEmpty {
                Text(runtimeMarker)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("raw_amount_field.runtime_marker")
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
        .accessibilityLabel(accessibilityLabel ?? placeholder)
        .onChange(of: text) {
            let bounded = SecurityValidation.boundedAmountInput(text)
            MoneyInputTrace.log("field=\(traceID) mac_on_change raw=\(text) bounded=\(bounded)")
            text = bounded
        }
    }
}

#endif
