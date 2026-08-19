// meetink-tap — EXPERIMENTAL sidecar, deliberately separate from the
// main capture pipeline. Device-scoped Core Audio tap (macOS 14.4+) on
// the DEFAULT OUTPUT device: it records exactly what the user HEARS.
// When Krisp (or any in-path cleaner) renders the meeting to the real
// output, this captures the post-cleanup audio that the main SCK tap
// misses (the SCK tap sees each app's render — including the dirty
// pre-Krisp feed Zoom sends to Krisp's virtual device).
//
//   meetink-tap --out /path/to/tap-experiment.wav [--keep-alive]
//
// v2: NO resampling — v1's "naive resample to 48 kHz" punched ~2M
// micro-holes into a 32-min capture and lost 0.65% of wall-clock
// samples (field case: the Diogo meeting sounded glitchy/robotic).
// Samples are written VERBATIM at the tap's native rate; the WAV header
// carries that rate. If a device change renegotiates the rate mid-run,
// the writer rolls to <out>.2.wav etc. rather than converting. Every
// 60 s a stats line lands in the journal (frames written vs wall-clock
// expectation, zero fraction) so drift and hole-punching are measurable
// after the fact instead of guessed at.
//
// Runs until SIGINT/SIGTERM. Follows default-output-device changes
// (teardown + recreate — the wedge-prone moment). Watchdogs the
// documented zero-buffer failure (tap keeps firing with exact silence).
// Exits when the main capture dies unless --keep-alive (bench runs).
//
// If ANYTHING here fails, we log and exit 0 — this sidecar must never
// make a recording session look unhealthy.

import Foundation
import CoreAudio
import AudioToolbox

func log(_ s: String) {
    FileHandle.standardError.write(("meetink-tap: " + s + "\n").data(using: .utf8)!)
}

// --- args ---
var outPath: String? = nil
var keepAlive = false
var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    if argv[i] == "--out", i + 1 < argv.count {
        outPath = argv[i + 1]; i += 2
    } else if argv[i] == "--keep-alive" {
        keepAlive = true; i += 1
    } else { i += 1 }
}
guard let outPath else {
    log("usage: meetink-tap --out <file.wav> [--keep-alive]")
    exit(0)
}

let journalPath = outPath + ".tap-journal.jsonl"
func journal(_ event: String, _ detail: String) {
    let line = "{\"t\": \(Date().timeIntervalSince1970), \"event\": \"\(event)\", \"detail\": \"\(detail.replacingOccurrences(of: "\"", with: "'"))\"}\n"
    if let h = FileHandle(forWritingAtPath: journalPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        FileManager.default.createFile(atPath: journalPath,
                                       contents: line.data(using: .utf8))
    }
    log("\(event): \(detail)")
}

// --- WAV writer: mono s16le at the TAP'S native rate, header patched on
// clean exit (pre-sized maximal so a kill -9 still leaves it playable) ---
final class WavWriter {
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    let rate: Double
    let path: String
    init?(path: String, rate: Double) {
        self.rate = rate
        self.path = path
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
        let r = UInt32(rate)
        var header = Data()
        func put(_ s: String) { header.append(s.data(using: .ascii)!) }
        func put32(_ v: UInt32) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 4)) }
        func put16(_ v: UInt16) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 2)) }
        put("RIFF"); put32(0xFFFFFFF0); put("WAVE")   // maximal size: playable even if never patched
        put("fmt "); put32(16); put16(1); put16(1)
        put32(r); put32(r * 2); put16(2); put16(16)
        put("data"); put32(0xFFFFFFC8)
        handle.write(header)
    }
    func append(_ samples: [Int16]) {
        samples.withUnsafeBufferPointer {
            handle.write(Data(buffer: $0))
        }
        dataBytes &+= UInt32(samples.count * 2)
    }
    func finalize() {
        try? handle.seek(toOffset: 4)
        var riff = (36 &+ dataBytes).littleEndian
        handle.write(Data(bytes: &riff, count: 4))
        try? handle.seek(toOffset: 40)
        var d = dataBytes.littleEndian
        handle.write(Data(bytes: &d, count: 4))
        try? handle.close()
    }
}

// --- CoreAudio helpers ---
func defaultOutputDevice() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                               &addr, 0, nil, &size, &dev)
    return dev
}

func deviceUID(_ dev: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &uid) { ptr in
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, ptr)
    }
    return st == noErr ? uid as String? : nil
}

func deviceName(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var name: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &name) { ptr in
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, ptr)
    }
    return st == noErr ? (name as String? ?? "?") : "?"
}

// --- Tap session: tap + aggregate + ioproc for one device ---
final class TapSession {
    private var tapID = AudioObjectID(0)
    private var aggID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID? = nil
    let device: AudioObjectID
    private(set) var rate: Double = 48000
    private let onAudio: ([Int16], Bool, Double) -> Void

    init?(device: AudioObjectID, onAudio: @escaping ([Int16], Bool, Double) -> Void) {
        self.device = device
        self.onAudio = onAudio
        guard let uid = deviceUID(device) else { return nil }

        // Device-scoped tap: everything rendered to THIS device,
        // excluding no processes. NOTE: mixdownOfProcesses([]) means
        // "tap NOTHING" (empty process set — first smoke test recorded
        // 9.6 s of exact zeros that way). initExcludingProcesses:
        // andDeviceUID: is the "whole device" spelling; the initializer
        // is NS_REFINED_FOR_SWIFT, hence the __ prefix.
        let desc = CATapDescription(
            __excludingProcesses: [] as [NSNumber],
            andDeviceUID: uid,
            withStream: 0)
        desc.isMono = true
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.unmuted
        var tap = AudioObjectID(0)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else {
            journal("tap-create-failed", "status \(st) on \(deviceName(device))")
            return nil
        }
        tapID = tap

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "meetink-tap-agg",
            kAudioAggregateDeviceUIDKey as String: "com.meetink.tap.agg.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: uid,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: uid]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: desc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey as String: true]
            ],
        ]
        var agg = AudioObjectID(0)
        st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard st == noErr else {
            journal("aggregate-create-failed", "status \(st)")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        aggID = agg

        // The tap's ACTUAL stream format — trusted for rate, layout and
        // channel count; journaled so a mismatch is diagnosable later.
        var asbd = AudioStreamBasicDescription()
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var fs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fs, &asbd) == noErr,
              asbd.mSampleRate > 0 else {
            journal("tap-format-failed", "cannot read tap format")
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        rate = asbd.mSampleRate
        let deinterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let chDesc = deinterleaved ? "deinterleaved" : "interleaved"
        journal("tap-format",
                "\(Int(rate)) Hz, \(asbd.mChannelsPerFrame) ch \(chDesc), "
                + "\(asbd.mBitsPerChannel)-bit, bytes/frame \(asbd.mBytesPerFrame)")

        // The IOProc delivers in the AGGREGATE's clock, not at the tap
        // format's claim. With AirPods renegotiated to 24 kHz call mode
        // the tap format still said 48000 while delivery ran at exactly
        // half — a 24k stream in a 48k-labeled WAV plays helium-pitched
        // (field case: the Ross call). The aggregate's nominal rate IS
        // the delivery rate; trust it over the tap format.
        var aggRate: Double = 0
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rs = UInt32(MemoryLayout<Double>.size)
        if AudioObjectGetPropertyData(aggID, &rateAddr, 0, nil, &rs, &aggRate) == noErr,
           aggRate > 0, aggRate != rate {
            // Clock mismatch (AirPods call mode: device/aggregate 24 kHz,
            // tap stream 48 kHz) makes the tap→aggregate drift
            // compensator resample 2:1 — and it drops one IO cycle every
            // ring-buffer wrap: a ~20 ms zero gap every 0.68 s
            // (= 32768 frames at 48 kHz; field case: rhythmic 'womp'
            // under Ross's speech). Pin the aggregate to the tap's rate
            // so the tap path copies verbatim; the HAL resamples the
            // device feed instead, which is the boring well-tested path.
            var want = rate
            let st2 = AudioObjectSetPropertyData(
                aggID, &rateAddr, 0, nil,
                UInt32(MemoryLayout<Double>.size), &want)
            if st2 == noErr {
                journal("agg-rate-pinned",
                        "aggregate \(Int(aggRate)) → \(Int(want)) Hz to "
                        + "match the tap stream")
                // Re-read: the HAL may quantize or refuse silently.
                var check: Double = 0
                if AudioObjectGetPropertyData(aggID, &rateAddr, 0, nil,
                                              &rs, &check) == noErr,
                   check > 0 { aggRate = check }
            } else {
                journal("agg-rate-pin-failed",
                        "status \(st2) — keeping \(Int(aggRate)) Hz")
            }
            if aggRate != rate {
                journal("tap-rate-override",
                        "tap format claims \(Int(rate)) Hz but the aggregate "
                        + "runs \(Int(aggRate)) Hz — trusting the aggregate")
                rate = aggRate
            }
        }

        let srcRate = rate
        var pid: AudioDeviceIOProcID? = nil
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, nil) {
            _, inInputData, _, _, _ in
            // v2: samples pass through VERBATIM (Float32 → Int16 only).
            // Mono mixdown averages across ALL buffers/channels — v1
            // read only abl.first, which under-reads any layout with
            // more than one buffer.
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            let bufs = abl.compactMap { b -> (UnsafeMutablePointer<Float32>, Int, Int)? in
                guard let d = b.mData, b.mDataByteSize > 0 else { return nil }
                let n = Int(b.mDataByteSize) / MemoryLayout<Float32>.size
                let ch = max(1, Int(b.mNumberChannels))
                return (d.bindMemory(to: Float32.self, capacity: n), n, ch)
            }
            guard !bufs.isEmpty else { return }
            if deinterleaved {
                // One buffer per channel, equal frame counts.
                let frames = bufs.map { $0.1 }.min() ?? 0
                if frames == 0 { return }
                var out = [Int16](repeating: 0, count: frames)
                var nonzero = false
                let scale = Float32(1) / Float32(bufs.count)
                for f in 0..<frames {
                    var acc: Float32 = 0
                    for (p, _, _) in bufs { acc += p[f] }
                    let v = acc * scale
                    if v != 0 { nonzero = true }
                    out[f] = v.isFinite
                        ? Int16(max(-32768, min(32767, v * 32767))) : 0
                }
                self.onAudio(out, nonzero, srcRate)
            } else {
                let (p, n, ch) = bufs[0]
                let frames = n / ch
                if frames == 0 { return }
                var out = [Int16](repeating: 0, count: frames)
                var nonzero = false
                let scale = Float32(1) / Float32(ch)
                for f in 0..<frames {
                    var acc: Float32 = 0
                    for c in 0..<ch { acc += p[f * ch + c] }
                    let v = acc * scale
                    if v != 0 { nonzero = true }
                    out[f] = v.isFinite
                        ? Int16(max(-32768, min(32767, v * 32767))) : 0
                }
                self.onAudio(out, nonzero, srcRate)
            }
        }
        guard st == noErr, let pid else {
            journal("ioproc-create-failed", "status \(st)")
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }
        procID = pid
        st = AudioDeviceStart(aggID, pid)
        guard st == noErr else {
            journal("device-start-failed", "status \(st)")
            teardown()
            return nil
        }
        journal("tap-started", "\(deviceName(device)) @ \(Int(srcRate)) Hz")
    }

    func teardown() {
        if let pid = procID {
            AudioDeviceStop(aggID, pid)
            AudioDeviceDestroyIOProcID(aggID, pid)
            procID = nil
        }
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }
}

// --- main loop: session per default device, watchdog, signals ---
let queue = DispatchQueue(label: "meetink.tap")
var session: TapSession? = nil
var lastNonzeroAt = Date()
var lastAudioAt = Date()
var running = true

// Segment-rolling writer: one WAV per sample rate. A mid-run rate
// renegotiation (AirPods A2DP <-> call mode) rolls to <out>.2.wav
// instead of converting — verbatim beats resampled for a diagnostic.
var wavCur: WavWriter? = nil
var segIndex = 0
func writer(for rate: Double) -> WavWriter? {
    if let w = wavCur, w.rate == rate { return w }
    wavCur?.finalize()
    segIndex += 1
    let path = segIndex == 1 ? outPath
        : (outPath.hasSuffix(".wav")
           ? String(outPath.dropLast(4)) + ".\(segIndex).wav"
           : outPath + ".\(segIndex)")
    if segIndex > 1 {
        journal("segment-rolled", "rate now \(Int(rate)) Hz → \((path as NSString).lastPathComponent)")
    }
    wavCur = WavWriter(path: path, rate: rate)
    if wavCur == nil { journal("wav-open-failed", path) }
    return wavCur
}

// Per-minute stats so drift/holes are measurable, not guessed.
var statFrames = 0
var statZeroSamples = 0
var statRate: Double = 0
var statWindowStart = Date()

// Measured-rate override: when the stats watchdog catches delivery
// running at a different rate than every property claimed, it re-labels
// the stream here (rolls a segment at the measured rate).
var forcedRate: Double? = nil

let audioSink: ([Int16], Bool, Double) -> Void = { samples, nonzero, rate in
    queue.async {
        writer(for: forcedRate ?? rate)?.append(samples)
        lastAudioAt = Date()
        if nonzero { lastNonzeroAt = Date() }
        statFrames += samples.count
        statRate = rate
        if !nonzero { statZeroSamples += samples.count }
        else { statZeroSamples += samples.lazy.filter { $0 == 0 }.count }
    }
}

func startSession() {
    let dev = defaultOutputDevice()
    guard dev != 0 else {
        journal("no-default-output", "will retry")
        return
    }
    session = TapSession(device: dev, onAudio: audioSink)
    lastNonzeroAt = Date()
    lastAudioAt = Date()
    statFrames = 0
    statZeroSamples = 0
    statWindowStart = Date()
    forcedRate = nil   // a fresh session re-derives its own rate
}

func restartSession(_ reason: String) {
    journal("tap-restart", reason)
    session?.teardown()
    session = nil
    startSession()
}

// Default-output change listener.
var outAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &outAddr,
    DispatchQueue.global()) { _, _ in
    queue.async {
        let dev = defaultOutputDevice()
        if dev != session?.device {
            restartSession("default-output-changed to \(deviceName(dev))")
        }
    }
}

// Watchdog: the documented zero-buffer wedge — callbacks fire, samples
// all zero. 30 s of exact silence triggers a full recreate (a quiet
// meeting moment can last that long; recreation during real silence is
// harmless). Separately, NO callbacks for 15 s = dead session. Every
// 60 s: a stats journal line (drift + hole measurement).
var watchdogTicks = 0
let watchdog = DispatchSource.makeTimerSource(queue: queue)
watchdog.schedule(deadline: .now() + 10, repeating: 10)
watchdog.setEventHandler {
    guard running else { return }
    if session == nil {
        startSession()
        return
    }
    let now = Date()
    watchdogTicks += 1
    if watchdogTicks % 6 == 0, statRate > 0 {
        let elapsed = now.timeIntervalSince(statWindowStart)
        let expected = Int(elapsed * statRate)
        let zf = statFrames > 0
            ? Double(statZeroSamples) / Double(statFrames) : 0
        journal("stats", "window \(Int(elapsed))s: \(statFrames) frames "
                + "(expected ~\(expected), drift \(statFrames - expected)), "
                + "zero-fraction \(String(format: "%.3f", zf))")
        // Delivery rate is MEASURED, not believed: if a full window ran
        // >5% off the writer's rate, re-label at the nearest standard
        // rate (a wrong label plays pitch-shifted; a rolled segment
        // just plays right). Catches anything the property lies missed.
        if elapsed > 30, statFrames > 0 {
            let measured = Double(statFrames) / elapsed
            let current = forcedRate ?? statRate
            if current > 0, abs(measured - current) / current > 0.05 {
                let standards: [Double] = [8000, 16000, 22050, 24000,
                                           32000, 44100, 48000, 88200, 96000]
                let snapped = standards.min {
                    abs($0 - measured) < abs($1 - measured)
                } ?? measured
                journal("rate-mismatch",
                        "measured \(Int(measured)) Hz vs writer "
                        + "\(Int(current)) Hz — rolling segment at \(Int(snapped)) Hz")
                forcedRate = snapped
            }
        }
        statFrames = 0
        statZeroSamples = 0
        statWindowStart = now
    }
    if now.timeIntervalSince(lastAudioAt) > 15 {
        restartSession("no-callbacks-15s")
    } else if now.timeIntervalSince(lastNonzeroAt) > 30 {
        restartSession("zero-buffers-30s (wedge suspected)")
    }
    // Orphan guard: exit when the main capture is gone (bench runs pass
    // --keep-alive to skip this).
    if keepAlive { return }
    if let pidStr = try? String(contentsOfFile: "/tmp/meetink-capture.pid",
                                encoding: .utf8),
       let p = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(p, 0) == 0 {
        // capture alive — keep going
    } else {
        journal("capture-gone", "finalizing and exiting")
        running = false
        session?.teardown()
        wavCur?.finalize()
        exit(0)
    }
}
watchdog.resume()

// Signal handlers can't capture context — route through DispatchSource
// instead (the standard Swift pattern).
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
let doShutdown = {
    running = false
    session?.teardown()
    wavCur?.finalize()
    journal("tap-finalized", "clean shutdown")
    exit(0)
}
sigint.setEventHandler(handler: doShutdown)
sigterm.setEventHandler(handler: doShutdown)
sigint.resume()
sigterm.resume()

queue.async { startSession() }
journal("tap-launched", "out=\(outPath)")
dispatchMain()
