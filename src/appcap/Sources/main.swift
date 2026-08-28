// meetink-appcap — EXPERIMENTAL diagnostic sidecar. Captures the
// system-audio mix AND one stream per audio application (Krisp, Zoom,
// Chrome/Meet, …) simultaneously via ScreenCaptureKit, each to its own
// WAV in the session folder:
//
//   appcap-all.wav        every app summed (what the main capture
//                         recorded before the Krisp exclusion — the
//                         historical behavior, kept for comparison)
//   appcap-<app>.wav      that app's render alone
//
// Purpose (field experiment, Aug 27): prove/refute per-app where the
// echo on Krisp-routed calls comes from by letting the user A/B every
// layer of the audio topology from ONE call. Nothing in the pipeline
// reads these files.
//
//   meetink-appcap --out-dir <session dir> [--apps csv] [--rate hz]
//                  [--keep-alive]
//
// Runs until SIGINT/SIGTERM or until the main capture exits (orphan
// guard; --keep-alive skips it for bench runs). Journals to
// appcap-journal.jsonl with per-minute per-stream stats. If ANYTHING
// fails, log and exit 0 — this sidecar must never make a recording
// look unhealthy. Heads-up: 48 kHz mono s16 is ~330 MB/hour per
// stream; a 4-stream hour is ~1.3 GB. It's a diagnostic, not a daily
// driver — disable with appcap_experiment=off (or delete the config
// line) once the comparison is done.

import Foundation
import ScreenCaptureKit
import CoreMedia

func log(_ s: String) {
    FileHandle.standardError.write(("meetink-appcap: " + s + "\n").data(using: .utf8)!)
}

var outDir: String? = nil
var appsCSV = "krisp,zoom,chrome,meet,teams,webex,safari,arc,brave,edge,discord,facetime,slack"
var rate: Double = 48000
var keepAlive = false
var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    switch argv[i] {
    case "--out-dir" where i + 1 < argv.count: outDir = argv[i + 1]; i += 2
    case "--apps" where i + 1 < argv.count: appsCSV = argv[i + 1]; i += 2
    case "--rate" where i + 1 < argv.count: rate = Double(argv[i + 1]) ?? 48000; i += 2
    case "--keep-alive": keepAlive = true; i += 1
    default: i += 1
    }
}
guard let outDir else {
    log("usage: meetink-appcap --out-dir <dir> [--apps csv] [--rate hz] [--keep-alive]")
    exit(0)
}

let journalPath = outDir + "/appcap-journal.jsonl"
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

// Same pre-sized-header WAV writer as the tap sidecar: playable even
// after a kill -9; finalize() patches the true sizes.
final class WavWriter {
    private let handle: FileHandle
    private var dataBytes: UInt32 = 0
    init?(path: String, rate: Double) {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        handle = h
        let r = UInt32(rate)
        var header = Data()
        func put(_ s: String) { header.append(s.data(using: .ascii)!) }
        func put32(_ v: UInt32) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 4)) }
        func put16(_ v: UInt16) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 2)) }
        put("RIFF"); put32(0xFFFFFFF0); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(r); put32(r * 2); put16(2); put16(16)
        put("data"); put32(0xFFFFFFC8)
        handle.write(header)
    }
    func append(_ samples: [Int16]) {
        samples.withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
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

func resampleLinear(_ x: [Float], from: Double, to: Double) -> [Float] {
    if abs(from - to) < 1.0 || x.isEmpty { return x }
    let n = Int(Double(x.count) * to / from)
    var out = [Float](repeating: 0, count: n)
    for k in 0..<n {
        let pos = Double(k) * from / to
        let j = Int(pos)
        let frac = Float(pos - Double(j))
        out[k] = j + 1 < x.count ? x[j] * (1 - frac) + x[j + 1] * frac : x[min(j, x.count - 1)]
    }
    return out
}

let queue = DispatchQueue(label: "meetink.appcap")

final class StreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let label: String
    let wav: WavWriter
    var frames = 0
    var zeroFrames = 0
    init?(label: String, path: String) {
        self.label = label
        guard let w = WavWriter(path: path, rate: rate) else { return nil }
        wav = w
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        let length = CMBlockBufferGetDataLength(bb)
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdP = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        let asbd = asbdP.pointee
        guard asbd.mBitsPerChannel == 32 else { return }
        let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let ch = max(1, Int(asbd.mChannelsPerFrame))
        var mono: [Float]
        if ch > 1 {
            let fc = floats.count / ch
            mono = (0..<fc).map { f in
                var s: Float = 0
                for c in 0..<ch { s += floats[f * ch + c] }
                return s / Float(ch)
            }
        } else {
            mono = floats
        }
        if abs(asbd.mSampleRate - rate) > 1.0 {
            mono = resampleLinear(mono, from: asbd.mSampleRate, to: rate)
        }
        let out = mono.map { v -> Int16 in
            v.isFinite ? Int16(max(-32768, min(32767, v * 32767))) : 0
        }
        queue.async {
            self.wav.append(out)
            self.frames += out.count
            self.zeroFrames += out.lazy.filter { $0 == 0 }.count
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        journal("stream-stopped", "\(label): \(error.localizedDescription)")
    }
}

var recorders: [(SCStream, StreamRecorder)] = []

func startAll() async {
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    } catch {
        journal("no-permission", "shareable content failed: \(error.localizedDescription)")
        exit(0)
    }
    guard let display = content.displays.first else {
        journal("no-display", "exiting"); exit(0)
    }
    let patterns = appsCSV.lowercased().split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    var targets: [(String, SCContentFilter)] = [
        ("all", SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []))
    ]
    var seen = Set<String>()
    for app in content.applications {
        let hay = (app.bundleIdentifier + " " + app.applicationName).lowercased()
        guard patterns.contains(where: { hay.contains($0) }) else { continue }
        var name = app.applicationName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        if name.isEmpty { name = app.bundleIdentifier }
        // One stream per app NAME — Chrome shows up as many processes
        // under one application; SCK groups them, but guard anyway.
        guard !seen.contains(name) else { continue }
        seen.insert(name)
        targets.append((name, SCContentFilter(
            display: display, including: [app], exceptingWindows: [])))
    }
    for (name, filter) in targets {
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = Int(rate)
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let path = outDir + "/appcap-\(name).wav"
        guard let rec = StreamRecorder(label: name, path: path) else {
            journal("wav-open-failed", path); continue
        }
        let stream = SCStream(filter: filter, configuration: cfg, delegate: rec)
        do {
            try stream.addStreamOutput(rec, type: .audio,
                                       sampleHandlerQueue: DispatchQueue(label: "appcap-\(name)"))
            try await stream.startCapture()
            recorders.append((stream, rec))
            journal("stream-started", name)
        } catch {
            journal("stream-start-failed", "\(name): \(error.localizedDescription)")
        }
    }
    if recorders.isEmpty {
        journal("nothing-to-capture", "exiting")
        exit(0)
    }
}

func finalizeAll(_ reason: String) {
    for (stream, rec) in recorders {
        stream.stopCapture { _ in }
        rec.wav.finalize()
    }
    journal("appcap-finalized", reason)
    exit(0)
}

// Watchdog: per-minute stats + orphan guard.
var ticks = 0
let watchdog = DispatchSource.makeTimerSource(queue: queue)
watchdog.schedule(deadline: .now() + 10, repeating: 10)
watchdog.setEventHandler {
    ticks += 1
    if ticks % 6 == 0 {
        for (_, rec) in recorders {
            let zf = rec.frames > 0 ? Double(rec.zeroFrames) / Double(rec.frames) : 0
            journal("stats", "\(rec.label): \(rec.frames) frames, "
                    + "zero-fraction \(String(format: "%.3f", zf))")
            rec.frames = 0
            rec.zeroFrames = 0
        }
    }
    if keepAlive { return }
    if let pidStr = try? String(contentsOfFile: "/tmp/meetink-capture.pid",
                                encoding: .utf8),
       let p = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(p, 0) == 0 {
        // capture alive
    } else {
        finalizeAll("capture gone")
    }
}
watchdog.resume()

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
sigint.setEventHandler { finalizeAll("clean shutdown") }
sigterm.setEventHandler { finalizeAll("clean shutdown") }
sigint.resume()
sigterm.resume()

journal("appcap-launched", "out=\(outDir) apps=\(appsCSV) rate=\(Int(rate))")
Task { await startAll() }
dispatchMain()
