import Foundation
import Observation

/// Tokens of Claude Code, summed from `UsageBucket`s (#302).
struct UsageTokens: Equatable {
    var input: UInt64 = 0
    var output: UInt64 = 0
    var cacheWrite5m: UInt64 = 0
    var cacheWrite1h: UInt64 = 0
    var cacheRead: UInt64 = 0

    var total: UInt64 { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    init() {}

    init(_ bucket: UsageBucket) {
        input = bucket.input
        output = bucket.output
        cacheWrite5m = bucket.cacheWrite5m
        cacheWrite1h = bucket.cacheWrite1h
        cacheRead = bucket.cacheRead
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheWrite5m += rhs.cacheWrite5m
        lhs.cacheWrite1h += rhs.cacheWrite1h
        lhs.cacheRead += rhs.cacheRead
    }
}

/// The list price of a model in US dollars per million tokens.
struct ModelPrice: Codable, Equatable, Identifiable {
    var model: String
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double

    var id: String { model }

    /// Cache writes cost 1.25 times the input for five minutes and twice
    /// the input for an hour.
    init(model: String, input: Double, output: Double, cacheRead: Double) {
        self.model = model
        self.input = input
        self.output = output
        cacheWrite5m = input * 1.25
        cacheWrite1h = input * 2
        self.cacheRead = cacheRead
    }

    /// Whether a model ID from the session files is this model, also with
    /// a date behind it (`claude-haiku-5-5-20261001`).
    func matches(_ id: String) -> Bool {
        id == model || id.hasPrefix(model + "-")
    }

    func cost(_ tokens: UsageTokens) -> Double {
        (Double(tokens.input) * input
            + Double(tokens.output) * output
            + Double(tokens.cacheWrite5m) * cacheWrite5m
            + Double(tokens.cacheWrite1h) * cacheWrite1h
            + Double(tokens.cacheRead) * cacheRead) / 1_000_000
    }
}

/// The prices the app estimates costs with (#302): an editable table per
/// model in `UserDefaults`, with Anthropic's list prices as defaults. In
/// dollars, as Anthropic lists them, so no exchange rate needs keeping.
@MainActor
@Observable
final class UsagePrices {
    static let shared = UsagePrices()
    static let storageKey = "usagePrices"

    /// Anthropic's pricing page as of 2026-10-29; Haiku at the rate for
    /// prompts up to 100,000 tokens.
    static let defaults: [ModelPrice] = [
        ModelPrice(model: "claude-fable-5-1", input: 10, output: 50, cacheRead: 0.25),
        ModelPrice(model: "claude-opus-5-5", input: 4, output: 20, cacheRead: 0.20),
        ModelPrice(model: "claude-sonnet-5-5", input: 2, output: 10, cacheRead: 0.10),
        ModelPrice(model: "claude-haiku-5-5", input: 0.10, output: 0.50, cacheRead: 0.01),
    ]

    var prices: [ModelPrice] {
        didSet { save() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([ModelPrice].self, from: data) {
            prices = stored
        } else {
            prices = Self.defaults
        }
    }

    var isDefault: Bool { prices == Self.defaults }

    func reset() {
        prices = Self.defaults
    }

    /// The estimated cost in dollars; `nil` for a model without a price.
    func cost(model: String, tokens: UsageTokens) -> Double? {
        prices.first { $0.matches(model) }?.cost(tokens)
    }

    private func save() {
        if isDefault {
            // Later default prices then reach those who never edited them.
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(prices) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
