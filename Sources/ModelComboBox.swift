import AppKit
import SwiftUI

/// Editable combo box: type freely or pick from dropdown (macOS NSComboBox).
struct ModelComboBox: NSViewRepresentable {
    @Binding var text: String
    var items: [String]
    var placeholder: String = L("选择或输入模型 id")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.isEditable = true
        box.isBordered = true
        box.completes = true
        box.hasVerticalScroller = true
        box.numberOfVisibleItems = 12
        box.font = .systemFont(ofSize: 13)
        box.placeholderString = placeholder
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.comboAction(_:))
        context.coordinator.syncItems(box, items: items, selected: text)
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if box.stringValue != text {
            box.stringValue = text
        }
        context.coordinator.syncItems(box, items: items, selected: text)
    }

    final class Coordinator: NSObject, NSComboBoxDelegate, NSComboBoxDataSource {
        var parent: ModelComboBox
        private var lastItems: [String] = []

        init(_ parent: ModelComboBox) { self.parent = parent }

        func syncItems(_ box: NSComboBox, items: [String], selected: String) {
            if items != lastItems {
                lastItems = items
                box.removeAllItems()
                box.addItems(withObjectValues: items)
            }
            // Ensure current free-text value stays visible even if not in list
            if !selected.isEmpty && !items.contains(selected) {
                // NSComboBox shows stringValue independently; no need to insert
            }
            if box.stringValue != selected {
                box.stringValue = selected
            }
        }

        @objc func comboAction(_ sender: NSComboBox) {
            parent.text = sender.stringValue
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let box = obj.object as? NSComboBox else { return }
            parent.text = box.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            // Selection index maps to item; stringValue updates after runloop tick
            DispatchQueue.main.async {
                self.parent.text = box.stringValue
            }
        }
    }
}
