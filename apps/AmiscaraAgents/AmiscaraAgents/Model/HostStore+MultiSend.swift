import Foundation

#if !os(tvOS)
extension HostStore {
    /// Sends one prompt to several agent panes (#299), one after the other
    /// in the given order, each over its own host with the composer's
    /// checks. A pane that waits for an answer, also one that started
    /// waiting since it was picked, gets nothing; a failed send does not
    /// stop the others. `progress` gets each result as it comes.
    func sendToMany(
        _ prompt: String,
        to targets: [MultiSend.Target],
        progress: @MainActor (MultiSend.Result) -> Void
    ) async -> [MultiSend.Result] {
        var results: [MultiSend.Result] = []
        // A host found out of reach is not waited for again.
        var unreachable: [UUID: String] = [:]
        for target in targets {
            if Task.isCancelled { break }
            let outcome: MultiSend.Outcome
            if let reason = unreachable[target.hostID] {
                outcome = .failed(reason)
            } else {
                outcome = await sendOne(prompt, to: target)
                if case .failed(let reason) = outcome, connection(for: target.hostID)?.isLive != true {
                    unreachable[target.hostID] = reason
                }
            }
            let result = MultiSend.Result(target: target, outcome: outcome)
            results.append(result)
            progress(result)
        }
        return results
    }

    private func sendOne(_ prompt: String, to target: MultiSend.Target) async -> MultiSend.Outcome {
        let waiting = String(localized: "Wartet auf Antwort")
        // A host without a connection keeps its last board; it fails below.
        if let connection = connection(for: target.hostID), connection.isLive {
            if boardItem(host: target.hostID, pane: target.paneID)?.agentState == .blocked {
                return .skipped(waiting)
            }
            // herdr may report a choice question late (#272).
            if await connection.choiceQuestion(paneID: target.paneID) != nil {
                return .skipped(String(localized: "Auswahlfrage offen"))
            }
        }
        do {
            try await sendPrompt(prompt, toHost: target.hostID, pane: target.paneID)
        } catch PromptIntentError.blocked {
            return .skipped(waiting)
        } catch let error as PromptIntentError {
            return .failed(String(localized: error.localizedStringResource))
        } catch {
            return .failed(error.localizedDescription)
        }
        PromptHistory.shared.record(prompt, for: PromptHistory.key(host: target.hostID, pane: target.paneID))
        return .sent
    }
}
#endif
