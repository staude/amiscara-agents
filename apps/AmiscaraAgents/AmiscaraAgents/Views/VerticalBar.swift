import SwiftUI

/// The iPhone Duo (#215) shows status bar and navigation bar as a vertical
/// strip at the side of the screen, folded and unfolded. Toolbar items move
/// into that strip; our own header rows do not, so views that have a few
/// buttons in a header put them into the toolbar while the strip is there.
extension View {
    /// Keeps `active` true while the system shows a vertical bar.
    @ViewBuilder
    func tracksVerticalBar(_ active: Binding<Bool>) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            modifier(VerticalBarReader(active: active))
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Widens the sidebar of a split view to the fold of an unfolded iPhone
    /// Duo, so the crease runs between sidebar and detail instead of through
    /// the terminal.
    @ViewBuilder
    func sidebarAtFold(_ width: Binding<CGFloat?>) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            onGeometryChange(for: CGFloat?.self) { proxy in
                FoldLayout.sidebarWidth(
                    folds: proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame),
                    in: proxy.size
                )
            } action: { width.wrappedValue = $0 }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
@available(iOS 27.1, *)
private struct VerticalBarReader: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var edge
    @Binding var active: Bool

    func body(content: Content) -> some View {
        content.onChange(of: edge != nil, initial: true) { _, shown in active = shown }
    }
}
#endif

enum FoldLayout {
    /// Narrowest sidebar the split view gets anyway.
    static let minSidebar: CGFloat = 240

    /// The sidebar width that puts its edge on an upright fold, or `nil`
    /// without one or when the fold is too far off to the side for a sidebar.
    static func sidebarWidth(folds: [CGRect], in size: CGSize) -> CGFloat? {
        guard let fold = folds.first(where: { $0.height > $0.width }) else { return nil }
        let width = fold.minX
        guard width >= minSidebar, width <= size.width * 0.6 else { return nil }
        return width
    }
}
