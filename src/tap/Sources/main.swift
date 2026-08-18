// meetink-tap — EXPERIMENTAL sidecar, deliberately separate from the
// main capture pipeline. Device-scoped Core Audio tap (macOS 14.4+) on
// the DEFAULT OUTPUT device: it records exactly what the user HEARS.
// When Krisp (or any in-path cleaner) renders the meeting to the real
// output, this captures the post-cleanup audio that the main SCK tap
// misses (the SCK tap sees each app's render — including the dirty
// pre-Krisp feed Zoom sends to Krisp's virtual device).
//
//   meetink-tap --out /path/to/tap-experiment.wav
//
// Runs until SIGINT/SIGTERM. Follows default-output-device changes
// (teardown + recreate — the wedge-prone moment). Watchdogs the
// documented zero-buffer failure (tap keeps firing with exact silence):
// sustained all-zero output while the device claims activity triggers a
// full tap+aggregate teardown/recreate. Events journal to
// <out>.tap-journal.jsonl. Nothing in the pipeline reads any of this.
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
var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    if argv[i] == "--out", i + 1 < argv.count {
        outPath = argv[i + 1]; i += 2
    } else { i += 1 }
}
guard let outPath else {
    log("usage: meetink-tap --out <file.wav>")
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

// --- WAV writer: 48 kHz mono s16le, header patched on clean exit ---
final class WavWriter {
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    init?(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
        var header = Data()
        func put(_ s: String) { header.append(s.data(using: .ascii)!) }
        func put32(_ v: UInt32) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 4)) }
        func put16(_ v: UInt16) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 2)) }
        put("RIFF"); put32(0xFFFFFFF0); put("WAVE")   // maximal size: playable even if never patched
        put("fmt "); put32(16); put16(1); put16(1)
        put32(48000); put32(48000 * 2); put16(2); put16(16)
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

guard let wav = WavWriter(path: outPath) else {
    log("cannot open output — exiting")
    exit(0)
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
    private var converterState = 0.0   // fractional resample position
    let device: AudioObjectID
    private let onAudio: ([Int16], Bool) -> Void

    init?(device: AudioObjectID, onAudio: @escaping ([Int16], Bool) -> Void) {
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

        // The tap's stream format (sample rate can differ per device).
        var rate: Double = 48000
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var fs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fs, &asbd) == noErr,
           asbd.mSampleRate > 0 {
            rate = asbd.mSampleRate
        }
        let srcRate = rate

        var pid: AudioDeviceIOProcID? = nil
        st = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, nil) {
            _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let buf = abl.first, let data = buf.mData else { return }
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
            let ch = max(1, Int(buf.mNumberChannels))
            let floats = data.bindMemory(to: Float32.self, capacity: n)
            let frames = n / ch
            if frames == 0 { return }
            // mono + naive resample to 48k (speech archive; fidelity
            // needs are modest and drift compensation is on)
            let ratio = 48000.0 / srcRate
            let outFrames = Int(Double(frames) * ratio)
            var out = [Int16](repeating: 0, count: outFrames)
            var nonzero = false
            for oi in 0..<outFrames {
                let si = min(frames - 1, Int(Double(oi) / ratio))
                var acc: Float32 = 0
                for c in 0..<ch { acc += floats[si * ch + c] }
                let v = acc / Float32(ch)
                if v != 0 { nonzero = true }
                out[oi] = Int16(max(-32768, min(32767, v * 32767)))
            }
            self.onAudio(out, nonzero)
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

let audioSink: ([Int16], Bool) -> Void = { samples, nonzero in
    queue.async {
        wav.append(samples)
        lastAudioAt = Date()
        if nonzero { lastNonzeroAt = Date() }
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
// harmless). Separately, NO callbacks for 15 s = dead session.
let watchdog = DispatchSource.makeTimerSource(queue: queue)
watchdog.schedule(deadline: .now() + 10, repeating: 10)
watchdog.setEventHandler {
    guard running else { return }
    if session == nil {
        startSession()
        return
    }
    let now = Date()
    if now.timeIntervalSince(lastAudioAt) > 15 {
        restartSession("no-callbacks-15s")
    } else if now.timeIntervalSince(lastNonzeroAt) > 30 {
        restartSession("zero-buffers-30s (wedge suspected)")
    }
    // Orphan guard: exit when the main capture is gone.
    if let pidStr = try? String(contentsOfFile: "/tmp/meetink-capture.pid",
                                encoding: .utf8),
       let p = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(p, 0) == 0 {
        // capture alive — keep going
    } else {
        journal("capture-gone", "finalizing and exiting")
        running = false
        session?.teardown()
        wav.finalize()
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
    wav.finalize()
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
