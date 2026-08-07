/* Deprecated Codex-only implementation retained for migration reference.
@preconcurrency import AVFoundation
import Foundation
import Speech

struct SpeechEvent: Encodable {
    let type: String
    var backend: String?
    var timestamp_ms: Int?
    var utterance_id: String?
    var text: String?
    var code: String?
    var message: String?
    var recoverable: Bool?
    var reason: String?
}

final class EventEmitter: @unchecked Sendable {
    private let encoder = JSONEncoder()
    private let lock = NSLock()

    /// Writes one newline-delimited JSON event to standard output.
    func emit(_ event: SpeechEvent) {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? encoder.encode(event) else {
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

final class VoiceActivityTracker: @unchecked Sendable {
    private let emitter: EventEmitter
    private let lock = NSLock()
    private let silenceHangover: TimeInterval = 0.65
    private let threshold: Float = 0.003
    private var lastVoiceTime: TimeInterval = 0
    private var speaking = false

    /// Creates an acoustic voice-activity tracker for microphone buffers.
    init(emitter: EventEmitter) {
        self.emitter = emitter
    }

    /// Measures one microphone buffer and emits speech boundary events.
    func process(_ buffer: AVAudioPCMBuffer) {
        let level = rootMeanSquare(buffer)
        let now = ProcessInfo.processInfo.systemUptime
        var started = false
        var ended = false

        lock.lock()
        if level >= threshold {
            lastVoiceTime = now
            if !speaking {
                speaking = true
                started = true
            }
        } else if speaking, now - lastVoiceTime >= silenceHangover {
            speaking = false
            ended = true
        }
        lock.unlock()

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        if started {
            emitter.emit(SpeechEvent(type: "speech_started", timestamp_ms: timestamp))
        }
        if ended {
            emitter.emit(SpeechEvent(type: "speech_ended", timestamp_ms: timestamp))
        }
    }

    /// Calculates the root-mean-square amplitude of a PCM audio buffer.
    private func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sum += sample * sample
            }
        }
        return sqrt(sum / Float(frameCount * max(channelCount, 1)))
    }
}

final class AudioBufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    /// Creates a converter from the microphone format to the analyzer format.
    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// Converts one microphone buffer into the analyzer's required format.
    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw HelperError.audioConversionFailed
        }

        let provider = ConverterInputProvider(input: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            provider.next(status: inputStatus)
        }

        if status == .error {
            throw conversionError ?? HelperError.audioConversionFailed
        }
        return output
    }
}

final class ConverterInputProvider: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false

    /// Creates a single-buffer input provider for AVAudioConverter.
    init(input: AVAudioPCMBuffer) {
        self.input = input
    }

    /// Supplies the source buffer once and then reports that no more data is available.
    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return input
    }
}

enum HelperError: LocalizedError {
    case audioConversionFailed
    case microphoneDenied
    case microphoneUnavailable
    case speechLocaleUnsupported
    case speechUnavailable

    /// Returns a user-facing description for helper startup errors.
    var errorDescription: String? {
        switch self {
        case .audioConversionFailed:
            "The microphone audio format could not be converted for speech recognition."
        case .microphoneDenied:
            "Microphone permission was denied."
        case .microphoneUnavailable:
            "No usable microphone input is available."
        case .speechLocaleUnsupported:
            "The current speech locale is not supported."
        case .speechUnavailable:
            "On-device speech transcription is unavailable."
        }
    }
}

@main
struct CodexHandsfree {
    /// Starts the speech helper or emits a deterministic protocol self-test.
    static func main() async {
        let emitter = EventEmitter()
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest(emitter: emitter)
            return
        }

        do {
            try await run(emitter: emitter)
        } catch {
            emitter.emit(
                SpeechEvent(
                    type: "error",
                    code: "startup_failed",
                    message: error.localizedDescription,
                    recoverable: false
                )
            )
            exit(1)
        }
    }

    /// Emits a complete synthetic event sequence without opening the microphone.
    private static func runSelfTest(emitter: EventEmitter) {
        emitter.emit(SpeechEvent(type: "ready", backend: "self-test"))
        emitter.emit(SpeechEvent(type: "speech_started", timestamp_ms: 1))
        emitter.emit(SpeechEvent(type: "transcript_partial", utterance_id: "test-1", text: "hello"))
        emitter.emit(SpeechEvent(type: "transcript_final", utterance_id: "test-1", text: "hello"))
        emitter.emit(SpeechEvent(type: "speech_ended", timestamp_ms: 2))
        emitter.emit(SpeechEvent(type: "stopped", reason: "self-test"))
    }

    /// Runs continuous microphone capture and on-device transcription.
    private static func run(emitter: EventEmitter) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw HelperError.speechUnavailable
        }

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            throw HelperError.microphoneDenied
        }

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw HelperError.speechLocaleUnsupported
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        _ = try await AssetInventory.reserve(locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw HelperError.speechUnavailable
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw HelperError.microphoneUnavailable
        }
        guard let converter = AudioBufferConverter(inputFormat: inputFormat, outputFormat: analyzerFormat) else {
            throw HelperError.audioConversionFailed
        }

        let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let activity = VoiceActivityTracker(emitter: emitter)
        let transcriptionTask = Task {
            try await emitTranscriptionResults(from: transcriber, emitter: emitter)
        }
        let analysisTask = Task {
            try await analyzer.analyzeSequence(inputs)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            activity.process(buffer)
            do {
                let converted = try converter.convert(buffer)
                inputContinuation.yield(AnalyzerInput(buffer: converted))
            } catch {
                emitter.emit(
                    SpeechEvent(
                        type: "error",
                        code: "audio_conversion_failed",
                        message: error.localizedDescription,
                        recoverable: false
                    )
                )
            }
        }

        try engine.start()
        emitter.emit(SpeechEvent(type: "ready", backend: "apple-speech"))
        await waitForTerminationSignal()

        inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation.finish()
        _ = try await analysisTask.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try await transcriptionTask.value
        _ = await AssetInventory.release(reservedLocale: locale)
        emitter.emit(SpeechEvent(type: "stopped", reason: "terminated"))
    }

    /// Converts transcriber results into partial and final protocol events.
    private static func emitTranscriptionResults(
        from transcriber: SpeechTranscriber,
        emitter: EventEmitter
    ) async throws {
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let range = result.range
            let identifier = "\(range.start.value)-\(range.start.timescale)-\(range.duration.value)-\(range.duration.timescale)"
            emitter.emit(
                SpeechEvent(
                    type: result.isFinal ? "transcript_final" : "transcript_partial",
                    utterance_id: identifier,
                    text: text
                )
            )
        }
    }

    /// Suspends until the process receives SIGTERM or SIGINT.
    private static func waitForTerminationSignal() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)

            let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let lock = NSLock()
            var resumed = false

            /// Resumes the waiting task exactly once.
            func resumeOnce() {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else {
                    return
                }
                resumed = true
                terminationSource.cancel()
                interruptSource.cancel()
                continuation.resume()
            }

            terminationSource.setEventHandler(handler: resumeOnce)
            interruptSource.setEventHandler(handler: resumeOnce)
            terminationSource.resume()
            interruptSource.resume()
        }
    }
}
*/
