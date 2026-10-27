import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shows text in the system's own text view, where a selection can span
/// lines (#123): the pane screen draws one SwiftUI `Text` per line, and a
/// selection there ends at the line. Read only; starts at the end.
#if !os(tvOS)
struct SelectTextView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            NativeTextView(text: text)
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(copied ? "Kopiert" : "Alles kopieren", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            Platform.copy(text)
                            copied = true
                        }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
    }
}

#endif

#if os(tvOS)
/// tvOS has no text selection: no button.
struct SelectTextButton: View {
    let title: String
    let makeText: () -> String

    var body: some View { EmptyView() }
}
#else
/// Opens `SelectTextView` with the text `makeText` returns at that moment.
struct SelectTextButton: View {
    let title: String
    let makeText: () -> String
    @State private var shown: String?

    var body: some View {
        Button("Text auswählen", systemImage: "text.cursor") { shown = makeText() }
            .labelStyle(.iconOnly)
            .help(String(localized: "Text auswählen und kopieren"))
            .sheet(item: Binding(get: { shown.map(Shown.init) }, set: { shown = $0?.text })) { item in
                SelectTextView(title: title, text: item.text)
            }
    }

    private struct Shown: Identifiable {
        let text: String
        var id: Int { text.hashValue }
    }
}

#endif

extension PaneContent {
    /// The lines as plain text: no styles, trailing spaces and empty lines
    /// at the end dropped.
    var plainText: String {
        var lines = lines.map { line in
            String(line.spans.map(\.text).joined().reversed().drop(while: { $0 == " " }).reversed())
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

#if os(macOS)
/// Read-only monospace text in the system's text view, with its find bar.
struct NativeTextView: NSViewRepresentable {
    let text: String
    var scrollsToEnd = true
    /// Each change opens the find bar.
    var findRequest = 0

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.string = text
        if scrollsToEnd {
            DispatchQueue.main.async { view.scrollToEndOfDocument(nil) }
        }
        context.coordinator.findRequest = findRequest
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard findRequest != context.coordinator.findRequest,
              let view = scroll.documentView as? NSTextView
        else { return }
        context.coordinator.findRequest = findRequest
        view.window?.makeFirstResponder(view)
        // The text view reads the action from the sender's tag.
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        view.performFindPanelAction(item)
    }

    func makeCoordinator() -> FindRequestState { FindRequestState() }
}
#elseif os(iOS)
/// Read-only monospace text in the system's text view, with its find bar.
struct NativeTextView: UIViewRepresentable {
    let text: String
    var scrollsToEnd = true
    /// Each change opens the find navigator.
    var findRequest = 0

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isFindInteractionEnabled = true
        view.font = .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.text = text
        if scrollsToEnd {
            DispatchQueue.main.async {
                view.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
            }
        }
        context.coordinator.findRequest = findRequest
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard findRequest != context.coordinator.findRequest else { return }
        context.coordinator.findRequest = findRequest
        view.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func makeCoordinator() -> FindRequestState { FindRequestState() }
}
#endif

#if !os(tvOS)
/// The last find request a `NativeTextView` answered.
final class FindRequestState {
    var findRequest = 0
}
#endif
