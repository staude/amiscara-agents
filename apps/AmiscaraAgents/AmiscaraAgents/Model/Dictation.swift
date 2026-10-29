import AVFoundation
import Observation
import Speech
import Synchronization

/// Dictation straight into the composer, without bringing up the keyboard
/// first: apps cannot start the system dictation, so this uses the Speech
/// framework (German, on the device where possible).
@MainActor
@Observable
final class Dictation {
    private(set) var isRunning = false
    /// What has been recognized since `start`, updated while speaking.
    private(set) var transcript = ""
    private(set) var error: String?
    /// Called once per recording that started, from `stop`: with the
    /// transcript when a pause ended it (`endingAfterPause`), else `nil`.
    @ObservationIgnored var onFinish: (@MainActor (String?) -> Void)?
    /// Whether any composer or the voice mode is recording (#297).
    static var isAnyRunning: Bool { running > 0 }
    private static var running = 0

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    /// Created per recording, after the audio session is set to record, and
    /// dropped afterwards, so each recording starts on the current route.
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var feed: AudioFeed?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// Text of the utterances finished so far. After a pause the recognizer
    /// starts its transcription over, so the earlier text is kept here.
    @ObservationIgnored private var finished = ""
    /// The latest transcription and whether its utterance ended (the
    /// recognizer attaches metadata to an utterance's last result).
    @ObservationIgnored private var current = ""
    @ObservationIgnored private var currentEnded = false
    /// Silence after speech that ends the recording, `nil` to keep going.
    @ObservationIgnored private var pause: Duration?
    /// A pause or the recognizer's final result ended the recording.
    @ObservationIgnored private var endedByPause = false
    /// Between `start` and the recording, while asking for permissions.
    @ObservationIgnored private var starting = false
    /// Counts transcript changes, so a pause timer sees newer speech.
    @ObservationIgnored private var heard = 0

    /// `endingAfterPause` stops the recording once that long nothing new
    /// was recognized after some speech. `preferBuiltInMic: false` keeps the
    /// microphone of the route in use (AirPods, CarPlay) on iOS.
    func start(endingAfterPause pause: Duration? = nil, preferBuiltInMic: Bool = true) async {
        guard !isRunning, !starting else { return }
        starting = true
        defer { starting = false }
        // A pause timer of an earlier recording must not end this one.
        heard += 1
        self.pause = pause
        endedByPause = false
        error = nil
        transcript = ""
        finished = ""
        current = ""
        currentEnded = false
        guard let recognizer, recognizer.isAvailable else {
            error = String(localized: "Spracherkennung ist gerade nicht verfügbar.")
            return
        }
        guard await Self.speechAllowed() else {
            error = String(localized: "Spracherkennung ist nicht erlaubt (Einstellungen › Datenschutz › Spracherkennung).")
            return
        }
        guard await Self.microphoneAllowed() else {
            error = String(localized: "Mikrofon ist nicht erlaubt (Einstellungen › Datenschutz › Mikrofon).")
            return
        }
        do {
            try begin(with: recognizer, preferBuiltInMic: preferBuiltInMic)
            isRunning = true
            Self.running += 1
        } catch {
            stop()
            self.error = String(localized: "Diktat konnte nicht starten: \(error.localizedDescription)")
        }
    }

    func stop() {
        let wasRunning = isRunning
        // `begin` activated the session once it made the feed.
        let hadSession = wasRunning || feed != nil
        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        feed?.request.endAudio()
        task?.finish()
        feed = nil
        task = nil
        isRunning = false
        #if os(iOS)
        // Not when nothing recorded: reading aloud may be using the session.
        if hadSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        guard wasRunning else { return }
        Self.running -= 1
        onFinish?(endedByPause ? transcript : nil)
    }

    private func begin(with recognizer: SFSpeechRecognizer, preferBuiltInMic: Bool) throws {
        #if os(iOS)
        // Non-mixable (no `.duckOthers`), default mode (not `.measurement`),
        // built-in microphone preferred. Tested on the iPad Pro M5.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        if preferBuiltInMic, let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtIn)
        } else if !preferBuiltInMic {
            // The preference outlives the recording that set it.
            try session.setPreferredInput(nil)
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        let feed = AudioFeed(request: request)
        self.feed = feed

        let engine = AVAudioEngine()
        self.engine = engine
        feed.install(on: engine.inputNode)
        // Pull the input through the graph, silently. Without a connection
        // the input node may not be rendered.
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: engine.inputNode.outputFormat(forBus: 0))
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
        watchForSilence(feed)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = result?.speechRecognitionMetadata != nil
            let done = error != nil || (result?.isFinal ?? false)
            let message = error.flatMap(Self.message(for:))
            Task { @MainActor in
                guard let self else { return }
                if let text { self.receive(text, ended: ended) }
                // With a pause the text is sent, so an error must show.
                if let message, self.transcript.isEmpty || self.pause != nil { self.error = message }
                if done && self.isRunning {
                    // A final result counts like the pause.
                    if message == nil, self.pause != nil, !self.transcript.isEmpty { self.endedByPause = true }
                    self.stop()
                }
            }
        }
    }

    /// Keeps what was said before a pause: once an utterance has ended, a
    /// transcription that does not continue it starts a new one.
    private func receive(_ text: String, ended: Bool) {
        if currentEnded, !current.isEmpty, !text.hasPrefix(current) {
            finished = Self.join(finished, current)
        }
        current = text
        currentEnded = ended
        let joined = Self.join(finished, current)
        guard joined != transcript else { return }
        transcript = joined
        if let pause, !joined.isEmpty { endAfter(pause) }
    }

    /// Stops after `pause` unless something new was recognized meanwhile.
    private func endAfter(_ pause: Duration) {
        heard += 1
        let mark = heard
        Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard let self, self.isRunning, self.heard == mark else { return }
            self.endedByPause = true
            self.stop()
        }
    }

    private static func join(_ first: String, _ second: String) -> String {
        [first, second].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// While the iPad is remote controlled from a Mac (screen sharing with
    /// control), iPadOS mutes the microphone for every app: the system log
    /// shows `IsInputMutedBecauseDeviceIsRemoteControlled` for this app and
    /// for Signal alike, and the app gets exact zeros without a microphone
    /// indicator. Only system dictation keeps working. Tried without effect:
    /// other session modes, voice processing, recording to a file (#46).
    /// A real microphone never delivers exact zeros for long, so stop and
    /// say why.
    private func watchForSilence(_ feed: AudioFeed) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.isRunning, self.feed === feed, feed.peak == 0 else { return }
            // Before `stop`, so `onFinish` sees it.
            self.error = String(localized: "Kein Mikrofon: Solange das iPad per Bildschirmfreigabe vom Mac aus gesteuert wird, schaltet iPadOS das Mikrofon für Apps stumm. Freigabe beenden oder das Diktat der Tastatur nutzen.")
            self.stop()
        }
    }

    /// Text for a recognition error, or `nil` for the cancellation that
    /// follows our own `stop`.
    private nonisolated static func message(for error: Error) -> String? {
        let error = error as NSError
        switch (error.domain, error.code) {
        case ("kAFAssistantErrorDomain", 1110):
            return String(localized: "Keine Sprache erkannt. Bitte näher ans Mikrofon und noch einmal.")
        case ("kAFAssistantErrorDomain", 216), ("kAFAssistantErrorDomain", 301),
             (NSCocoaErrorDomain, NSUserCancelledError):
            return nil
        default:
            return String(localized: "Spracherkennung fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Nonisolated: Speech calls the handler on a background queue, and a
    /// handler inferred as main actor isolated traps there (#218).
    private nonisolated static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
    }

    private static func microphoneAllowed() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}

/// Hands microphone buffers to the recognition request from the audio
/// thread. The request is only appended to there and ended on the main
/// actor after the tap is removed.
private final class AudioFeed: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    private let level = Mutex<Float>(0)

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    /// Loudest sample so far; exactly 0 means the system sends silence.
    var peak: Float { level.withLock { $0 } }

    nonisolated func install(on input: AVAudioInputNode) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [self] buffer, _ in
            receive(buffer)
        }
    }

    private nonisolated func receive(_ buffer: AVAudioPCMBuffer) {
        if let samples = buffer.floatChannelData?[0] {
            var loudest: Float = 0
            for i in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(samples[i])) }
            level.withLock { $0 = max($0, loudest) }
        }
        request.append(buffer)
    }
}
