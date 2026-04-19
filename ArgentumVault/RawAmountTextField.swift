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
    var sanitizeInput: (String) -> String = SecurityValidation.boundedAmountInput
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
        textField.inputAccessoryView = context.coordinator.makeInputAccessoryView()
        let keypad = NumericKeypadInputView()
        keypad.onKeyTap = { [weak coordinator = context.coordinator] key in
            coordinator?.handleCustomKeypadInput(key)
        }
        keypad.onDelete = { [weak coordinator = context.coordinator] in
            coordinator?.handleCustomKeypadDelete()
        }
        textField.inputView = keypad
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
        context.coordinator.currentTextField = uiView
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
        weak var currentTextField: UITextField?

        init(parent: RawAmountTextField) {
            self.parent = parent
        }

        func makeInputAccessoryView() -> UIView {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()

            let flexibleSpace = UIBarButtonItem(systemItem: .flexibleSpace)

            let doneButton = UIBarButtonItem(
                title: "Done",
                style: .done,
                target: self,
                action: #selector(dismissKeyboardFromAccessory)
            )
            doneButton.accessibilityIdentifier = "raw_amount_field.done"
            doneButton.accessibilityLabel = "Done"

            toolbar.items = [flexibleSpace, doneButton]
            return toolbar
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
            let boundedText = parent.sanitizeInput(proposedRaw)
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
            currentTextField = textField
            parent.isFocused?.wrappedValue = true
            MoneyInputTrace.log(
                "field=\(parent.traceID) ui_component=RawAmountTextField runtime_marker=\(parent.runtimeMarker ?? "") focus=began"
            )
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if currentTextField === textField {
                currentTextField = nil
            }
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
                textField.leftView = nil
                textField.leftViewMode = .never
                return
            }

            let container: UIView
            let label: UILabel

            if let existingContainer = textField.leftView,
               let existingLabel = existingContainer.subviews.compactMap({ $0 as? UILabel }).first {
                container = existingContainer
                label = existingLabel
            } else {
                let badgeLabel = UILabel()
                badgeLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
                badgeLabel.textColor = .white
                badgeLabel.numberOfLines = 1
                badgeLabel.isAccessibilityElement = true
                badgeLabel.accessibilityIdentifier = "raw_amount_field.runtime_marker"

                let badgeContainer = UIView(frame: .zero)
                badgeContainer.backgroundColor = .systemRed
                badgeContainer.layer.cornerRadius = 6
                badgeContainer.layer.masksToBounds = true
                badgeContainer.addSubview(badgeLabel)

                container = badgeContainer
                label = badgeLabel
            }

            label.text = runtimeMarker
            label.accessibilityLabel = runtimeMarker
            label.sizeToFit()

            let horizontalPadding: CGFloat = 8
            let verticalPadding: CGFloat = 4
            let labelFrame = CGRect(
                x: horizontalPadding,
                y: verticalPadding,
                width: label.bounds.width,
                height: label.bounds.height
            )
            label.frame = labelFrame
            container.frame = CGRect(
                x: 0,
                y: 0,
                width: labelFrame.maxX + horizontalPadding + 8,
                height: max(30, labelFrame.maxY + verticalPadding)
            )

            if container !== textField.leftView {
                let spacer = UIView(frame: CGRect(x: 0, y: 0, width: container.frame.width + 8, height: container.frame.height))
                container.frame.origin.x = 0
                container.frame.origin.y = max(0, (spacer.frame.height - container.frame.height) / 2)
                spacer.addSubview(container)
                textField.leftView = spacer
            } else if let spacer = textField.leftView {
                spacer.frame = CGRect(x: 0, y: 0, width: container.frame.width + 8, height: container.frame.height)
                container.frame.origin = CGPoint(x: 0, y: max(0, (spacer.frame.height - container.frame.height) / 2))
            }

            textField.leftViewMode = .always
        }

        func handleCustomKeypadInput(_ key: String) {
            insertAccessoryText(key)
        }

        func handleCustomKeypadDelete() {
            guard let textField = currentTextField else { return }
            let currentText = textField.text ?? ""
            let range: NSRange
            if let sel = textField.selectedTextRange {
                let loc = textField.offset(from: textField.beginningOfDocument, to: sel.start)
                let len = textField.offset(from: sel.start, to: sel.end)
                if len > 0 {
                    range = NSRange(location: loc, length: len)
                } else if loc > 0 {
                    range = NSRange(location: loc - 1, length: 1)
                } else {
                    return
                }
            } else {
                let len = (currentText as NSString).length
                guard len > 0 else { return }
                range = NSRange(location: len - 1, length: 1)
            }
            guard let swiftRange = Range(range, in: currentText) else { return }
            let newText = currentText.replacingCharacters(in: swiftRange, with: "")
            let bounded = parent.sanitizeInput(newText)
            apply(text: bounded, to: textField, desiredCaretOffset: range.location)
        }

        @objc
        private func dismissKeyboardFromAccessory() {
            currentTextField?.resignFirstResponder()
        }

        private func insertAccessoryText(_ insertedText: String) {
            guard let textField = currentTextField else { return }

            let currentText = textField.text ?? ""
            let range: NSRange

            if let selectedTextRange = textField.selectedTextRange {
                let location = textField.offset(from: textField.beginningOfDocument, to: selectedTextRange.start)
                let length = textField.offset(from: selectedTextRange.start, to: selectedTextRange.end)
                range = NSRange(location: location, length: length)
            } else {
                range = NSRange(location: (currentText as NSString).length, length: 0)
            }

            guard let swiftRange = Range(range, in: currentText) else { return }

            let proposedRaw = currentText.replacingCharacters(in: swiftRange, with: insertedText)
            let boundedText = parent.sanitizeInput(proposedRaw)
            let desiredCaretOffset = min(
                range.location + (insertedText as NSString).length,
                (boundedText as NSString).length
            )

            MoneyInputTrace.log(
                """
                field=\(parent.traceID) accessory_insert \
                current=\(currentText) \
                inserted=\(insertedText) \
                range=\(range.location),\(range.length) \
                proposed_raw=\(proposedRaw) \
                bounded=\(boundedText)
                """
            )

            apply(text: boundedText, to: textField, desiredCaretOffset: desiredCaretOffset)
        }
    }
}

private final class NumericKeypadInputView: UIInputView {
    var onKeyTap: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}

    private static let keyLayout: [[String?]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".", "0", nil]
    ]
    private var keyButtons: [UIButton] = []

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 260), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        buildButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildButtons() {
        for row in Self.keyLayout {
            for key in row {
                let button = UIButton(type: .system)
                if let key {
                    button.setTitle(key, for: .normal)
                    button.titleLabel?.font = UIFont.systemFont(ofSize: 26, weight: .light)
                    button.setTitleColor(.label, for: .normal)
                    button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
                } else {
                    let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
                    button.setImage(UIImage(systemName: "delete.backward", withConfiguration: config), for: .normal)
                    button.tintColor = .label
                    button.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
                }
                button.accessibilityIdentifier = key.map { "numpad_key_\($0)" } ?? "numpad_key_delete"
                addSubview(button)
                keyButtons.append(button)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rows = Self.keyLayout.count
        let cols = 3
        let gap: CGFloat = 1
        let w = bounds.width
        let h = bounds.height
        let cellW = (w - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = (h - gap * CGFloat(rows - 1)) / CGFloat(rows)

        var idx = 0
        for (r, row) in Self.keyLayout.enumerated() {
            for (c, key) in row.enumerated() {
                let btn = keyButtons[idx]
                btn.frame = CGRect(
                    x: CGFloat(c) * (cellW + gap),
                    y: CGFloat(r) * (cellH + gap),
                    width: cellW,
                    height: cellH
                )
                btn.backgroundColor = UIColor { trait in
                    let dark = trait.userInterfaceStyle == .dark
                    if key == nil {
                        return dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.78, alpha: 1)
                    }
                    return dark ? UIColor(white: 0.22, alpha: 1) : .white
                }
                idx += 1
            }
        }
    }

    @objc private func keyTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        onKeyTap(title)
    }

    @objc private func deleteTapped() {
        onDelete()
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
    var sanitizeInput: (String) -> String = SecurityValidation.boundedAmountInput
    var font: Any?
    var isFocused: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 8) {
            if let runtimeMarker, !runtimeMarker.isEmpty {
                Text(runtimeMarker)
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityIdentifier("raw_amount_field.runtime_marker")
            }

            Group {
                if let isFocused {
                    TextField(placeholder, text: $text)
                        .focused(isFocused)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
        .accessibilityLabel(accessibilityLabel ?? placeholder)
        .onChange(of: text) {
            let bounded = sanitizeInput(text)
            MoneyInputTrace.log("field=\(traceID) mac_on_change raw=\(text) bounded=\(bounded)")
            text = bounded
        }
    }
}

#endif
