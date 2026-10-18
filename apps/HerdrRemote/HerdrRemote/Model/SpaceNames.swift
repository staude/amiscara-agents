import Foundation

/// Spaces named "Bereich/Name" sit in the sidebar group "Bereich" and are
/// shown as "Name" (the core splits the label, see `herdr_core::spaces`).
/// Outside the sidebar the group goes in brackets after the name, so a
/// chain like "Mac · Dorfkino (Privat) · Tab 2" still reads as one place.
enum SpaceNames {
    /// Footer of the sheets that name a space.
    static let groupHint = String(localized: "Mit „Bereich/Name“ landet der Space in der Gruppe „Bereich“. herdr selbst zeigt den vollen Namen.")

    static func place(name: String, group: String?) -> String {
        guard let group else { return name }
        return "\(name) (\(group))"
    }
}

extension BoardItem {
    /// The agent's space as short name with its group, e.g. "Dorfkino (Privat)".
    var spacePlace: String { SpaceNames.place(name: workspaceName, group: workspaceGroup) }
}
