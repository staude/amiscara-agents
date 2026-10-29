import Foundation
import Observation

/// A saved prompt with `{placeholders}`, offered in the input bar for one
/// repository or for all of them.
struct PromptTemplate: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var text = ""
    /// Folder name of the repository's main checkout; `nil` means all repos.
    var repo: String?
}

extension PromptTemplate {
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The name, or the text when no name was given.
    var title: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? trimmedText : trimmedName
    }
}

/// Prompt templates of this device, persisted as JSON in Application Support.
/// Per device like the quick replies, and a list of their own: the Watch and
/// the Apple TV do not show them.
@MainActor
@Observable
final class PromptTemplateStore {
    static let shared = PromptTemplateStore()

    var templates: [PromptTemplate] {
        didSet { save() }
    }
    var saveError: String?

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AmiscaraAgents/prompt-templates.json")
        self.fileURL = url
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([PromptTemplate].self, from: data) {
            templates = stored
        } else {
            templates = []
        }
    }

    func add(repo: String? = nil) -> PromptTemplate {
        let template = PromptTemplate(repo: repo)
        templates.append(template)
        return template
    }

    /// Drops entries left without text in the editor.
    func removeBlank() {
        let kept = templates.filter { !$0.trimmedText.isEmpty }
        if kept.count != templates.count { templates = kept }
    }

    /// The templates for a space of `repo`: those for all repos and those
    /// for exactly this one. Entries without text are skipped.
    func matching(repo: String?) -> [PromptTemplate] {
        templates.filter { template in
            guard !template.trimmedText.isEmpty else { return false }
            guard let scope = template.repo else { return true }
            return scope == repo
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(templates).write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// The `{name}` placeholders of a template text.
enum PromptPlaceholders {
    private static let pattern = try! NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#)
    private static let branchIssue = try! NSRegularExpression(pattern: #"^[^/]+/(\d+)(-|$)"#)

    /// Names in the text, each once, in order of appearance.
    static func names(in text: String) -> [String] {
        var seen = Set<String>()
        return matches(in: text).compactMap { match in
            seen.insert(match.name).inserted ? match.name : nil
        }
    }

    /// The text with each placeholder replaced; one without a value stays.
    static func fill(_ text: String, values: [String: String]) -> String {
        var result = ""
        var rest = text.startIndex
        for match in matches(in: text) {
            result += text[rest..<match.range.lowerBound]
            result += values[match.name] ?? String(text[match.range])
            rest = match.range.upperBound
        }
        return result + text[rest...]
    }

    /// The issue number of a branch like `feature/123-slug`.
    static func issueNumber(branch: String) -> String? {
        let range = NSRange(branch.startIndex..., in: branch)
        guard let match = branchIssue.firstMatch(in: branch, range: range),
              let digits = Range(match.range(at: 1), in: branch) else { return nil }
        return String(branch[digits])
    }

    /// Values known from the space: `nr`, `branch` and `space`, those that exist.
    static func prefills(branch: String?, space: String?) -> [String: String] {
        var values: [String: String] = [:]
        if let branch, !branch.isEmpty {
            values["branch"] = branch
            if let number = issueNumber(branch: branch) { values["nr"] = number }
        }
        if let space, !space.isEmpty { values["space"] = space }
        return values
    }

    private static func matches(in text: String) -> [(name: String, range: Range<String.Index>)] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let name = Range(match.range(at: 1), in: text) else { return nil }
            return (String(text[name]), whole)
        }
    }
}
