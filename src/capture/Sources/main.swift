import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreAudio

// MARK: - Configuration

let sampleRate: Double = 16000
let chunkDurationSeconds: Int = 3
let samplesPerChunk = Int(sampleRate) * chunkDurationSeconds
let whisperPort = 8178
let diarizePort = 8179

let whisperModel = ProcessInfo.processInfo.environment["MEETINK_MODEL"]
    ?? "\(NSHomeDirectory())/.meetink/models/ggml-small.en.bin"
let transcriptPath = ProcessInfo.processInfo.environment["MEETINK_TRANSCRIPT"]
    ?? "\(NSHomeDirectory())/.meetink/transcripts/live.txt"
let chunkDir = ProcessInfo.processInfo.environment["MEETINK_CHUNK_DIR"]
    ?? "/tmp/meetink-chunks"
let whisperPromptPath = ProcessInfo.processInfo.environment["MEETINK_PROMPT"]
    ?? "\(NSHomeDirectory())/.meetink/prompts/default.txt"

// User identity. The mic stream always belongs to whoever is running
// meetink, so we don't diarize it — we just label it. By default that
// label is "ME"; if the launcher set MEETINK_ME_NAME (from /me <name>
// in the REPL), we use that instead, uppercased. Persisting the name
// also lets future /ask features know who the user is in the transcript.
let meName: String = {
    if let raw = ProcessInfo.processInfo.environment["MEETINK_ME_NAME"]?
        .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
        return raw.uppercased()
    }
    return "ME"
}()

// MARK: - Audio spooling (post-meeting refine pass)

// When MEETINK_SPOOL_DIR is set (launcher, keep_audio config), every
// extracted chunk is ALSO appended to a per-stream raw file (headerless
// s16le / 16 kHz / mono) — including chunks the RMS gate skips, so the
// stream timeline stays linear and refine.py can compute wall-clock
// timestamps from sample offsets alone. ~115 MB/hour/stream; the refine
// step deletes the spools on success.
let spoolDir = ProcessInfo.processInfo.environment["MEETINK_SPOOL_DIR"]

// Archive-rate spooling (MEETINK_SPOOL48=on, launcher sets it from the
// keep_audio config). The transcription pipeline stays 16 kHz end to end,
// but a 16 kHz archive caps playback at 8 kHz bandwidth — remote voices
// sound like AM radio no matter what post-processing does. When enabled,
// ScreenCaptureKit runs at 48 kHz (downsampled in-process for whisper)
// and a second spool pair keeps the full-bandwidth streams for the
// listenable m4a. ~345 MB/hour/stream, deleted with the 16 kHz spools.
let archiveRate: Double = 48000
let spool48Enabled = spoolDir != nil
    && (ProcessInfo.processInfo.environment["MEETINK_SPOOL48"] ?? "off") == "on"

// MARK: - Live echo cancellation (WebRTC AEC3)
//
// With speakers instead of headphones, the mic hears everything the
// speakers play and every remote utterance enters the pipeline twice
// (field report: the whole meeting duplicated, one copy labeled as the
// user). We uniquely HAVE the echo reference — the sys stream IS the
// speaker signal — so run the mic through AEC3 with sys as the far end.
// Gated twice: MEETINK_LIVE_AEC=on (launcher, live_aec config) and the
// vendored library present at build time (-D MEETINK_AEC + aec_shim).
let liveAECWanted = (ProcessInfo.processInfo.environment["MEETINK_LIVE_AEC"] ?? "off") == "on"
// Two independent cancellers: one at 16 kHz for the transcription path,
// one at 48 kHz for the archive spools — the playback m4a mixes the
// archive mic, and leaving it raw kept the speaker bleed (with all its
// room reverb) audible under the clean sys copy (field report: remote
// voice "echoy, lots of reverb").
var aecHandle: UnsafeMutableRawPointer? = nil
var aecHandle48: UnsafeMutableRawPointer? = nil

func aecFeedFar(_ samples: [Float], _ handle: UnsafeMutableRawPointer?) {
#if MEETINK_AEC
    guard let h = handle, !samples.isEmpty else { return }
    samples.withUnsafeBufferPointer {
        mk_aec_feed_far(h, $0.baseAddress, Int32(samples.count))
    }
#endif
}

func aecProcessNear(_ samples: inout [Float], _ handle: UnsafeMutableRawPointer?) {
#if MEETINK_AEC
    guard let h = handle, !samples.isEmpty else { return }
    samples.withUnsafeMutableBufferPointer {
        mk_aec_process_near(h, $0.baseAddress, Int32($0.count))
    }
#endif
}

func int16Data(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        let clamped = max(-1.0, min(1.0, sample))
        let int16 = Int16(clamped * 32767.0)
        withUnsafeBytes(of: int16.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

final class SpoolWriter: @unchecked Sendable {
    private let handle: FileHandle?

    init(path: String?) {
        guard let path = path else { handle = nil; return }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func append(_ samples: [Float]) {
        guard let handle = handle else { return }
        handle.write(int16Data(samples))
    }

    func close() {
        try? handle?.close()
    }
}

// MARK: - WAV Writer

func writeWAV(samples: [Float], to url: URL) throws {
    let dataSize = samples.count * 2
    let fileSize = 36 + dataSize
    var data = Data(capacity: 44 + dataSize)

    data.append(contentsOf: "RIFF".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
    data.append(contentsOf: "data".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

    for sample in samples {
        let clamped = max(-1.0, min(1.0, sample))
        let int16 = Int16(clamped * 32767.0)
        data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
    }

    try data.write(to: url)
}

// MARK: - Audio Buffer (thread-safe)

final class AudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var systemSamples: [Float] = []
    private var micSamples: [Float] = []
    private var _chunkIndex = 0

    var chunkIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return _chunkIndex
    }

    func appendSystem(_ samples: [Float]) {
        lock.lock()
        systemSamples.append(contentsOf: samples)
        lock.unlock()
    }

    func appendMic(_ samples: [Float]) {
        lock.lock()
        micSamples.append(contentsOf: samples)
        lock.unlock()
    }

    func tryExtractChunks() -> (system: [Float]?, mic: [Float]?)? {
        lock.lock()
        defer { lock.unlock() }

        let needed = samplesPerChunk
        guard systemSamples.count >= needed || micSamples.count >= needed else {
            return nil
        }

        var sysChunk: [Float]? = nil
        var micChunk: [Float]? = nil

        if systemSamples.count >= Int(sampleRate) {
            let take = min(systemSamples.count, needed)
            sysChunk = Array(systemSamples.prefix(take))
            systemSamples.removeFirst(take)
        }

        if micSamples.count >= Int(sampleRate) {
            let take = min(micSamples.count, needed)
            micChunk = Array(micSamples.prefix(take))
            micSamples.removeFirst(take)
        }

        _chunkIndex += 1
        return (system: sysChunk, mic: micChunk)
    }

    func flush() -> (system: [Float]?, mic: [Float]?) {
        lock.lock()
        defer { lock.unlock() }

        let sysChunk: [Float]? = systemSamples.count > Int(sampleRate) ? systemSamples : nil
        let micChunk: [Float]? = micSamples.count > Int(sampleRate) ? micSamples : nil

        systemSamples.removeAll()
        micSamples.removeAll()
        _chunkIndex += 1

        return (system: sysChunk, mic: micChunk)
    }
}

// MARK: - Simulation mode (test harness)

// MEETINK_SIM_SYS / MEETINK_SIM_MIC (raw s16le/16k/mono files, prepared by
// `meetink simulate`) feed file audio through the REAL pipeline at
// MEETINK_SIM_RATE x real time — same buffers the hardware taps fill, so
// the RMS gate, live whisper, live diarization, merger, spooling and the
// whole /stop pipeline behave exactly as in a meeting. No SCK, no mic,
// therefore NO permissions — runs anywhere, including CI-ish contexts.

func loadRawSamples(_ path: String) -> [Float] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    var out = [Float]()
    out.reserveCapacity(data.count / 2)
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        for v in buf.bindMemory(to: Int16.self) {
            out.append(Float(Int16(littleEndian: v)) / 32768.0)
        }
    }
    return out
}

func startSimFeeder(sysPath: String?, micPath: String?, rate: Double,
                    buffer: AudioBuffer) {
    let sys = sysPath.map(loadRawSamples) ?? []
    let mic = micPath.map(loadRawSamples) ?? []
    fputs("sim inputs: sys=\(sys.count / Int(sampleRate))s "
          + "mic=\(mic.count / Int(sampleRate))s rate=\(rate)x\n", stderr)
    Thread.detachNewThread {
        var si = 0, mi = 0
        let tick = 0.5
        let per = max(1, Int(Double(sampleRate) * tick * rate))
        while si < sys.count || mi < mic.count {
            if si < sys.count {
                let end = min(si + per, sys.count)
                buffer.appendSystem(Array(sys[si..<end]))
                si = end
            }
            if mi < mic.count {
                let end = min(mi + per, mic.count)
                buffer.appendMic(Array(mic[mi..<end]))
                mi = end
            }
            Thread.sleep(forTimeInterval: tick)
        }
        // The launcher's `meetink simulate` greps for this marker, drains,
        // and auto-runs stop.
        fputs("simulation input exhausted\n", stderr)
    }
}

// MARK: - Transcription via whisper-server

/// RMS floor below which a chunk is treated as silence and never sent to
/// whisper. The default is deliberately permissive (quiet speakers survive),
/// which means room tone can clear it — the filler-only hallucination filter
/// is the second line of defence. Raise via env if your mic picks up a noisy
/// room and fillers still leak through.
let audioRMSThreshold: Float =
    Float(ProcessInfo.processInfo.environment["MEETINK_RMS_THRESHOLD"] ?? "") ?? 0.005

func chunkRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
}

func hasAudio(_ samples: [Float], threshold: Float = audioRMSThreshold) -> Bool {
    return chunkRMS(samples) > threshold
}

/// Log a chunk's gate decision with its RMS so users can calibrate
/// MEETINK_RMS_THRESHOLD against their actual room noise floor: run a short
/// recording sitting silent, then eyeball the rms= values in the capture log
/// and pick a threshold between the silent floor and spoken levels.
func logGate(_ label: String, _ samples: [Float], sent: Bool) {
    let rms = chunkRMS(samples)
    fputs("  gate [\(label)]: rms=\(String(format: "%.4f", rms)) threshold=\(String(format: "%.4f", audioRMSThreshold)) → \(sent ? "transcribe" : "skip")\n", stderr)
}

/// Track last transcription per speaker for context carry-over
final class TranscriptContext: @unchecked Sendable {
    private let lock = NSLock()
    private var lastText: [String: String] = [:]

    func get(_ speaker: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastText[speaker] ?? ""
    }

    func set(_ speaker: String, text: String) {
        lock.lock()
        lastText[speaker] = String(text.suffix(200))
        lock.unlock()
    }
}

let transcriptContext = TranscriptContext()

// MARK: - Speaker Index (tinydiarize)

/// Monotonic speaker counter for tinydiarize. Not recycled — long meetings
/// can roll into AA, AB, … so labels stay unique within a session.
final class SpeakerIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var _index = 0

    func current() -> Int {
        lock.lock(); defer { lock.unlock() }
        return _index
    }

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        _index += 1
        return _index
    }
}

let speakerIndex = SpeakerIndex()

/// 0→A, 1→B, … 25→Z, 26→AA, 27→AB, …
func speakerLetter(_ i: Int) -> String {
    if i < 26 {
        return String(UnicodeScalar(65 + i)!)
    }
    let first = (i / 26) - 1
    let second = i % 26
    return "\(String(UnicodeScalar(65 + first)!))\(String(UnicodeScalar(65 + second)!))"
}

// MARK: - Hallucination Filter

let whisperHallucinations: Set<String> = [
    "(soft music)", "(laughing)", "(mumbling)", "(electronic beeping)",
    "(typing)", "(keyboard clicking)", "(silence)", "(wind blowing)",
    "(footsteps)", "(crickets chirping)", "(sighs)", "(clapping)",
    "(applause)", "(music)", "(music playing)", "(upbeat music)",
    "(gentle music)", "(birds chirping)", "(door opening)", "(door closing)",
    "(phone ringing)", "(coughing)", "(sneezing)", "(breathing)",
    "(background noise)", "(inaudible)", "(static)", "(beeping)",
    "[MUSIC PLAYING]", "[MUSIC]", "[BLANK_AUDIO]", "[Ding]",
    "(audio cuts out)", "(soft piano music)", "(piano music)",
]

/// YouTube-style hallucination phrases whisper generates from silence/noise
let youtubeHallucinations: [String] = [
    "thank you for watching", "thanks for watching", "please subscribe",
    "like the video", "hit the bell", "see you next time",
    "if you enjoyed this video", "subscribe to my channel",
    "i'll see you in the next", "don't forget to subscribe",
    "leave a comment", "find me on my website",
    "please subscribe and like", "i will be back",
    "we'll be right back", "[end of audio]", "[sound]",
    "done.", "done!", "thank you.",
]

/// Filler tokens whisper hallucinates from near-silence. Kept conservative:
/// only sounds that carry no content on their own. A chunk made up entirely
/// of these is dropped; mixed with real words they pass through.
let fillerTokens: Set<String> = [
    "you", "yeah", "um", "uh", "hmm", "hm", "mm", "mmm", "mm-hmm", "mmhmm",
    "uh-huh", "okay", "ok", "kay", "done",
]

func isHallucination(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    let lower = trimmed.lowercased()
    // Exact match against known sounds
    if whisperHallucinations.contains(trimmed) { return true }
    // Case-insensitive match
    for h in whisperHallucinations {
        if lower == h.lowercased() { return true }
    }
    // Pattern: entire text is a parenthetical like (some noise)
    if lower.hasPrefix("(") && lower.hasSuffix(")") && lower.count < 40 { return true }
    // Same in brackets: [typing] [silence] [clears throat] [SQUEAK] — whisper
    // emits these too, especially on the system-audio stream during quiet
    // moments. Same length cap as the parenthetical rule.
    if lower.hasPrefix("[") && lower.hasSuffix("]") && lower.count < 40 { return true }
    // And in asterisks: *Sigh* *Silence* *Crickets* *Door opens* — a third
    // annotation style whisper uses for non-speech noise. Same length cap.
    if lower.hasPrefix("*") && lower.hasSuffix("*") && lower.count < 40 { return true }
    // Filler-only chunks. Near-silence that clears the RMS gate makes whisper
    // hallucinate fillers with punctuation ("Okay.", "Mm-hmm.", "'Kay. 'Kay."),
    // so compare token-by-token with punctuation stripped, and drop the chunk
    // only when *every* token is a filler — fillers inside real sentences
    // ("okay, let's ship it") survive.
    let fillerSeparators = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-'"))
        .inverted
    let tokens = lower
        .components(separatedBy: fillerSeparators)
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
        .filter { !$0.isEmpty }
    if !tokens.isEmpty && tokens.allSatisfy({ fillerTokens.contains($0) }) { return true }

    // Copyright/watermark hallucinations
    if lower.contains("© ") || lower.contains("copyright") || lower.contains("bf-watch") { return true }
    // "check out the links in the description" style
    if lower.contains("links in the description") || lower.contains("check out the link") { return true }

    // YouTube-style hallucinations (substring match)
    for phrase in youtubeHallucinations {
        if lower.contains(phrase) { return true }
    }

    // Whisper prompt-leakage. The initial prompt biases decoding, but during
    // quiet/unclear stretches whisper sometimes regurgitates the prompt
    // verbatim. We ship an empty prompt by default, but filter against the
    // historical default + obvious prompt-shaped phrases for safety.
    let promptLeakPhrases = [
        "use natural punctuation",
        "the following is a transcription",
        "full sentences",
    ]
    for phrase in promptLeakPhrases {
        if lower.contains(phrase) { return true }
    }

    // Repetition loop detection: if a short phrase repeats 3+ times
    if hasRepetitionLoop(lower) { return true }

    return false
}

func hasRepetitionLoop(_ text: String) -> Bool {
    let words = text.split(separator: " ").map(String.init)
    guard words.count >= 9 else { return false }

    // Check for repeating N-grams (2-6 words) appearing 3+ times
    for n in 2...min(6, words.count / 3) {
        var ngramCounts: [String: Int] = [:]
        for i in 0...(words.count - n) {
            let ngram = words[i..<(i + n)].joined(separator: " ")
            ngramCounts[ngram, default: 0] += 1
            if ngramCounts[ngram]! >= 3 {
                return true
            }
        }
    }
    return false
}

// MARK: - Sentence Merger (thread-safe)

final class TranscriptMerger: @unchecked Sendable {
    private let lock = NSLock()
    private var currentSpeaker: String = ""
    private var currentOrigin: String = ""
    private var currentTimestamp: String = ""
    private var currentText: String = ""
    private var lastAddTime: Date = Date()
    private var bufferStartTime: Date = Date()
    // The idle gap must exceed the steady-state interval between chunk adds
    // (3 s chunk cadence + transcription latency), or flushIfStale fires
    // between every pair of chunks and same-speaker merging never happens —
    // one sentence per 3 s chunk instead of one line per utterance.
    private let mergeGapSeconds: TimeInterval =
        TimeInterval(ProcessInfo.processInfo.environment["MEETINK_MERGE_GAP_S"] ?? "") ?? 4.0
    // How long one line may keep accumulating before it's forced out. Larger
    // = fewer, longer lines but the live tail lags further behind the audio.
    private let maxBufferAgeSeconds: TimeInterval =
        TimeInterval(ProcessInfo.processInfo.environment["MEETINK_MERGE_MAX_BUFFER_S"] ?? "") ?? 8.0

    func add(timestamp: String, speaker: String, text: String, origin: String) {
        lock.lock()

        // Never merge across origins, even under the same label: a mic
        // chunk and a sys chunk both labeled GREG are the user's voice AND
        // its remote echo — coalescing them interleaves near-identical
        // sentences INSIDE one line (field case: every sentence doubled).
        // Kept as separate lines, the refine pass's echo dedup can kill
        // the sys copy cleanly.
        if speaker == currentSpeaker && origin == currentOrigin && !currentText.isEmpty {
            let age = Date().timeIntervalSince(bufferStartTime)
            if age > maxBufferAgeSeconds {
                let flushSpeaker = currentSpeaker
                let flushTimestamp = currentTimestamp
                let flushText = currentText

                currentTimestamp = timestamp
                currentText = text
                bufferStartTime = Date()
                lastAddTime = Date()
                lock.unlock()

                writeLine(timestamp: flushTimestamp, speaker: flushSpeaker, text: flushText)
                return
            }

            // Same speaker, still fresh — append
            currentText += " " + text
            lastAddTime = Date()
            lock.unlock()
        } else {
            // Different speaker — flush old, start new
            let flushSpeaker = currentSpeaker
            let flushTimestamp = currentTimestamp
            let flushText = currentText

            currentSpeaker = speaker
            currentOrigin = origin
            currentTimestamp = timestamp
            currentText = text
            bufferStartTime = Date()
            lastAddTime = Date()
            lock.unlock()

            if !flushText.isEmpty {
                writeLine(timestamp: flushTimestamp, speaker: flushSpeaker, text: flushText)
            }
        }
    }

    /// Call periodically to flush stale buffered text
    func flushIfStale() {
        lock.lock()
        let idleElapsed = Date().timeIntervalSince(lastAddTime)
        let bufferAge = Date().timeIntervalSince(bufferStartTime)
        let shouldFlush = !currentText.isEmpty && (idleElapsed > mergeGapSeconds || bufferAge > maxBufferAgeSeconds)
        guard shouldFlush else {
            lock.unlock()
            return
        }
        let speaker = currentSpeaker
        let timestamp = currentTimestamp
        let text = currentText
        currentText = ""
        currentSpeaker = ""
        lock.unlock()

        writeLine(timestamp: timestamp, speaker: speaker, text: text)
    }

    /// Force flush remaining buffer (on shutdown)
    func flushAll() {
        lock.lock()
        let speaker = currentSpeaker
        let timestamp = currentTimestamp
        let text = currentText
        currentText = ""
        currentSpeaker = ""
        lock.unlock()

        if !text.isEmpty {
            writeLine(timestamp: timestamp, speaker: speaker, text: text)
        }
    }

    private func writeLine(timestamp: String, speaker: String, text: String) {
        let line = "[\(timestamp)] \(speaker): \(text)\n"
        let fileURL = URL(fileURLWithPath: transcriptPath)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

let transcriptMerger = TranscriptMerger()

// MARK: - Diarization with Audio Buffering

/// Track diarize-server availability with automatic retry
var diarizeFailCount = 0
let diarizeMaxFails = 3
let diarizeRetryInterval = 10  // retry every N chunks after failure

/// Buffer system audio samples for diarization (longer = more stable embeddings)
final class DiarizeAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastSpeaker: String = "THEM"
    // 5s windows with 1.5s overlap. Shorter windows are more likely to be
    // single-speaker — a 10s window during fast back-and-forth produced a
    // mixed embedding that consistently merged both voices into one cluster.
    // Speaker-embedding nets need ~1s minimum to be stable, so 5s gives the
    // model enough signal while still catching turn changes faster than
    // the prior 10s. Side effect: more clusters; if one voice splits across
    // two clusters the user can recover with `/profile merge A B`.
    private let targetSamples = Int(sampleRate) * 5

    /// Add samples and return WAV data if buffer is full enough
    func addAndMaybeFlush(_ newSamples: [Float]) -> Data? {
        lock.lock()
        samples.append(contentsOf: newSamples)

        guard samples.count >= targetSamples else {
            lock.unlock()
            return nil
        }

        // Keep ~1.5s for overlap so consecutive embeddings share enough
        // context for stable matching, but not so much that two windows
        // see the same turn change.
        let keepSamples = Int(Double(sampleRate) * 1.5)
        let toProcess = samples
        samples = Array(samples.suffix(keepSamples))
        lock.unlock()

        // Convert to WAV data
        guard let wavData = try? samplesToWAV(toProcess) else { return nil }
        return wavData
    }

    /// Get current speaker assignment
    func getCurrentSpeaker() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lastSpeaker
    }

    func setCurrentSpeaker(_ speaker: String) {
        lock.lock()
        lastSpeaker = speaker
        lock.unlock()
    }

    /// Flush whatever is left (for shutdown)
    func flush() -> Data? {
        lock.lock()
        guard samples.count >= Int(sampleRate) * 2 else {
            lock.unlock()
            return nil
        }
        let toProcess = samples
        samples.removeAll()
        lock.unlock()
        return try? samplesToWAV(toProcess)
    }

    private func samplesToWAV(_ samples: [Float]) throws -> Data {
        let dataSize = samples.count * 2
        let fileSize = 36 + dataSize
        var data = Data(capacity: 44 + dataSize)

        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
        }

        return data
    }
}

let diarizeBuffer = DiarizeAudioBuffer()

func diarizeSpeaker(wavData: Data, chunkIndex: Int) -> String? {
    // If recently failed, only retry periodically
    if diarizeFailCount >= diarizeMaxFails {
        if chunkIndex % diarizeRetryInterval != 0 { return nil }
        fputs("  diarize-server: retrying...\n", stderr)
    }

    let url = URL(string: "http://127.0.0.1:\(diarizePort)/identify")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
    request.setValue(String(wavData.count), forHTTPHeaderField: "Content-Length")
    request.httpBody = wavData

    let semaphore = DispatchSemaphore(value: 0)
    var speakerName: String? = nil

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }

        if error != nil {
            diarizeFailCount += 1
            if diarizeFailCount == diarizeMaxFails {
                fputs("  diarize-server unavailable, will retry every \(diarizeRetryInterval) chunks\n", stderr)
            }
            return
        }

        // Server is back
        if diarizeFailCount > 0 {
            fputs("  diarize-server reconnected\n", stderr)
            diarizeFailCount = 0
        }

        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let speaker = json["speaker"] as? String,
              speaker != "unknown" else { return }

        speakerName = speaker
    }
    task.resume()
    semaphore.wait()

    return speakerName
}

func transcribe(wavURL: URL, chunkIndex: Int, speaker: String) {
    let startTime = Date()
    let timestamp = DateFormatter.localizedString(from: startTime, dateStyle: .none, timeStyle: .medium)

    let wavData = (try? Data(contentsOf: wavURL)) ?? Data()

    // Per-chunk diarization. We used to buffer ~5s of system audio before
    // calling /identify, but that meant fast back-and-forth got embedded as
    // a *mix* of both voices and consistently merged into one cluster. By
    // identifying each 3s chunk on its own, every transcript line gets its
    // own speaker decision — close to per-turn resolution for normal
    // conversation pace. /identify is synchronous (~300ms) and runs before
    // whisper-server, so the transcript line we write below already has
    // the right label. diarizeBuffer's `lastSpeaker` is now just a fallback
    // for the first chunks before any /identify completes.
    if speaker == "THEM" && !wavData.isEmpty {
        if let identified = diarizeSpeaker(wavData: wavData, chunkIndex: chunkIndex) {
            let prev = diarizeBuffer.getCurrentSpeaker()
            // Label casing is the server's job now: enrolled names arrive
            // pre-uppercased (MELANIE), cluster labels arrive as "Speaker 1".
            let next = identified
            diarizeBuffer.setCurrentSpeaker(next)
            if prev != next {
                fputs("  speaker changed: \(prev) -> \(next)\n", stderr)
            }
        }
    }

    // Send to whisper-server via HTTP multipart
    let url = URL(string: "http://127.0.0.1:\(whisperPort)/inference")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 30

    let boundary = "----MeetingCapture\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()

    // Audio file
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(wavData)
    body.append("\r\n".data(using: .utf8)!)

    // Response format
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
    body.append("text\r\n".data(using: .utf8)!)

    // Temperature
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"temperature\"\r\n\r\n".data(using: .utf8)!)
    body.append("0.0\r\n".data(using: .utf8)!)

    // Domain vocabulary + context carry-over prompt
    let effectiveSpeaker = speaker  // Use original for context lookup
    var prompt = ""
    if let domainPrompt = try? String(contentsOfFile: whisperPromptPath, encoding: .utf8) {
        prompt = domainPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let previousText = transcriptContext.get(effectiveSpeaker)
    if !previousText.isEmpty {
        prompt += " " + previousText
    }
    if !prompt.isEmpty {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(prompt)\r\n".data(using: .utf8)!)
    }

    body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = body

    let semaphore = DispatchSemaphore(value: 0)
    var resultText = ""

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }

        if let error = error {
            fputs("  whisper-server error: \(error.localizedDescription)\n", stderr)
            return
        }

        guard let data = data else { return }
        resultText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    task.resume()
    semaphore.wait()

    // Clean up chunk file
    try? FileManager.default.removeItem(at: wavURL)

    let elapsed = String(format: "%.1fs", Date().timeIntervalSince(startTime))
    let text = resultText

    if text.isEmpty || text == "[BLANK_AUDIO]" {
        fputs("  chunk \(chunkIndex) [\(speaker)]: [silence]\n", stderr)
        return
    }

    // Tinydiarize-trained whisper models emit [SPEAKER_TURN] markers between
    // segments where the active speaker changes. Only meaningful for THEM
    // (system audio may carry multiple voices); the mic stream is single-source.
    let isTdrz = (speaker == "THEM") && text.contains("[SPEAKER_TURN]")

    if isTdrz {
        let segments = text.components(separatedBy: "[SPEAKER_TURN]")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for (i, segment) in segments.enumerated() {
            if isHallucination(segment) {
                fputs("  chunk \(chunkIndex) seg\(i): [filtered: \(segment.prefix(30))]\n", stderr)
                continue
            }
            // Segment 0 continues the previous speaker (so a single voice
            // spanning chunk boundaries keeps its label); each subsequent
            // segment is a new speaker (monotonically increasing index).
            let idx = (i == 0) ? speakerIndex.current() : speakerIndex.increment()
            let label = "THEM-\(speakerLetter(idx))"
            transcriptContext.set(label, text: segment)
            transcriptMerger.add(timestamp: timestamp, speaker: label, text: segment,
                                 origin: "sys")
            fputs("  chunk \(chunkIndex) [\(label)]: \(segment.prefix(70))... (\(elapsed))\n", stderr)
        }
        return
    }

    // Non-tdrz path: THEM uses whatever the diarize-server most recently
    // returned via the 10s embedding window — either a matched profile name
    // (e.g. "ALICE") or a cluster label ("Speaker 1", "Speaker 2", …) for voices
    // that don't match any enrolled profile. Stays "THEM" only when the
    // server is unreachable or no window has been processed yet. ME stays ME.
    if isHallucination(text) {
        fputs("  chunk \(chunkIndex) [\(speaker)]: [filtered: \(text.prefix(30))]\n", stderr)
        return
    }

    let finalSpeaker: String
    if speaker == "THEM" {
        let bufferedSpeaker = diarizeBuffer.getCurrentSpeaker()
        finalSpeaker = bufferedSpeaker == "THEM" ? "THEM" : bufferedSpeaker
    } else {
        finalSpeaker = speaker
    }

    // Live echo-kill: a SYSTEM-audio voice identified as the user is, by
    // definition, an echo — you are never remote in your own meeting. This
    // happens when another participant's client (speakers + mic, room
    // system) sends the user's voice back. Requires an enrolled profile;
    // the refine pass catches what this misses.
    let origin = (speaker == "THEM") ? "sys" : "mic"
    if origin == "sys" && finalSpeaker == meName {
        fputs("  chunk \(chunkIndex) [echo]: sys voice identified as \(meName) — dropped\n", stderr)
        return
    }

    transcriptContext.set(speaker, text: text)
    transcriptMerger.add(timestamp: timestamp, speaker: finalSpeaker, text: text,
                         origin: origin)
    fputs("  chunk \(chunkIndex) [\(finalSpeaker)]: \(text.prefix(70))... (\(elapsed))\n", stderr)
}

// MARK: - Stream Delegate

/// Linear-interpolation resampler — the fallback when AVAudioConverter
/// can't be built. No anti-alias filter, so only for edge cases; the
/// converter path is the quality path.
func resampleLinear(_ samples: [Float], from inputRate: Double,
                    to outputRate: Double) -> [Float] {
    let ratio = outputRate / inputRate
    let outCount = Int(Double(samples.count) * ratio)
    return (0..<outCount).map { i -> Float in
        let srcIdx = Double(i) / ratio
        let idx = Int(srcIdx)
        let frac = Float(srcIdx - Double(idx))
        if idx + 1 < samples.count {
            return samples[idx] * (1 - frac) + samples[idx + 1] * frac
        }
        return idx < samples.count ? samples[idx] : 0
    }
}

class CaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
    let buffer: AudioBuffer
    let targetFormat: AVAudioFormat
    /// 48 kHz sys archive spool; nil when archive spooling is off.
    let archiveSpool: SpoolWriter?
    // Persistent downsampler for the whisper path when SCK runs at the
    // archive rate. One instance across callbacks — AVAudioConverter
    // carries filter state internally, so the stream stays continuous
    // (rebuilding it per buffer would click at every boundary).
    private var downConverter: AVAudioConverter?
    private var downConverterRate: Double = 0

    init(buffer: AudioBuffer, archiveSpool: SpoolWriter? = nil) {
        self.buffer = buffer
        self.archiveSpool = archiveSpool
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }

        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc!)!.pointee

        let float32Samples: [Float]
        if asbd.mBitsPerChannel == 32 {
            float32Samples = data.withUnsafeBytes { ptr in
                let floatPtr = ptr.bindMemory(to: Float.self)
                return Array(floatPtr)
            }
        } else {
            return
        }

        let channels = Int(asbd.mChannelsPerFrame)
        let inputRate = asbd.mSampleRate
        let monoSamples: [Float]

        if channels > 1 {
            let frameCount = float32Samples.count / channels
            monoSamples = (0..<frameCount).map { frame in
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += float32Samples[frame * channels + ch]
                }
                return sum / Float(channels)
            }
        } else {
            monoSamples = float32Samples
        }

        // Full-bandwidth archive copy first, straight from the stream —
        // it is also the 48 kHz canceller's far-end reference.
        if let archiveSpool {
            let arch = abs(inputRate - archiveRate) <= 1.0
                ? monoSamples
                : resampleLinear(monoSamples, from: inputRate, to: archiveRate)
            aecFeedFar(arch, aecHandle48)
            archiveSpool.append(arch)
        }

        // Whisper path: 16 kHz. When SCK delivers 16 kHz directly (archive
        // spooling off) this is a straight append, exactly as before.
        func deliver(_ samples: [Float]) {
            // The sys stream is the AEC's far-end reference — feed it
            // before it lands in the transcription buffer.
            aecFeedFar(samples, aecHandle)
            buffer.appendSystem(samples)
        }
        if abs(inputRate - sampleRate) <= 1.0 {
            deliver(monoSamples)
            return
        }
        // Downsample with AVAudioConverter (filtered, stateful) — linear
        // interpolation without a low-pass would alias >8 kHz content
        // into the speech band and degrade transcription.
        if downConverter == nil || downConverterRate != inputRate {
            if let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: inputRate, channels: 1,
                                         interleaved: false) {
                downConverter = AVAudioConverter(from: inFmt, to: targetFormat)
                downConverterRate = inputRate
            }
        }
        if let converter = downConverter,
           let inBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                           frameCapacity: AVAudioFrameCount(monoSamples.count)) {
            inBuffer.frameLength = AVAudioFrameCount(monoSamples.count)
            monoSamples.withUnsafeBufferPointer { src in
                inBuffer.floatChannelData![0].update(from: src.baseAddress!,
                                                     count: monoSamples.count)
            }
            let ratio = sampleRate / inputRate
            let outputFrameCount = AVAudioFrameCount(Double(monoSamples.count) * ratio)
            if let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                frameCapacity: outputFrameCount) {
                let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
                    outStatus.pointee = .haveData
                    return inBuffer
                }
                if status == .haveData, let floatData = outBuffer.floatChannelData {
                    deliver(Array(UnsafeBufferPointer(
                        start: floatData[0], count: Int(outBuffer.frameLength))))
                    return
                }
            }
        }
        // Converter unavailable — old linear-interp fallback.
        deliver(resampleLinear(monoSamples, from: inputRate, to: sampleRate))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        fputs("Screen capture stopped: \(error)\n", stderr)
    }
}

// MARK: - Sample recording (for /profile add)

/// Record N seconds of microphone audio at 16kHz mono and write a WAV file.
/// Used by /profile add to enroll voice samples — kept here so we don't need
/// a separate brew dependency (sox/ffmpeg) for recording.
func recordSample(to path: String, seconds: Double) throws {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: 1, interleaved: false
    )!
    let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

    let lock = NSLock()
    var collected: [Float] = []

    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { inBuffer, _ in
        guard let converter = converter else { return }
        let ratio = sampleRate / inputFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }
        let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
            outStatus.pointee = .haveData
            return inBuffer
        }
        if status == .haveData, let floatData = outBuffer.floatChannelData {
            let s = Array(UnsafeBufferPointer(start: floatData[0], count: Int(outBuffer.frameLength)))
            lock.lock(); collected.append(contentsOf: s); lock.unlock()
        }
    }

    try engine.start()
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()
    inputNode.removeTap(onBus: 0)

    try writeWAV(samples: collected, to: URL(fileURLWithPath: path))
    fputs("recorded \(collected.count) samples (\(Double(collected.count) / sampleRate)s) → \(path)\n", stderr)
}

// MARK: - Main

@main
struct LocalSpeechCapture {
    static func main() async {
        // Sub-mode: `meetink-capture --record-sample <path> <seconds>`
        // Records mic audio and exits. Used by /profile add for enrollment.
        let args = CommandLine.arguments
        if args.count >= 4 && args[1] == "--record-sample" {
            do {
                try recordSample(to: args[2], seconds: Double(args[3]) ?? 5.0)
                Foundation.exit(0)
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }

        do {
            try await run()
        } catch {
            fputs("Fatal error: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run() async throws {
        let transcriptDir = (transcriptPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: transcriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: chunkDir, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: whisperModel) else {
            fputs("Error: whisper model not found at \(whisperModel)\n", stderr)
            Foundation.exit(1)
        }

        // Wait for whisper-server to be ready
        fputs("Waiting for whisper-server...\n", stderr)
        var serverReady = false
        for _ in 0..<30 {
            let url = URL(string: "http://127.0.0.1:\(whisperPort)/")!
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            let task = URLSession.shared.dataTask(with: url) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    ok = true
                }
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()
            if ok { serverReady = true; break }
            Thread.sleep(forTimeInterval: 1.0)
        }

        guard serverReady else {
            fputs("Error: whisper-server not responding on port \(whisperPort)\n", stderr)
            Foundation.exit(1)
        }
        fputs("whisper-server ready\n", stderr)

        // Initialize transcript file. The `# user:` line embeds who is
        // running this session so downstream tooling (titling, /ask) can
        // map ME-equivalent labels back to a real person without guessing.
        // titling.sh's _transcript_body() already strips lines starting
        // with "# " before feeding the model, so this stays out of titles.
        //
        // /watch additionally injects MEETINK_EVENT_* env vars when
        // auto-recording from a calendar event. Each present field
        // becomes a header line so /ask can answer questions like
        // "who was on this call" or "what was the agenda" off the
        // transcript alone, with no separate sidecar file.
        var header = "# Meeting Transcript\n"
        if meName != "ME" {
            header += "# user: \(meName)\n"
        }
        let env = ProcessInfo.processInfo.environment
        let metadataKeys: [(envKey: String, headerKey: String)] = [
            ("MEETINK_EVENT_TITLE",     "event"),
            ("MEETINK_EVENT_INSTANT",   "instant"),
            ("MEETINK_EVENT_SOURCE",    "source"),
            ("MEETINK_EVENT_START",     "scheduled_start"),
            ("MEETINK_EVENT_END",       "scheduled_end"),
            ("MEETINK_EVENT_ATTENDEES", "attendees"),
            ("MEETINK_EVENT_LOCATION",  "location"),
            ("MEETINK_EVENT_RSVP",      "rsvp"),
            ("MEETINK_EVENT_CALENDAR",  "calendar"),
            ("MEETINK_EVENT_PROJECT",   "project"),
        ]
        for (envKey, headerKey) in metadataKeys {
            if let v = env[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !v.isEmpty {
                // Single-line header values only. Newlines / CRs would
                // break the parser convention (one fact per `# k: v` line);
                // collapse them into spaces.
                let oneLine = v.replacingOccurrences(of: "\n", with: " ")
                                .replacingOccurrences(of: "\r", with: " ")
                header += "# \(headerKey): \(oneLine)\n"
            }
        }
        // Notes can be long (Google Meet / Calendly auto-blurbs are huge).
        // Truncate at ~500 chars so we don't bloat the transcript header
        // beyond what's useful for /ask. The full event blob lives in
        // Calendar.app for anyone who really needs it.
        if let raw = env["MEETINK_EVENT_NOTES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
                              .replacingOccurrences(of: "\r", with: " ")
            let truncated = oneLine.count > 500
                ? String(oneLine.prefix(500)) + "…"
                : oneLine
            header += "# description: \(truncated)\n"
        }
        header += "Started: \(ISO8601DateFormatter().string(from: Date()))\n\n"
        try header.write(toFile: transcriptPath, atomically: true, encoding: .utf8)

        let audioBuffer = AudioBuffer()

        // --- Simulation mode: file audio instead of hardware ---
        let simSysPath = ProcessInfo.processInfo.environment["MEETINK_SIM_SYS"]
        let simMicPath = ProcessInfo.processInfo.environment["MEETINK_SIM_MIC"]
        let simMode = simSysPath != nil || simMicPath != nil
        let simRate = Double(ProcessInfo.processInfo.environment["MEETINK_SIM_RATE"] ?? "1") ?? 1.0
        if simMode {
            fputs("SIMULATION MODE — file audio through the real pipeline, no hardware, no permissions\n", stderr)
            startSimFeeder(sysPath: simSysPath, micPath: simMicPath,
                           rate: simRate, buffer: audioBuffer)
        }

        // --- System audio via ScreenCaptureKit ---
        // BOTH references must outlive this block. SCStream does NOT
        // strongly retain its delegate/stream-output — when the sim-mode
        // refactor moved `let delegate` to block scope, the delegate
        // deallocated at the closing brace and SCK kept "capturing" into a
        // dead object: startCapture() succeeds, zero errors, zero samples,
        // 0-byte sys spool (field-debugged mid-Zoom-call 2026-08-04).
        // --- Spool writers (no-ops when MEETINK_SPOOL_DIR is unset) ---
        // Created before the capture sources: the SCK delegate and mic tap
        // write the 48 kHz archive spools directly from their callbacks
        // (the 16 kHz pair still flows through the chunk loop below, so
        // sim mode spools exactly as before — sim feeds AudioBuffer and
        // never touches the archive writers, whose files stay empty and
        // are ignored by the mix's size guard).
        var spoolSys = SpoolWriter(path: nil)
        var spoolMic = SpoolWriter(path: nil)
        var spool48Sys = SpoolWriter(path: nil)
        var spool48Mic = SpoolWriter(path: nil)
        if let dir = spoolDir {
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            spoolSys = SpoolWriter(path: "\(dir)/session-sys.raw")
            spoolMic = SpoolWriter(path: "\(dir)/session-mic.raw")
            if spool48Enabled {
                spool48Sys = SpoolWriter(path: "\(dir)/session-sys.48k.raw")
                spool48Mic = SpoolWriter(path: "\(dir)/session-mic.48k.raw")
            }
            fputs("Spooling session audio to \(dir) (for post-meeting refine"
                  + (spool48Enabled ? " + 48 kHz archive" : "") + ")\n", stderr)
        }

#if MEETINK_AEC
        if liveAECWanted && !simMode {
            aecHandle = mk_aec_create(Int32(sampleRate))
            // 16 kHz transcription path ONLY — the archive spools stay
            // raw for natural playback (see the mic tap comment).
            fputs(aecHandle != nil
                  ? "Live echo cancellation on (WebRTC AEC3, sys as reference, transcription path)\n"
                  : "Live echo cancellation requested but AEC3 init failed\n",
                  stderr)
        }
#else
        if liveAECWanted && !simMode {
            fputs("live_aec=on but this build has no AEC3 — run `meetink aec install` and rebuild\n", stderr)
        }
#endif

        var scStream: SCStream? = nil
        var scDelegate: CaptureDelegate? = nil
        if !simMode {
        fputs("Requesting screen capture permission...\n", stderr)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            fputs("\nError: Screen recording permission denied.\n", stderr)
            fputs("Fix: System Settings > Privacy & Security > Screen & System Audio Recording\n", stderr)
            fputs("       → Enable your terminal app\n", stderr)
            Foundation.exit(1)
        }

        guard let display = content.displays.first else {
            fputs("Error: no display found\n", stderr)
            Foundation.exit(1)
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Archive spooling wants the full-bandwidth stream; the delegate
        // downsamples to 16 kHz for whisper. With archiving off SCK
        // delivers 16 kHz directly — byte-identical to the old behavior.
        config.sampleRate = spool48Enabled ? Int(archiveRate) : Int(sampleRate)
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let delegate = CaptureDelegate(buffer: audioBuffer,
                                       archiveSpool: spool48Enabled ? spool48Sys : nil)

        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: DispatchQueue(label: "system-audio"))

        do {
            try await stream.startCapture()
        } catch {
            fputs("\nError starting capture: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }

        scStream = stream
        scDelegate = delegate
        fputs("System audio capture started\n", stderr)
        }

        // --- Microphone via AVAudioEngine ---
        //
        // The mic stream is fragile mid-recording: users swap headphones,
        // toggle Bluetooth, change the system default input, or have a
        // device silently stop delivering samples. AVAudioEngine doesn't
        // catch all of these. We layer three redundant signal sources so
        // a wedged tap is detected within ~5 s:
        //
        //   1. AVAudioEngineConfigurationChange — the documented hook.
        //      Fires for sample-rate changes and some default-input
        //      switches, but missing for many real-world swap patterns
        //      (silent BT drop, manual System Settings change while the
        //      engine is bound, Audio MIDI Setup tweaks).
        //   2. CoreAudio HAL listener on kAudioHardwarePropertyDefault-
        //      InputDevice. Lower-level than AVAudioEngine — fires on
        //      EVERY system-default-input change regardless of whether
        //      AVAudioEngine notices.
        //   3. Heartbeat watchdog. Tracks the wall-clock time of the
        //      most recent mic sample. If the engine claims to be
        //      running but no samples have landed for > MIC_STALL_S,
        //      force a rebuild. Catches "silent drop" patterns where
        //      the device handle is technically valid but isn't
        //      delivering audio.
        //
        // All three converge on the same rebuild path, serialised on a
        // dedicated queue so a flurry of signals doesn't fire concurrent
        // engine.stop() / installTap() calls.
        //
        // (Simulation mode skips ALL of this — the feeder thread fills the
        // same AudioBuffer directly, so no mic hardware, no permissions.)
        var micEngineRef: AVAudioEngine? = nil
        var micWatchdogRef: DispatchSourceTimer? = nil
        if !simMode {
        let engine = AVAudioEngine()

        // Acoustic echo cancellation — OPT-IN (MEETINK_AEC=on), default off.
        // The idea: without headphones the mic hears the system audio and
        // every remote utterance lands twice, once mislabeled as the user.
        // Apple's voice-processing mode would cancel that at the OS level —
        // but enabled on this input-only engine it delivered PURE ZEROS on
        // real hardware (field case: permissions fine, "recording", mic
        // rms=0.0000 while the user talked). VPIO wants a fully configured
        // input/output pair; wiring that properly is future work. Until
        // then: headphones give a clean live transcript, and the refine
        // pass's echo suppression scrubs speaker-echo from the transcript
        // that actually gets kept.
        if (ProcessInfo.processInfo.environment["MEETINK_AEC"] ?? "off") == "on" {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                fputs("Mic voice processing (AEC) enabled — EXPERIMENTAL, verify the mic gate shows non-zero rms\n", stderr)
            } catch {
                fputs("Voice processing unavailable (\(error))\n", stderr)
            }
        }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

        // Shared heartbeat state. The tap closure updates the timestamp on
        // every delivered buffer; the watchdog reads it on a 5 s tick. NSLock
        // because both can run on arbitrary queues.
        let micHeartbeatLock = NSLock()
        var lastMicSampleAt: TimeInterval = Date().timeIntervalSince1970
        let micStallThresholdSeconds: TimeInterval = 15.0
        let updateMicHeartbeat: () -> Void = {
            micHeartbeatLock.lock()
            lastMicSampleAt = Date().timeIntervalSince1970
            micHeartbeatLock.unlock()
        }

        let installMicTap: () throws -> Void = {
            let inputNode = engine.inputNode
            // During a device swap the engine briefly reports a zero-rate
            // format; installing a tap on it raises. Skip and wait for the
            // next configuration-change notification to deliver a real one.
            guard inputNode.outputFormat(forBus: 0).sampleRate > 0 else {
                fputs("Mic input format not ready yet, will retry on next configuration change\n", stderr)
                return
            }
            // format: nil — the tap adopts whatever format the node has AT
            // INSTALL TIME. Passing a queried format instead is a crash: if
            // the device flips between the query and the install (AirPods
            // dropping call mode when a meeting ends — 24 kHz HFP mic),
            // installTap raises an Objective-C NSException that Swift
            // try/catch CANNOT catch, and the whole process dies mid-flush
            // (field crash: 71-min call, no Ended footer, no refine, spools
            // orphaned). The converter is built lazily from each buffer's
            // actual format for the same reason.
            var converter: AVAudioConverter? = nil
            var converterInputFormat: AVAudioFormat? = nil
            // Second lazy converter for the 48 kHz archive spool — same
            // per-buffer-format rebuild rule as above (AirPods flip rates
            // mid-call), independent instance so each conversion keeps its
            // own filter state.
            var converter48: AVAudioConverter? = nil
            var converter48InputFormat: AVAudioFormat? = nil
            let archiveFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: archiveRate,
                                              channels: 1, interleaved: false)!
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { inBuffer, _ in
                let inFormat = inBuffer.format
                guard inFormat.sampleRate > 0 else { return }
                if converterInputFormat != inFormat {
                    converter = AVAudioConverter(from: inFormat, to: targetFormat)
                    converterInputFormat = inFormat
                }
                guard let converter = converter else { return }
                let ratio = sampleRate / inFormat.sampleRate
                let outputFrameCount = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio)
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }
                let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
                    outStatus.pointee = .haveData
                    return inBuffer
                }
                if status == .haveData, let floatData = outBuffer.floatChannelData {
                    var samples = Array(UnsafeBufferPointer(start: floatData[0], count: Int(outBuffer.frameLength)))
                    // Subtract the speaker bleed (sys is the reference)
                    // before the gate/whisper/spool ever see it.
                    aecProcessNear(&samples, aecHandle)
                    audioBuffer.appendMic(samples)
                    updateMicHeartbeat()
                }
                if spool48Enabled {
                    if converter48InputFormat != inFormat {
                        converter48 = AVAudioConverter(from: inFormat, to: archiveFormat)
                        converter48InputFormat = inFormat
                    }
                    guard let converter48 = converter48 else { return }
                    let ratio48 = archiveRate / inFormat.sampleRate
                    let outCount48 = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio48)
                    guard let out48 = AVAudioPCMBuffer(pcmFormat: archiveFormat, frameCapacity: outCount48) else { return }
                    let status48 = converter48.convert(to: out48, error: nil) { _, outStatus in
                        outStatus.pointee = .haveData
                        return inBuffer
                    }
                    if status48 == .haveData, let fd = out48.floatChannelData {
                        // The archive mic stays RAW: AEC3's residual
                        // suppressor bakes robotic double-talk artifacts
                        // into the playback audio (field verdict — the
                        // user's natural voice beat every cleaned
                        // variant). The transcript-driven mix gates the
                        // bleed instead; neural AEC (DTLN) is the
                        // planned proper fix.
                        spool48Mic.append(Array(UnsafeBufferPointer(
                            start: fd[0], count: Int(out48.frameLength))))
                    }
                }
            }
            try engine.start()
            // Reset the heartbeat on install so the watchdog gives the new
            // engine a full window to produce its first sample.
            updateMicHeartbeat()
        }

        try installMicTap()
        fputs("Microphone capture started\n", stderr)

        // Serial queue: every rebuild request — whatever signal triggered
        // it — funnels through here. Async so the calling thread (notification
        // queue / CoreAudio HAL queue / watchdog timer) doesn't block on the
        // tap dance.
        let micRebuildQueue = DispatchQueue(label: "meetink.mic-rebuild")
        let rebuildMicTap: (String) -> Void = { reason in
            micRebuildQueue.async {
                fputs("[\(reason)] rebuilding mic tap...\n", stderr)
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                engine.reset()
                do {
                    try installMicTap()
                    fputs("Mic capture resumed (trigger=\(reason))\n", stderr)
                } catch {
                    fputs("Failed to restart mic (trigger=\(reason)): \(error.localizedDescription)\n", stderr)
                }
            }
        }

        // Signal 1: AVAudioEngineConfigurationChange notification.
        _ = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            rebuildMicTap("av-engine-config-change")
        }

        // Signal 2: CoreAudio HAL listener on the system default input
        // device. The block fires on the CoreAudio internal thread; we just
        // dispatch into the serial rebuild queue. Bridging the property
        // listener to a Swift closure is via AudioObjectAddPropertyListener-
        // Block which takes an Objective-C block (Swift closures convert
        // automatically). We keep the listener alive for the process
        // lifetime — meetink-capture exits on /stop, taking it with us.
        var defaultInputProp = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let halStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputProp,
            DispatchQueue.global(qos: .userInitiated)
        ) { _, _ in
            rebuildMicTap("coreaudio-default-input-changed")
        }
        if halStatus != noErr {
            fputs("Warning: CoreAudio HAL listener install failed (status=\(halStatus)); falling back to AVAudioEngine + heartbeat only\n", stderr)
        }

        // Signal 3: heartbeat watchdog. Polls every 5 s. If the engine
        // reports running but no mic samples have landed in the last
        // micStallThresholdSeconds, force a rebuild. Catches silent-drop
        // patterns (BT disconnect that doesn't trigger either of the
        // notifications above).
        let micWatchdogTimer = DispatchSource.makeTimerSource(queue: micRebuildQueue)
        micWatchdogTimer.schedule(deadline: .now() + 5.0, repeating: 5.0, leeway: .seconds(1))
        micWatchdogTimer.setEventHandler {
            guard engine.isRunning else { return }
            let now = Date().timeIntervalSince1970
            micHeartbeatLock.lock()
            let elapsed = now - lastMicSampleAt
            micHeartbeatLock.unlock()
            if elapsed > micStallThresholdSeconds {
                fputs("Mic stall detected: \(String(format: "%.1f", elapsed))s since last sample (threshold=\(Int(micStallThresholdSeconds))s)\n", stderr)
                // Direct call here is safe — we're already on the rebuild queue.
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                engine.reset()
                do {
                    try installMicTap()
                    fputs("Mic capture resumed (trigger=heartbeat-stall)\n", stderr)
                } catch {
                    fputs("Failed to restart mic after heartbeat stall: \(error.localizedDescription)\n", stderr)
                }
            }
        }
        micWatchdogTimer.resume()
        micEngineRef = engine
        micWatchdogRef = micWatchdogTimer
        }

        fputs("\n=== Meeting capture running ===\n", stderr)
        fputs("Transcript: \(transcriptPath)\n", stderr)
        fputs("Press Ctrl+C to stop\n\n", stderr)

        // --- Handle SIGINT ---
        var running = true
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            running = false
            fputs("\nStopping capture...\n", stderr)
        }
        sigintSource.resume()

        // --- Chunk processing loop ---
        while running {
            try await Task.sleep(nanoseconds: 1_000_000_000)

            // Flush merged transcript lines if speaker has paused
            transcriptMerger.flushIfStale()

            if let chunks = audioBuffer.tryExtractChunks() {
                let idx = audioBuffer.chunkIndex

                if let s = chunks.system { spoolSys.append(s) }
                if let m = chunks.mic { spoolMic.append(m) }

                if let sysSamples = chunks.system {
                    let sent = hasAudio(sysSamples)
                    logGate("sys", sysSamples, sent: sent)
                    if sent {
                        let wavURL = URL(fileURLWithPath: "\(chunkDir)/chunk_\(idx)_them.wav")
                        try writeWAV(samples: sysSamples, to: wavURL)
                        DispatchQueue.global().async {
                            transcribe(wavURL: wavURL, chunkIndex: idx, speaker: "THEM")
                        }
                    }
                }

                if let micSamples = chunks.mic {
                    let sent = hasAudio(micSamples)
                    logGate("mic", micSamples, sent: sent)
                    if sent {
                        let wavURL = URL(fileURLWithPath: "\(chunkDir)/chunk_\(idx)_me.wav")
                        try writeWAV(samples: micSamples, to: wavURL)
                        DispatchQueue.global().async {
                            transcribe(wavURL: wavURL, chunkIndex: idx, speaker: meName)
                        }
                    }
                }
            }
        }

        // --- Shutdown ---
        micWatchdogRef?.cancel()
        micEngineRef?.stop()
        micEngineRef?.inputNode.removeTap(onBus: 0)
        if let scStream {
            try await scStream.stopCapture()
        }
        // Keep the SCK delegate alive until AFTER capture stops. ARC frees
        // a local at its last USE, not at scope end — without this read the
        // delegate dies right after setup and sys audio silently flatlines.
        withExtendedLifetime(scDelegate) {}

        // Flush any buffered merged transcript lines
        transcriptMerger.flushAll()

        let remaining = audioBuffer.flush()
        if let s = remaining.system { spoolSys.append(s) }
        if let m = remaining.mic { spoolMic.append(m) }
        spoolSys.close()
        spoolMic.close()
        spool48Sys.close()
        spool48Mic.close()
        let idx = audioBuffer.chunkIndex
        if let sysSamples = remaining.system, hasAudio(sysSamples) {
            let wavURL = URL(fileURLWithPath: "\(chunkDir)/chunk_final_them.wav")
            try writeWAV(samples: sysSamples, to: wavURL)
            transcribe(wavURL: wavURL, chunkIndex: idx, speaker: "THEM")
        }
        if let micSamples = remaining.mic, hasAudio(micSamples) {
            let wavURL = URL(fileURLWithPath: "\(chunkDir)/chunk_final_me.wav")
            try writeWAV(samples: micSamples, to: wavURL)
            transcribe(wavURL: wavURL, chunkIndex: idx, speaker: meName)
        }

        let footer = "\n---\nEnded: \(ISO8601DateFormatter().string(from: Date()))\n"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: transcriptPath)) {
            handle.seekToEndOfFile()
            handle.write(footer.data(using: .utf8)!)
            handle.closeFile()
        }

        fputs("Meeting ended. Transcript saved to: \(transcriptPath)\n", stderr)
        try? FileManager.default.removeItem(atPath: chunkDir)
    }
}
