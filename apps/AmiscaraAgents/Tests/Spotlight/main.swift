// Checks the Spotlight entries of spaces and agents (#308) without the UI
// or CoreSpotlight: detail text, keywords, the cap per kind, and the two
// link helpers on WidgetSnapshot. Built by scripts/spotlight-test.sh.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") }
}

let hostID = UUID()

// MARK: Space entries

let withBranch = SpotlightEntries.Space(workspaceID: "ws1", name: "Dorfkino", label: "Privat/Dorfkino", branch: "main")
let withoutBranch = SpotlightEntries.Space(workspaceID: "ws2", name: "Shop", label: "Shop", branch: nil)

let spaceEntries = SpotlightEntries.entries(hostID: hostID, hostName: "Mac mini", spaces: [withBranch, withoutBranch], agents: [])
check(spaceEntries.count == 2, "one entry per space: \(spaceEntries.count)")
check(spaceEntries[0].title == "Dorfkino", "space title is the name: \(spaceEntries[0].title)")
check(spaceEntries[0].detail == "Mac mini · main", "space detail has host and branch: \(spaceEntries[0].detail)")
check(spaceEntries[0].keywords == ["Privat/Dorfkino", "main", "Mac mini"], "space keywords: \(spaceEntries[0].keywords)")
check(spaceEntries[1].detail == "Mac mini", "space detail without a branch is only the host: \(spaceEntries[1].detail)")
check(spaceEntries[1].keywords == ["Shop", "Mac mini"], "space keywords without a branch: \(spaceEntries[1].keywords)")
check(spaceEntries[0].id == WidgetSnapshot.spaceURL(host: hostID, workspaceID: "ws1").absoluteString, "space id is its spaceURL")

// MARK: Agent entries

let agent = WidgetSnapshot.Agent(paneID: "p1", workspaceID: "ws1", place: "Dorfkino · Tab 1", name: "claude", state: .blocked)
let agentEntries = SpotlightEntries.entries(hostID: hostID, hostName: "Mac mini", spaces: [], agents: [agent])
check(agentEntries.count == 1, "one entry per agent: \(agentEntries.count)")
check(agentEntries[0].title == "claude", "agent title is its name: \(agentEntries[0].title)")
check(agentEntries[0].detail == "wartet · Dorfkino · Tab 1 · Mac mini", "agent detail has status, place and host: \(agentEntries[0].detail)")
check(
    agentEntries[0].id == WidgetSnapshot.openURL(host: hostID, workspaceID: "ws1", paneID: "p1").absoluteString,
    "agent id is its openURL"
)

// MARK: Cap per kind

let manySpaces = (0..<150).map { SpotlightEntries.Space(workspaceID: "ws\($0)", name: "Space \($0)", label: "Space \($0)", branch: nil) }
let manyAgents = (0..<150).map { WidgetSnapshot.Agent(paneID: "p\($0)", workspaceID: "ws0", place: "", name: "claude \($0)", state: .idle) }
let capped = SpotlightEntries.entries(hostID: hostID, hostName: "Mac mini", spaces: manySpaces, agents: manyAgents)
check(capped.filter { $0.title.hasPrefix("Space ") }.count == 100, "spaces capped at 100")
check(capped.filter { $0.title.hasPrefix("claude ") }.count == 100, "agents capped at 100")
check(capped.first?.title == "Space 0", "spaces kept in the given order")
check(capped[100].title == "claude 0", "agents kept in the given order, after the spaces")

// MARK: spaceURL / parseSpaceURL

let spaceURL = WidgetSnapshot.spaceURL(host: hostID, workspaceID: "ws1")
check(WidgetSnapshot.parseSpaceURL(spaceURL)?.host == hostID, "parseSpaceURL reads its own link's host")
check(WidgetSnapshot.parseSpaceURL(spaceURL)?.workspaceID == "ws1", "parseSpaceURL reads its own link's space")

let openURL = WidgetSnapshot.openURL(host: hostID, workspaceID: "ws1", paneID: "p1")
check(WidgetSnapshot.parseSpaceURL(openURL) == nil, "parseSpaceURL rejects a link with a pane")
check(WidgetSnapshot.parseOpenURL(spaceURL) == nil, "parseOpenURL rejects a link without a pane")

if failures > 0 { exit(1) }
print("spotlight: ok")
