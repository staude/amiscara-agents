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

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de-DE"))
    /// Created per recording, after the audio session is set to record, and
    /// dropped afterwards, so each recording starts on the current route.
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var feed: AudioFeed?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func start() async {
        guard !isRunning else { return }
        error = nil
        transcript = ""
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
            try begin(with: recognizer)
            isRunning = true
        } catch {
            stop()
            self.error = String(localized: "Diktat konnte nicht starten: \(error.localizedDescription)")
        }
    }

    func stop() {
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func begin(with recognizer: SFSpeechRecognizer) throws {
        #if os(iOS)
        // Non-mixable (no `.duckOthers`), default mode (not `.measurement`),
        // built-in microphone preferred. Tested on the iPad Pro M5.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtIn)
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
            let done = error != nil || (result?.isFinal ?? false)
            let message = error.flatMap(Self.message(for:))
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if let message, self.transcript.isEmpty { self.error = message }
                if done && self.isRunning { self.stop() }
            }
        }
    }

    /// iPadOS hands apps pure silence (no microphone indicator) while the
    /// screen is shared to a Mac; system dictation still works then. A real
    /// microphone never delivers exact zeros for long, so stop and say why.
    private func watchForSilence(_ feed: AudioFeed) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.isRunning, self.feed === feed, feed.peak == 0 else { return }
            self.stop()
            self.error = String(localized: "Das iPad liefert kein Mikrofonsignal an die App, zum Beispiel während einer Bildschirmfreigabe zum Mac. Freigabe beenden oder das Diktat der Tastatur nutzen.")
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

    private static func speechAllowed() async -> Bool {
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
