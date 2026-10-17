import AVFoundation
import Observation
import Speech

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
    @ObservationIgnored private let engine = AVAudioEngine()
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
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
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

        let input = engine.inputNode
        feed.install(on: input)
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if done && self.isRunning { self.stop() }
            }
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

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    nonisolated func install(on input: AVAudioInputNode) {
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
            request.append(buffer)
        }
    }
}
