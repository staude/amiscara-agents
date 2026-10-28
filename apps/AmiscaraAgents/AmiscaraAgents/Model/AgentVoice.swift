import AVFoundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Reads a Claude pane's replies aloud with the system voice and, in voice
/// mode, takes the answer by dictation (#297): reply read, dictation, a
/// pause sends, the next reply is read. One per pane view.
@MainActor
@Observable
final class AgentVoice {
    enum State {
        case idle
        case speaking
        case listening
        /// Voice mode, until Claude has finished.
        case waiting
        /// Voice mode, Claude asks for a permission or a choice; that is
        /// answered on the screen, not by voice.
        case waitingForDecision
    }

    private(set) var state = State.idle
    private(set) var voiceMode = false
    var error: String?
    let dictation = Dictation()

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var delegate: SpeechDelegate?
    /// The utterance being spoken; a finish of an older one is ignored.
    @ObservationIgnored private var utterance: ObjectIdentifier?
    /// What comes after the utterance: dictation, or a resting state.
    @ObservationIgnored private var afterSpeaking: State?
    @ObservationIgnored private var target: (connection: HostConnection, paneID: String)?
    /// The reply read last, so a new state change does not read it again.
    @ObservationIgnored private var lastRead: Read?
    /// Bumped by `stop`, so work started before it does nothing.
    @ObservationIgnored private var run = 0
    /// Bumped on each agent state change, so an older retry loop stops.
    @ObservationIgnored private var stateChange = 0
    /// `Dictation.start` is still asking for permissions.
    @ObservationIgnored private var startingDictation = false

    private struct Read: Equatable {
        let sessionPath: String
        let timestamp: String?
        let text: String
    }

    private enum Outcome {
        case spoken
        /// The last reply is the one read before.
        case same
        case noReply
        case failed
    }

    init() {
        let delegate = SpeechDelegate { [weak self] id in
            Task { @MainActor in self?.finishedSpeaking(id) }
        }
        synthesizer.delegate = delegate
        self.delegate = delegate
    }

    /// "Antworten vorlesen" for this pane.
    static func readsReplies(host: UUID, pane: String) -> Bool {
        ReadAloudPanes.shared.keys.contains(PromptHistory.key(host: host, pane: pane))
    }

    static func setReadsReplies(_ on: Bool, host: UUID, pane: String) {
        let key = PromptHistory.key(host: host, pane: pane)
        if on { ReadAloudPanes.shared.keys.insert(key) } else { ReadAloudPanes.shared.keys.remove(key) }
    }

    /// "Letzte Antwort vorlesen": the last reply, also if read before. In
    /// voice mode dictation follows only where it would anyway: not while
    /// Claude works or waits for a decision.
    func readLast(connection: HostConnection, paneID: String) {
        if !voiceMode { stop() }
        let run = run
        let after: State = state == .waiting || state == .waitingForDecision ? state : .listening
        Task {
            if await read(connection: connection, paneID: paneID, automatic: false, onlyNew: false, run: run, then: after) == .noReply {
                error = String(localized: "Noch keine Antwort zum Vorlesen.")
            }
        }
    }

    /// Call when the pane's agent state changes. Only the end of Claude's
    /// work counts, not each text between two tool calls.
    func agentStateChanged(from old: AgentState?, to new: AgentState?, connection: HostConnection, paneID: String) {
        stateChange += 1
        guard let new, new != .working, state != .listening else { return }
        // A decision declined on the screen goes from blocked to idle, also
        // while its sentence is still spoken.
        let declined = voiceMode && old == .blocked
            && (state == .waitingForDecision || afterSpeaking == .waitingForDecision)
        guard old == .working || declined else { return }
        if declined {
            // Answered on the screen: wait for the reply as after a prompt.
            if utterance != nil {
                utterance = nil
                afterSpeaking = nil
                synthesizer.stopSpeaking(at: .immediate)
                releaseAudioSession()
            }
            state = .waiting
        }
        if new == .blocked {
            if voiceMode { speakDecision() }
            return
        }
        let reads = voiceMode
            || (Self.readsReplies(host: connection.id, pane: paneID) && !Dictation.isAnyRunning)
        guard reads else { return }
        let run = run
        let change = stateChange
        Task {
            // The session file may lag behind the state: try again a few
            // times, unless the state changed again (e.g. to a decision).
            for attempt in 0 ..< 4 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                guard run == self.run, change == stateChange else { return }
                let outcome = await read(connection: connection, paneID: paneID, automatic: !voiceMode, onlyNew: true, run: run)
                if outcome != .same { return }
            }
            // Nothing new: in voice mode take the next prompt instead of hanging.
            // Never while Claude waits for a decision (only `.waiting` here).
            if run == self.run, change == stateChange, voiceMode, state == .waiting { listen() }
        }
    }

    /// Voice mode: reads the last reply at once unless Claude is working,
    /// then listens; "Stopp" or a tap ends it.
    func startVoiceMode(connection: HostConnection, paneID: String, agentState: AgentState?) {
        stop()
        // Two recordings at once would hear each other.
        guard !Dictation.isAnyRunning else {
            error = String(localized: "Erst das Diktat in der Eingabeleiste beenden.")
            return
        }
        voiceMode = true
        target = (connection, paneID)
        keepScreenOn(true)
        switch agentState {
        case .working:
            state = .waiting
        case .blocked:
            speakDecision()
        default:
            let run = run
            Task {
                let outcome = await read(connection: connection, paneID: paneID, automatic: false, onlyNew: false, run: run)
                // Nothing to read yet: take the first prompt.
                if outcome == .noReply, run == self.run { listen() }
            }
        }
    }

    /// Ends speech, dictation and voice mode.
    func stop() {
        run += 1
        stopDictation()
        if utterance != nil {
            utterance = nil
            synthesizer.stopSpeaking(at: .immediate)
            releaseAudioSession()
        }
        afterSpeaking = nil
        if voiceMode { keepScreenOn(false) }
        voiceMode = false
        target = nil
        state = .idle
        error = nil
    }

    /// Hands the audio back to others, unless the composer's dictation
    /// started meanwhile and still needs it.
    private func releaseAudioSession() {
        #if os(iOS)
        guard !Dictation.isAnyRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Without `onFinish`; leaves the audio session alone when not recording.
    private func stopDictation() {
        guard dictation.isRunning else { return }
        dictation.onFinish = nil
        dictation.stop()
    }

    private func end(error: String?) {
        stop()
        self.error = error
    }

    /// Reads the last reply of the pane's conversation.
    /// `then` is what follows the reply in voice mode.
    private func read(
        connection: HostConnection, paneID: String, automatic: Bool, onlyNew: Bool, run: Int, then next: State = .listening
    ) async -> Outcome {
        let page: TranscriptPage
        do {
            page = try await connection.claudeHistory(paneID: paneID)
        } catch {
            guard run == self.run else { return .failed }
            end(error: inputErrorMessage(error))
            return .failed
        }
        guard run == self.run else { return .failed }
        // The composer's dictation shares the audio session: no automatic
        // reading meanwhile.
        if automatic, Dictation.isAnyRunning { return .failed }
        // A tool call after the last text: the closing reply is not in the
        // file yet.
        if onlyNew, let last = page.entries.last, last.kind != .assistant { return .same }
        guard let entry = page.entries.last(where: { $0.kind == .assistant }) else { return .noReply }
        let read = Read(sessionPath: page.sessionPath, timestamp: entry.timestamp, text: entry.text)
        if onlyNew, read == lastRead { return .same }
        lastRead = read
        let spoken = SpokenText.make(from: entry.text)
        guard !spoken.text.isEmpty else { return .noReply }
        speak(spoken.text, language: spoken.language, automatic: automatic, then: voiceMode ? next : nil)
        return .spoken
    }

    private func speakDecision() {
        let text = String(localized: "Claude wartet auf eine Entscheidung.")
        speak(text, language: nil, automatic: false, then: .waitingForDecision)
    }

    /// `automatic` reading follows the silent switch; reading the user asked
    /// for, and voice mode, does not.
    private func speak(_ text: String, language: String?, automatic: Bool, then next: State?) {
        stopDictation()
        synthesizer.stopSpeaking(at: .immediate)
        #if os(iOS)
        // While the composer records, speak over its session as it is.
        if !Dictation.isAnyRunning {
            let session = AVAudioSession.sharedInstance()
            let ambient = automatic && !voiceMode
            try? session.setCategory(ambient ? .ambient : .playback, mode: .spokenAudio, options: ambient ? [] : [.duckOthers])
            try? session.setActive(true)
        }
        #endif
        let utterance = AVSpeechUtterance(string: text)
        // Without a voice for the language the system voice reads.
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        self.utterance = ObjectIdentifier(utterance)
        afterSpeaking = next
        state = .speaking
        synthesizer.speak(utterance)
    }

    private func finishedSpeaking(_ id: ObjectIdentifier) {
        guard id == utterance else { return }
        utterance = nil
        let next = afterSpeaking
        afterSpeaking = nil
        releaseAudioSession()
        guard voiceMode else {
            state = .idle
            return
        }
        if next == .listening {
            listen()
        } else {
            state = next ?? .waiting
        }
    }

    /// Dictation after a reply; the speech sent once a pause ends it.
    private func listen() {
        guard voiceMode else { return }
        state = .listening
        let run = run
        dictation.onFinish = { [weak self] text in self?.heard(text, run: run) }
        // A start still asking for permissions serves this call too.
        guard !startingDictation else { return }
        startingDictation = true
        Task {
            await dictation.start(endingAfterPause: .seconds(1.8), preferBuiltInMic: false)
            startingDictation = false
            guard voiceMode, state == .listening else {
                // Stopped, or speaking again, while asking for permissions.
                stopDictation()
                return
            }
            if !dictation.isRunning, state == .listening {
                end(error: dictation.error)
            }
        }
    }

    private func heard(_ text: String?, run: Int) {
        guard run == self.run, voiceMode, state == .listening, let target else { return }
        let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            end(error: dictation.error)
            return
        }
        if Self.isStop(prompt) {
            end(error: nil)
            return
        }
        state = .waiting
        Task {
            do {
                try await target.connection.submit(prompt, to: target.paneID, isAgent: true)
                PromptHistory.shared.record(prompt, for: PromptHistory.key(host: target.connection.id, pane: target.paneID))
            } catch {
                guard run == self.run else { return }
                end(error: inputErrorMessage(error))
            }
        }
    }

    /// "Stopp" or "Stop", as the recognizer writes it.
    private static func isStop(_ text: String) -> Bool {
        let word = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return word == "stopp" || word == "stop"
    }

    /// Hands-free needs the app in front: keep the screen on (iOS).
    private func keepScreenOn(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

/// The panes with "Antworten vorlesen" on, for this run of the app only.
@MainActor
@Observable
final class ReadAloudPanes {
    static let shared = ReadAloudPanes()
    var keys: Set<String> = []
}

/// Passes the end of an utterance to the main actor; the synthesizer calls
/// its delegate on a queue of its own.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    let finished: @Sendable (ObjectIdentifier) -> Void

    init(finished: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.finished = finished
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(ObjectIdentifier(utterance))
    }
}
