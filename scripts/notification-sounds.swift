// Generates the notification tones the app brings (#336) as CAF files
// (linear PCM, 16 bit, 44.1 kHz, mono) into
// apps/AmiscaraAgents/AmiscaraAgents/Sounds. The files are checked in; run
// this only to change a tone:
//
//   swift scripts/notification-sounds.swift
import AVFoundation
import Foundation

let rate = 44_100.0
/// Peak at -3 dBFS.
let peak = 0.708
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "apps/AmiscaraAgents/AmiscaraAgents/Sounds")

/// One struck note: partials with an exponential decay, 8 ms fade-in.
struct Note {
    var start: Double
    var frequency: Double
    var length: Double
    var decay: Double
    var partials: [(ratio: Double, level: Double)] = [(1, 1)]
}

func render(_ notes: [Note], duration: Double) -> [Float] {
    var samples = [Double](repeating: 0, count: Int(duration * rate))
    for note in notes {
        let first = Int(note.start * rate)
        let count = Int(note.length * rate)
        for i in 0..<count where first + i < samples.count {
            let t = Double(i) / rate
            let fadeIn = min(1, t / 0.008)
            let fadeOut = min(1, (note.length - t) / 0.03)
            let envelope = exp(-t * note.decay) * fadeIn * fadeOut
            var value = 0.0
            for partial in note.partials {
                value += partial.level * sin(2 * .pi * note.frequency * partial.ratio * t)
            }
            samples[first + i] += value * envelope
        }
    }
    let top = samples.map(abs).max() ?? 1
    return samples.map { Float($0 / top * peak) }
}

let bell: [(ratio: Double, level: Double)] = [(1, 1), (2.76, 0.35), (5.4, 0.12)]

let tones: [String: [Float]] = [
    // One bright bell.
    "chime": render([Note(start: 0, frequency: 880, length: 1.3, decay: 3.2, partials: bell)], duration: 1.3),
    // Three notes up: C, E, G.
    "rising": render([
        Note(start: 0.00, frequency: 523.25, length: 0.45, decay: 7, partials: bell),
        Note(start: 0.16, frequency: 659.25, length: 0.45, decay: 7, partials: bell),
        Note(start: 0.32, frequency: 783.99, length: 0.70, decay: 5, partials: bell),
    ], duration: 1.02),
    // Three notes down: G, E, C.
    "falling": render([
        Note(start: 0.00, frequency: 783.99, length: 0.45, decay: 7, partials: bell),
        Note(start: 0.16, frequency: 659.25, length: 0.45, decay: 7, partials: bell),
        Note(start: 0.32, frequency: 523.25, length: 0.70, decay: 5, partials: bell),
    ], duration: 1.02),
    // Two dull knocks.
    "knock": render([
        Note(start: 0.00, frequency: 170, length: 0.25, decay: 22, partials: [(1, 1), (2, 0.4)]),
        Note(start: 0.20, frequency: 150, length: 0.30, decay: 20, partials: [(1, 1), (2, 0.4)]),
    ], duration: 0.5),
]

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
for (name, samples) in tones.sorted(by: { $0.key < $1.key }) {
    let url = outDir.appendingPathComponent("\(name).caf")
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
    print("\(url.path): \(String(format: "%.2f", Double(samples.count) / rate)) s")
}
