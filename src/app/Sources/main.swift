import AppKit
import AVFoundation
import Foundation

// meetink-app — the native companion, now a full (if small) app:
//
//   ┌───────────────────────────────────────────────────────────┐
//   │ ● Recording 12:34                     [Open Live Transcript] │  status strip
//   ├──────────┬────────────────────────────────────────────────┤
//   │ Meetings │                                                │
//   │ Vocab    │        detail area (list / transcript /        │
//   │ Upload   │         vocab editor / upload queue)           │
//   └──────────┴────────────────────────────────────────────────┘
//
// plus the menubar status item. One window, swappable detail pages: the
// live transcript is a PAGE you can always return to (status-strip button),
// so browsing old meetings or the vocab while recording costs nothing.
//
// Hard-won constraints this file preserves (see git history):
//   - Transcripts are rewritten IN PLACE (inode-preserving truncate+write)
//     and RENAMED by titling; the watcher re-resolves symlinks every poll
//     and re-reads on any inode/size change.
//   - ⌘F/⌘C/⌘A/⌘W need a real NSApp.mainMenu — bare NSApplication.run()
//     apps have none.
//   - TranscriptViewController's fixedPath-style state must never regain
//     an initializer default that lets an inherited init shadow ours.
//   - Recording started from this app runs under THIS app's TCC grants;
//     the stable "Meetink Signing" identity keeps them across rebuilds.

// MARK: - Paths & config

let mkHome = ProcessInfo.processInfo.environment["MEETINK_HOME"]
    ?? "\(NSHomeDirectory())/.meetink"

func configValue(_ key: String) -> String? {
    guard let text = try? String(contentsOfFile: "\(mkHome)/config", encoding: .utf8) else {
        return nil
    }
    for line in text.split(separator: "\n") {
        if line.hasPrefix("\(key)=") {
            return String(line.dropFirst(key.count + 1))
        }
    }
    return nil
}

/// Speakers hidden from the sidebar and excluded from talk-share math —
/// recurring non-participants like Zoom's "recording in progress"
/// announcer. hidden_speakers in ~/.meetink/config (CSV) overrides the
/// default. Their transcript lines stay; only the accounting hides.
func hiddenSpeakerNames() -> Set<String> {
    let raw = configValue("hidden_speakers") ?? "Zoom"
    return Set(raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        .filter { !$0.isEmpty })
}

/// Truthy spelling matches the launcher's mk_config_bool: true/on/1.
func configBool(_ key: String) -> Bool {
    guard let v = configValue(key) else { return false }
    return v == "true" || v == "on" || v == "1"
}

/// Rewrite one key=value line in ~/.meetink/config, preserving every other
/// line. Same file the launcher and REPL read — the Settings page is just
/// another writer of the shared config surface.
/// Interface zoom for the reading surfaces (⌘+/⌘-/⌘0), persisted as
/// ui_zoom in the config. Fonts multiply by this and round.
var uiZoom: CGFloat = {
    let v = Double(configValue("ui_zoom") ?? "") ?? 1.0
    return CGFloat(min(1.8, max(0.7, v)))
}()

func configSetValue(_ key: String, _ value: String) {
    let path = "\(mkHome)/config"
    var lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    while let last = lines.last, last.isEmpty { lines.removeLast() }
    lines.removeAll { $0.hasPrefix("\(key)=") }
    lines.append("\(key)=\(value)")
    try? FileManager.default.createDirectory(
        atPath: mkHome, withIntermediateDirectories: true)
    try? (lines.joined(separator: "\n") + "\n")
        .write(toFile: path, atomically: true, encoding: .utf8)
}

/// The live-transcript symlink path, honoring the active project the same
/// way the launcher resolves it.
func liveSymlinkPath() -> String {
    if let explicit = ProcessInfo.processInfo.environment["MEETINK_TRANSCRIPT"] {
        return explicit
    }
    var base = ProcessInfo.processInfo.environment["MEETINK_TRANSCRIPTS_DIR"]
        ?? "\(NSHomeDirectory())/Documents/meetink"
    if let project = configValue("active_project"), !project.isEmpty {
        base += "/\(project)"
    }
    return base + "/live.txt"
}

func transcriptsDir() -> String {
    (liveSymlinkPath() as NSString).deletingLastPathComponent
}

func vocabPath() -> String {
    ProcessInfo.processInfo.environment["MEETINK_PROMPT"]
        ?? "\(mkHome)/prompts/default.txt"
}

func launcherPath() -> String? {
    if let p = ProcessInfo.processInfo.environment["MEETINK_LAUNCHER"],
       FileManager.default.isExecutableFile(atPath: p) { return p }
    for candidate in ["/opt/homebrew/bin/meetink", "/usr/local/bin/meetink"] {
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}

/// Is the capture binary alive? Same check the REPL footer uses.
func recordingPID() -> Int32? {
    guard let raw = try? String(contentsOfFile: "/tmp/meetink-capture.pid", encoding: .utf8),
          let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return nil
    }
    guard kill(pid, 0) == 0 else { return nil }
    // PID reuse guard: a stale pid file whose number the OS recycled to
    // some unrelated process must not read as 'recording' (field case:
    // the strip said Recording during an upload with no capture alive).
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    if n > 0 {
        let path = String(cString: buf)
        if !path.hasSuffix("meetink-capture") { return nil }
    }
    return pid
}

/// Keeps the assignment combo's dropdown open and filtered while the
/// user types — NSComboBox's built-in completion is inline-only, so
/// without this the list has to be opened by hand every time.
final class ComboAutoOpen: NSObject, NSComboBoxDelegate {
    static let shared = ComboAutoOpen()

    func controlTextDidChange(_ n: Notification) {
        guard let combo = n.object as? NSComboBox else { return }
        let typed = combo.stringValue.lowercased()
        let all = enrolledProfiles()
        let matches = typed.isEmpty ? all
            : all.filter { $0.lowercased().contains(typed) }
        combo.removeAllItems()
        combo.addItems(withObjectValues: matches.isEmpty ? all : matches)
        (combo.cell as? NSComboBoxCell)?.perform(Selector(("popUp:")))
    }
}

/// Enrolled profile names, for the assignment dialog's suggestions.
func enrolledProfiles() -> [String] {
    let dir = "\(mkHome)/profiles"
    let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return items.filter { $0.hasSuffix(".npz") }
        .map { String($0.dropLast(4)) }
        .sorted()
}

// MARK: - The M mark

/// The bundled logo mark for the menu bar: black M + alpha at 18 pt
/// (the PNG is 36 px, so it's crisp on retina). `tint: nil` returns it
/// template-ready; a tint bakes the color in (recording = red). Returns
/// nil when running outside the bundle — callers fall back to the drawn
/// waveform mark.
func menubarMarkImage(tint: NSColor? = nil) -> NSImage? {
    guard let path = Bundle.main.path(forResource: "menubar-m", ofType: "png"),
          let img = NSImage(contentsOfFile: path) else { return nil }
    img.size = NSSize(width: 18, height: 18)
    guard let tint else { return img }
    let tinted = NSImage(size: img.size, flipped: false) { rect in
        img.draw(in: rect)
        tint.setFill()
        rect.fill(using: .sourceAtop)
        return true
    }
    return tinted
}

func mWaveformImage(size: CGFloat, barColor: NSColor, tile: NSColor? = nil) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        if let tile = tile {
            let inset = rect.insetBy(dx: size * 0.04, dy: size * 0.04)
            let bg = NSBezierPath(roundedRect: inset,
                                  xRadius: size * 0.22, yRadius: size * 0.22)
            tile.setFill()
            bg.fill()
        }
        let heights: [CGFloat] = [0.95, 0.42, 0.70, 0.42, 0.95]
        let drawable = rect.insetBy(dx: size * 0.18, dy: size * 0.22)
        let barWidth = drawable.width * 0.12
        let gap = (drawable.width - barWidth * CGFloat(heights.count))
            / CGFloat(heights.count - 1)
        barColor.setFill()
        for (i, h) in heights.enumerated() {
            let barHeight = drawable.height * h
            let x = drawable.minX + CGFloat(i) * (barWidth + gap)
            let y = drawable.midY - barHeight / 2
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: barHeight),
                xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        return true
    }
    return img
}

/// Write a calendar event (an agent `events` JSON object) onto a meeting:
/// metadata first (exact title + event record), then the slug rename,
/// then the header lines. Header edits are safe on a LIVE transcript —
/// capture re-opens by path per append, and the path doesn't change here.
/// '# event:' is what stop-time titling reads to name the meeting (live
/// meetings defer their rename to /stop); '# attendees:' feeds the
/// diarize whitelist mid-call. Returns the transcript's (possibly moved)
/// path.
func applyEventToMeeting(txtPath: String, event e: [String: Any]) -> String {
    let title = (e["title"] as? String) ?? ""
    let names = ((e["attendees"] as? [[String: String]]) ?? [])
        .compactMap { $0["name"]?.isEmpty == false ? $0["name"] : $0["email"] }
    var path = txtPath
    setMeetingMeta(path, "event", ["title": title,
                                   "start": (e["start"] as? String) ?? "",
                                   "attendees": names])
    if !title.isEmpty, let newPath = renameMeeting(txtPath: path, displayName: title) {
        path = newPath
    }
    if (!names.isEmpty || !title.isEmpty),
       var text = try? String(contentsOfFile: path, encoding: .utf8) {
        func upsert(_ line: String, matching pattern: String) {
            if let r = text.range(of: pattern, options: [.regularExpression]) {
                text.replaceSubrange(r, with: line)
            } else if let r = text.range(of: "Started:") {
                text.insert(contentsOf: line + "\n", at: r.lowerBound)
            }
        }
        if !title.isEmpty {
            upsert("# event: " + title, matching: #"(?m)^# event:.*$"#)
        }
        if !names.isEmpty {
            upsert("# attendees: " + names.joined(separator: ", "),
                   matching: #"(?m)^# attendees:.*$"#)
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    return path
}

/// Agent `events` over a window, on a background queue; completion on
/// main. Respects hidden_calendars. (Read-to-EOF before waitUntilExit —
/// the 64 KB pipe-deadlock lesson.)
func fetchAgentEvents(from: Date, to: Date,
                      completion: @escaping ([[String: Any]]) -> Void) {
    let agent = "\(mkHome)/bin/MeetinkAgent.app/Contents/MacOS/meetink-agent"
    guard FileManager.default.isExecutableFile(atPath: agent) else {
        completion([]); return
    }
    let iso = ISO8601DateFormatter()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: agent)
    var args = ["events", "--from", iso.string(from: from),
                "--to", iso.string(from: to)]
    if let hidden = configValue("hidden_calendars"), !hidden.isEmpty {
        args += ["--hidden-calendars", hidden]
    }
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    DispatchQueue.global().async {
        var events: [[String: Any]] = []
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            events = (try? JSONSerialization.jsonObject(with: data)
                      as? [[String: Any]]) ?? []
        } catch {}
        DispatchQueue.main.async { completion(events) }
    }
}

/// `meetink start`, then stamp a calendar event on the fresh session —
/// but only once the live symlink MOVES (stamping earlier would link
/// the previous meeting). Used by the Today page and the menu bar.
func startRecordingAndLinkEvent(_ e: [String: Any],
                                completion: (() -> Void)? = nil) {
    guard let launcher = launcherPath() else { completion?(); return }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launcher)
    proc.arguments = ["start"]
    var env = ProcessInfo.processInfo.environment
    env["MEETINK_NO_TAIL"] = "1"
    proc.environment = env
    let live = liveSymlinkPath()
    let before = try? FileManager.default.destinationOfSymbolicLink(atPath: live)
    DispatchQueue.global().async {
        defer { DispatchQueue.main.async { completion?() } }
        do { try proc.run() } catch { return }
        proc.waitUntilExit()
        var dest: String? = nil
        for _ in 0..<30 {
            dest = try? FileManager.default.destinationOfSymbolicLink(atPath: live)
            if recordingPID() != nil, let d = dest, d != before { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard recordingPID() != nil, let d = dest, d != before else { return }
        let resolved = d.hasPrefix("/") ? d
            : (live as NSString).deletingLastPathComponent + "/" + d
        _ = applyEventToMeeting(txtPath: resolved, event: e)
    }
}

/// True when this transcript is the one the capture binary is writing
/// RIGHT NOW. It matters because capture re-opens the transcript BY PATH
/// on every append — move the file or its folder and every later chunk
/// silently vanishes (field case: live transcript froze after Link Event
/// mid-call).
func isLiveRecording(txtPath: String) -> Bool {
    guard recordingPID() != nil else { return false }
    let live = liveSymlinkPath()
    guard let dest = try? FileManager.default
        .destinationOfSymbolicLink(atPath: live) else { return false }
    let resolved = dest.hasPrefix("/")
        ? dest
        : (live as NSString).deletingLastPathComponent + "/" + dest
    return (resolved as NSString).standardizingPath
        == (txtPath as NSString).standardizingPath
}

/// Rename a meeting to a new display name: slugify, keep the timestamp
/// prefix, move the session folder + every same-basename file (or the flat
/// siblings), and retarget live.txt if it pointed at the old path. Returns
/// the transcript's new path, or nil when nothing moved.
func renameMeeting(txtPath: String, displayName: String) -> String? {
    let title = displayName.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return nil }
    // A live meeting must not move on disk (see isLiveRecording). Record
    // the exact title in meta.json — the display name updates everywhere
    // immediately — and let stop-time titling perform the physical rename
    // with its lockstep machinery once capture has exited.
    if isLiveRecording(txtPath: txtPath) {
        setMeetingMeta(txtPath, "title", title)
        return txtPath
    }
    // The exact title (dashes, punctuation, anything) goes to metadata
    // FIRST — it travels with the same-basename rename below. The slug is
    // just the folder's readable spelling.
    setMeetingMeta(txtPath, "title", title)
    var slug = String(title.map { c in
        c.isLetter || c.isNumber ? c : "-"
    }).replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if slug.isEmpty { slug = "meeting" }
    let fm = FileManager.default
    let base = ((txtPath as NSString).lastPathComponent as NSString).deletingPathExtension
    var prefix = ""
    if let r = base.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}(-\d{2})?_?"#,
                          options: .regularExpression) {
        prefix = String(base[r])
        if !prefix.hasSuffix("_") { prefix += "_" }
    }
    let newBase = prefix + slug
    guard newBase != base else { return txtPath }
    let dir = (txtPath as NSString).deletingLastPathComponent
    var newTxt: String
    if (dir as NSString).lastPathComponent == base {
        let parent = (dir as NSString).deletingLastPathComponent
        let newDir = parent + "/" + newBase
        guard !fm.fileExists(atPath: newDir),
              (try? fm.moveItem(atPath: dir, toPath: newDir)) != nil else { return nil }
        for item in (try? fm.contentsOfDirectory(atPath: newDir)) ?? []
        where item.hasPrefix(base + ".") {
            let suffix = String(item.dropFirst(base.count))
            try? fm.moveItem(atPath: newDir + "/" + item,
                             toPath: newDir + "/" + newBase + suffix)
        }
        newTxt = newDir + "/" + newBase + ".txt"
    } else {
        for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        where item.hasPrefix(base + ".") {
            let suffix = String(item.dropFirst(base.count))
            try? fm.moveItem(atPath: dir + "/" + item,
                             toPath: dir + "/" + newBase + suffix)
        }
        newTxt = dir + "/" + newBase + ".txt"
    }
    let live = liveSymlinkPath()
    if let t = try? fm.destinationOfSymbolicLink(atPath: live), t == txtPath {
        try? fm.removeItem(atPath: live)
        try? fm.createSymbolicLink(atPath: live, withDestinationPath: newTxt)
    }
    return fm.fileExists(atPath: newTxt) ? newTxt : nil
}

/// Per-meeting metadata (<base>.meta.json, moved by the same-basename
/// rename rule like every other sidecar). The filename stays a readable
/// slug; anything a slug can't hold — exact titles with dashes and
/// punctuation first — lives here. One small JSON per meeting instead of
/// using the filesystem as the database.
func meetingMetaPath(_ txtPath: String) -> String {
    (txtPath as NSString).deletingPathExtension + ".meta.json"
}

func meetingMeta(_ txtPath: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: meetingMetaPath(txtPath)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}

func setMeetingMeta(_ txtPath: String, _ key: String, _ value: Any) {
    var meta = meetingMeta(txtPath)
    meta[key] = value
    if let data = try? JSONSerialization.data(withJSONObject: meta,
                                              options: [.sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: meetingMetaPath(txtPath)))
    }
}

/// A meeting's RECORDING date, from the filename's timestamp — the one
/// thing post-processing can't touch (mtime moves on every reprocess).
/// Falls back to filesystem creation date, then mtime.
func meetingRecordingDate(_ txtPath: String) -> Date {
    let base = ((txtPath as NSString).lastPathComponent as NSString).deletingPathExtension
    let df = DateFormatter()
    for fmt in ["yyyy-MM-dd_HH-mm-ss", "yyyy-MM-dd_HH-mm"] {
        df.dateFormat = fmt
        if let d = df.date(from: String(base.prefix(fmt.count))) { return d }
    }
    let attrs = (try? FileManager.default.attributesOfItem(atPath: txtPath)) ?? [:]
    return (attrs[.creationDate] as? Date)
        ?? (attrs[.modificationDate] as? Date) ?? .distantPast
}

/// "Aug 8 at 3:04 PM" this year; the year appears only for older meetings.
func formatMeetingDate(_ date: Date) -> String {
    let df = DateFormatter()
    let cal = Calendar.current
    df.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: Date())
        ? "MMM d 'at' h:mm a" : "MMM d, yyyy 'at' h:mm a"
    return df.string(from: date)
}

/// Meeting length from the transcript's own record: Ended minus Started
/// when the footer exists; for a live meeting, now minus Started; for a
/// session that died without a footer, the last line stamp. Reads only
/// the file's head and tail — the meetings list calls this on a 2 s tick.
func meetingDuration(_ txtPath: String, isLive: Bool) -> TimeInterval? {
    guard let fh = FileHandle(forReadingAtPath: txtPath) else { return nil }
    defer { try? fh.close() }
    let head = String(data: fh.readData(ofLength: 2048), encoding: .utf8) ?? ""
    guard let sr = head.range(of: #"Started: ([0-9T:+.Z-]+)"#, options: .regularExpression),
          let started = isoParser.date(from: String(head[sr]).replacingOccurrences(
            of: "Started: ", with: "")) else { return nil }
    if isLive { return max(0, Date().timeIntervalSince(started)) }
    let size = (try? fh.seekToEnd()) ?? 0
    let back: UInt64 = min(size, 4096)
    try? fh.seek(toOffset: size - back)
    let tail = String(data: fh.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if let er = tail.range(of: #"Ended: ([0-9T:+.Z-]+)"#, options: .regularExpression),
       let ended = isoParser.date(from: String(tail[er]).replacingOccurrences(
            of: "Ended: ", with: "")) {
        return max(0, ended.timeIntervalSince(started))
    }
    // No footer: last line stamp minus FIRST line stamp. Comparing the
    // last stamp against the Started header breaks on imports, whose
    // stamps are relative to the audio ("[01:50:05]" = 1h50m in) — read
    // as 1:50 AM wall clock that wrapped past midnight into "15h 40m"
    // (field case). First-to-last works for imports (first ≈ 00:00:00)
    // and crashed live sessions (first ≈ Started) alike.
    func stamp(in lines: [Substring]) -> Int? {
        for line in lines {
            if let m = line.range(of: #"^\[(\d{2}):(\d{2}):(\d{2})\]"#,
                                  options: .regularExpression) {
                let p = line[m].dropFirst().dropLast()
                    .split(separator: ":").compactMap { Int($0) }
                if p.count == 3 { return p[0] * 3600 + p[1] * 60 + p[2] }
            }
        }
        return nil
    }
    guard let last = stamp(in: tail.split(separator: "\n").reversed()
                                    .map { $0 }) else { return nil }
    let first = stamp(in: head.split(separator: "\n")) ?? last
    var d = TimeInterval(last - first)
    if d < 0 { d += 86400 }
    return max(0, d)
}

/// "8s" / "42m" / "1h 12m" — compact meeting-length spelling.
func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

/// Display name for a transcript path: timestamp prefix stripped, slug
/// prettified — same rule everywhere a meeting is shown.
func meetingDisplayName(_ txtPath: String) -> String {
    // Exact title from metadata wins; the filename slug is the fallback
    // (it can't hold dashes or punctuation — they round-trip to spaces).
    if let t = meetingMeta(txtPath)["title"] as? String,
       !t.trimmingCharacters(in: .whitespaces).isEmpty {
        return t
    }
    var name = ((txtPath as NSString).lastPathComponent as NSString).deletingPathExtension
    if let r = name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}(-\d{2})?_?"#,
                          options: .regularExpression) {
        name.removeSubrange(r)
    }
    name = name.replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "(untitled)" : name
}

// MARK: - Transcript model

struct TranscriptLine {
    let timestamp: String
    let speaker: String
    let text: String
}

struct SpeakerBlock {
    let timestamp: String
    let speaker: String
    var text: String
    // Constituent transcript lines (index into snapshot.lines + text) so the
    // player can highlight and seek at line granularity inside merged blocks.
    var parts: [(line: Int, text: String)]
}

struct TranscriptSnapshot {
    var lines: [TranscriptLine] = []
    var startedAt: Date?
    var endedAt: Date?

    var blocks: [SpeakerBlock] {
        var out: [SpeakerBlock] = []
        for (i, l) in lines.enumerated() {
            if var last = out.last, last.speaker == l.speaker {
                last.text += " " + l.text
                last.parts.append((line: i, text: l.text))
                out[out.count - 1] = last
            } else {
                out.append(SpeakerBlock(timestamp: l.timestamp,
                                        speaker: l.speaker, text: l.text,
                                        parts: [(line: i, text: l.text)]))
            }
        }
        return out
    }

    var talkShare: [(speaker: String, fraction: Double)] {
        var counts: [String: Int] = [:]
        for l in lines { counts[l.speaker, default: 0] += l.text.count }
        let total = max(1, counts.values.reduce(0, +))
        return counts.map { ($0.key, Double($0.value) / Double(total)) }
            .sorted { $0.1 > $1.1 }
    }
}

let lineRegex = try! NSRegularExpression(pattern: #"^\[(\d{2}:\d{2}:\d{2})\] ([^:]+): (.*)$"#)
let isoParser = ISO8601DateFormatter()

func parseTranscript(_ text: String) -> TranscriptSnapshot {
    var snap = TranscriptSnapshot()
    var current: TranscriptLine? = nil
    for rawLine in text.components(separatedBy: "\n") {
        let ns = rawLine as NSString
        if let m = lineRegex.firstMatch(in: rawLine, range: NSRange(location: 0, length: ns.length)) {
            if let c = current { snap.lines.append(c) }
            current = TranscriptLine(
                timestamp: ns.substring(with: m.range(at: 1)),
                speaker: ns.substring(with: m.range(at: 2)),
                text: ns.substring(with: m.range(at: 3))
            )
        } else if rawLine.hasPrefix("Started:") {
            snap.startedAt = isoParser.date(
                from: rawLine.replacingOccurrences(of: "Started: ", with: "")
                    .trimmingCharacters(in: .whitespaces))
        } else if rawLine.hasPrefix("Ended:") {
            // Metadata before continuation — the footer sits after the last
            // utterance and the old order glued it onto that utterance.
            snap.endedAt = isoParser.date(
                from: rawLine.replacingOccurrences(of: "Ended: ", with: "")
                    .trimmingCharacters(in: .whitespaces))
        } else if rawLine.hasPrefix("---") || rawLine.hasPrefix("#") {
            // Structural/comment lines are never utterance text.
        } else if var c = current, !rawLine.isEmpty {
            c = TranscriptLine(timestamp: c.timestamp, speaker: c.speaker,
                               text: c.text + " " + rawLine)
            current = c
        }
    }
    if let c = current { snap.lines.append(c) }
    return snap
}

// MARK: - Speaker colors

let speakerPalette: [NSColor] = [
    .systemBlue, .systemGreen, .systemOrange, .systemPurple,
    .systemTeal, .systemPink, .systemIndigo, .systemBrown,
]

/// Per-transcript color assignment: first-appearance order walks the
/// palette, so every speaker in a meeting gets a DISTINCT color (hashing
/// collided — Ross and Greg both landed on red). Falls back to hashing
/// only past the palette's end.
func speakerColorMap(_ snap: TranscriptSnapshot) -> [String: NSColor] {
    var map: [String: NSColor] = [:]
    var i = 0
    for l in snap.lines where map[l.speaker] == nil {
        map[l.speaker] = i < speakerPalette.count
            ? speakerPalette[i] : speakerColor(l.speaker)
        i += 1
    }
    return map
}

/// Post-processing state written by cmd_stop's pipeline (refine → names →
/// title). nil when idle; stale files (crashed pipeline) are ignored.
func postprocState() -> String? {
    let path = "/tmp/meetink-postproc.state"
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let m = attrs[.modificationDate] as? Date,
          Date().timeIntervalSince(m) < 1800,
          let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let line = txt.trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
}

/// The transcript currently being post-processed (written alongside the
/// state file), so per-meeting UI can mark the right row.
func postprocPath() -> String? {
    let path = "/tmp/meetink-postproc.path"
    guard postprocState() != nil,
          let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let line = txt.trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
}

/// Kill an in-flight post-process when a deletion orphans it. Exact
/// path comparison misses: the pipeline records its target at START and
/// titling renames mid-run. Folder-level match catches the rename case;
/// the target-no-longer-exists check (call AFTER trashing) catches
/// everything else — whatever the job thinks it's writing, it's gone.
func killPostprocIfOrphaned(deletedPath: String) {
    guard let pp = postprocPath(), let launcher = launcherPath() else { return }
    let sameFolder = (pp as NSString).deletingLastPathComponent
        == (deletedPath as NSString).deletingLastPathComponent
    let orphaned = !FileManager.default.fileExists(atPath: pp)
    guard pp == deletedPath || sameFolder || orphaned else { return }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launcher)
    proc.arguments = ["postproc-kill"]
    try? proc.run()
    proc.waitUntilExit()
}

func speakerColor(_ speaker: String) -> NSColor {
    var h = 0
    for u in speaker.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0x7fffffff }
    return speakerPalette[h % speakerPalette.count]
}

let unknownSpeakerRegex = try! NSRegularExpression(pattern: #"^Speaker (\d+)$"#)

func unknownSpeakerNumber(_ speaker: String) -> String? {
    let ns = speaker as NSString
    guard let m = unknownSpeakerRegex.firstMatch(
        in: speaker, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return ns.substring(with: m.range(at: 1))
}

// MARK: - Drag-and-drop container

let audioExtensions: Set<String> = [
    "wav", "m4a", "mp3", "aiff", "aif", "caf", "flac", "ogg", "opus",
    "mp4", "mov", "webm", "aac", "mkv",
]

final class DropContainerView: NSView {
    var onAudioDrop: (([URL]) -> Void)?
    var onDragState: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func audioURLs(from sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: opts) as? [URL] else { return [] }
        return urls.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !audioURLs(from: sender).isEmpty
        onDragState?(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragState?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragState?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragState?(false)
        let urls = audioURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onAudioDrop?(urls)
        return true
    }
}

// MARK: - Transcript page (live or archived)

final class TranscriptViewController: NSViewController, NSTextViewDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate,
                                      NSTextFieldDelegate {
    private let textView = NSTextView()
    private let headerField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(string: "")
    private let speakersTable = NSTableView()
    private enum PanelRow {
        case speaker(name: String, fraction: Double, hidden: Bool)
        case toggle(count: Int)
    }
    private var panelRows: [PanelRow] = []
    private var speakers: [(name: String, fraction: Double)] = []
    private var showHiddenSpeakers = false
    private var speakersWidthConstraint: NSLayoutConstraint? = nil
    private var currentSpeakingName: String? = nil
    private let statusDot = NSTextField(labelWithString: "●")
    private let copyButton = NSButton(title: "Copy All", target: nil, action: nil)
    private let folderButton = NSButton(title: "Open Folder", target: nil, action: nil)
    /// Event link as a dropdown in the header bar: shows the linked
    /// calendar event (or "No Event"); clicking lists the day's events.
    private let eventButton = NSButton(title: "No Event", target: nil, action: nil)
    private let downloadButton = NSButton(title: "Download Transcript", target: nil, action: nil)
    private let reprocessButton = NSButton(title: "Reprocess", target: nil, action: nil)
    private let menuButton = NSButton(title: "", target: nil, action: nil)
    private var fetchedEvents: [[String: Any]] = []
    /// Wired by MainWindowController: after Delete, go back to Meetings.
    var onMeetingDeleted: (() -> Void)? = nil
    private let jumpButton = NSButton(title: "", target: nil, action: nil)

    private var pollTimer: Timer?
    private var lastInode: UInt64 = 0
    private var lastSize: UInt64 = 0
    private var lastMtime: TimeInterval = 0
    private var lastResolvedPath: String = ""
    private var rawText: String = ""
    private var snapshot = TranscriptSnapshot()
    private var colorMap: [String: NSColor] = [:]

    // --- Chat with the transcript ---
    // Collapsed to a single bar; expands to a small log + input. Sits
    // directly above the player bar for recordings, and at the window
    // bottom for the live view (the collapsed player bar is 0pt there).
    private let chatPanel = NSStackView()
    private let chatToggle = NSButton()
    private let chatBody = NSStackView()
    private let chatLogScroll = NSScrollView()
    private let chatLog = NSTextView()
    private let chatField = NSTextField()
    private var chatHistory: [(q: String, a: String)] = []
    private var chatPending: String? = nil
    private var chatBusy = false

    // --- Playback (archived transcripts with a kept .m4a only) ---
    private var player: AVAudioPlayer? = nil
    private var audioPath: String? = nil
    private let playerBar = NSStackView()
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "")
    private let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var playerBarHeight: NSLayoutConstraint? = nil
    private let noAudioLabel = NSTextField(labelWithString: "No audio available — enable “Keep audio recording” in Settings")
    private var playTimer: Timer? = nil
    private var lineRanges: [Int: NSRange] = [:]     // line index -> text range
    private var lineOffsets: [Double] = []           // line index -> seconds into audio
    private var highlightedRange: NSRange? = nil
    private func color(for speaker: String) -> NSColor {
        colorMap[speaker] ?? speakerColor(speaker)
    }

    /// nil = follow the live symlink; a path = show that transcript.
    private(set) var fixedPath: String? = nil

    override func loadView() {
        let content = NSView()

        // Two header rows for recordings: an editable title (Enter saves —
        // renames the meeting's folder and files), then the status strip.
        titleField.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.placeholderString = "(untitled)"
        titleField.delegate = self
        titleField.lineBreakMode = .byTruncatingTail
        titleField.isHidden = true
        titleField.toolTip = "Click to rename this meeting (Enter saves)"

        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.spacing = 8

        let header = NSStackView(views: [titleField, strip])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 2
        header.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false
        titleField.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -24).isActive = true
        strip.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -24).isActive = true

        statusDot.font = NSFont.systemFont(ofSize: 12)
        headerField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        headerField.lineBreakMode = .byTruncatingTail
        headerField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        folderButton.bezelStyle = .rounded
        folderButton.controlSize = .small
        folderButton.font = NSFont.systemFont(ofSize: 11)
        folderButton.target = self
        folderButton.action = #selector(openFolder)
        menuButton.bezelStyle = .rounded
        menuButton.controlSize = .small
        menuButton.image = NSImage(systemSymbolName: "ellipsis.circle",
                                   accessibilityDescription: "More actions")
        menuButton.target = self
        menuButton.action = #selector(showActionsMenu)
        reprocessButton.bezelStyle = .rounded
        reprocessButton.controlSize = .small
        reprocessButton.font = NSFont.systemFont(ofSize: 11)
        reprocessButton.target = self
        reprocessButton.action = #selector(reprocess)
        reprocessButton.toolTip = "Re-run transcription, diarization and audio "
            + "enhancement on this meeting's kept audio"
        reprocessButton.isHidden = true
        eventButton.bezelStyle = .rounded
        eventButton.controlSize = .small
        eventButton.font = NSFont.systemFont(ofSize: 11)
        eventButton.image = NSImage(systemSymbolName: "calendar",
                                    accessibilityDescription: "Calendar event")
        eventButton.imagePosition = .imageLeading
        eventButton.lineBreakMode = .byTruncatingTail
        eventButton.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        eventButton.target = self
        eventButton.action = #selector(linkEvent)
        eventButton.toolTip = "Link this meeting to a calendar event"
        downloadButton.bezelStyle = .rounded
        downloadButton.controlSize = .small
        downloadButton.font = NSFont.systemFont(ofSize: 11)
        downloadButton.target = self
        downloadButton.action = #selector(downloadTranscript)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = NSFont.systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyAll)

        strip.addArrangedSubview(statusDot)
        strip.addArrangedSubview(headerField)
        strip.addArrangedSubview(NSView())
        strip.addArrangedSubview(eventButton)
        strip.addArrangedSubview(reprocessButton)
        strip.addArrangedSubview(folderButton)
        strip.addArrangedSubview(downloadButton)
        strip.addArrangedSubview(copyButton)
        strip.addArrangedSubview(menuButton)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Speakers panel — left of the transcript, under the status bar.
        // Live talk-share per speaker, same colors as the transcript;
        // clicking a row opens the same name/reassign dialog as clicking
        // a label inline.
        let speakersScroll = NSScrollView()
        speakersScroll.translatesAutoresizingMaskIntoConstraints = false
        speakersScroll.hasVerticalScroller = true
        speakersScroll.autohidesScrollers = true
        speakersScroll.drawsBackground = false
        let speakerCol = NSTableColumn(identifier: .init("speaker"))
        speakersTable.addTableColumn(speakerCol)
        speakersTable.headerView = nil
        speakersTable.rowHeight = 26
        speakersTable.backgroundColor = .clear
        speakersTable.selectionHighlightStyle = .none
        speakersTable.intercellSpacing = NSSize(width: 0, height: 2)
        speakersTable.dataSource = self
        speakersTable.delegate = self
        speakersTable.target = self
        speakersTable.action = #selector(speakerRowClicked)
        speakersScroll.documentView = speakersTable

        let panelDivider = PanelDividerView()
        panelDivider.translatesAutoresizingMaskIntoConstraints = false
        panelDivider.onDrag = { [weak self] dx in
            guard let self, let c = self.speakersWidthConstraint else { return }
            // Divider sits LEFT of the panel: dragging right shrinks it.
            let w = min(400, max(120, c.constant - dx))
            c.constant = w
            UserDefaults.standard.set(Double(w), forKey: "speakersPanelWidth")
        }

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        // No global link styling/cursor: body-text play-links keep the
        // I-beam (they read as text and drag-select must feel normal);
        // name/timestamp links carry their own hand cursor per-range.
        // A plain click fires the link (play); click-drag selects text
        // without firing — NSTextView's default link behavior.
        textView.linkTextAttributes = [:]
        textView.delegate = self
        scroll.documentView = textView

        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.bezelStyle = .rounded
        jumpButton.title = " Jump to live"
        jumpButton.image = NSImage(systemSymbolName: "arrow.down.to.line",
                                   accessibilityDescription: "Jump to end")
        jumpButton.imagePosition = .imageLeading
        jumpButton.target = self
        jumpButton.action = #selector(jumpToEnd)
        jumpButton.isHidden = true

        // Player bar (hidden until an archived transcript with audio loads).
        func barButton(_ symbol: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: "", target: self, action: action)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            return b
        }
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.bezelStyle = .texturedRounded
        playButton.isBordered = false
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        scrubber.target = self
        scrubber.action = #selector(scrubbed)
        scrubber.controlSize = .small
        playerBar.orientation = .horizontal
        playerBar.spacing = 10
        playerBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        playerBar.translatesAutoresizingMaskIntoConstraints = false
        noAudioLabel.font = NSFont.systemFont(ofSize: 11)
        noAudioLabel.textColor = .tertiaryLabelColor
        noAudioLabel.isHidden = true
        playerBar.addSubview(noAudioLabel)
        noAudioLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noAudioLabel.centerYAnchor.constraint(equalTo: playerBar.centerYAnchor),
            noAudioLabel.leadingAnchor.constraint(equalTo: playerBar.leadingAnchor, constant: 12),
        ])
        playerBar.addArrangedSubview(barButton("gobackward.10", #selector(back10)))
        playerBar.addArrangedSubview(playButton)
        playerBar.addArrangedSubview(barButton("goforward.10", #selector(fwd10)))
        playerBar.addArrangedSubview(scrubber)
        playerBar.addArrangedSubview(timeLabel)
        playerBar.isHidden = true
        playerBar.edgeInsets = NSEdgeInsets()
        playerBarHeight = playerBar.heightAnchor.constraint(equalToConstant: 0)
        // 999, not required: a collapsed bar whose insets/content want more
        // than 0pt must lose gracefully — a REQUIRED conflict makes AppKit
        // break arbitrary constraints every layout pass (field symptom: the
        // window resists resizing edge by edge, and the transcript column
        // can collapse to zero width so a live meeting renders nothing).
        playerBarHeight?.priority = NSLayoutConstraint.Priority(999)
        playerBarHeight?.isActive = true

        // --- Chat panel ---
        let chatDivider = NSBox()
        chatDivider.boxType = .separator
        chatToggle.title = "Ask about this meeting…"
        if let bubble = NSImage(systemSymbolName: "bubble.left",
                                accessibilityDescription: "Chat") {
            chatToggle.image = bubble
            chatToggle.imagePosition = .imageLeading
        }
        chatToggle.isBordered = false
        chatToggle.alignment = .left
        chatToggle.font = NSFont.systemFont(ofSize: 12)
        chatToggle.contentTintColor = .secondaryLabelColor
        chatToggle.target = self
        chatToggle.action = #selector(chatToggleClicked)
        chatLog.isEditable = false
        chatLog.drawsBackground = false
        chatLog.textContainerInset = NSSize(width: 4, height: 6)
        chatLog.autoresizingMask = [.width]
        chatLog.isVerticallyResizable = true
        chatLog.textContainer?.widthTracksTextView = true
        chatLogScroll.documentView = chatLog
        chatLogScroll.hasVerticalScroller = true
        chatLogScroll.drawsBackground = false
        // 999, not required — same graceful-collapse rule as the player
        // bar's height (a required conflict breaks random constraints).
        let chatLogHeight = chatLogScroll.heightAnchor.constraint(equalToConstant: 170)
        chatLogHeight.priority = NSLayoutConstraint.Priority(999)
        chatLogHeight.isActive = true
        chatField.placeholderString = "Ask — answers use the transcript as it is right now"
        chatField.target = self
        chatField.action = #selector(chatSend)
        chatBody.orientation = .vertical
        chatBody.alignment = .width
        chatBody.spacing = 6
        chatBody.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        chatBody.addArrangedSubview(chatLogScroll)
        chatBody.addArrangedSubview(chatField)
        chatBody.isHidden = true
        chatPanel.orientation = .vertical
        chatPanel.alignment = .width
        chatPanel.spacing = 2
        chatPanel.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        chatPanel.addArrangedSubview(chatDivider)
        chatPanel.addArrangedSubview(chatToggle)
        chatPanel.addArrangedSubview(chatBody)
        chatPanel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(divider)
        content.addSubview(playerBar)
        content.addSubview(chatPanel)
        content.addSubview(speakersScroll)
        content.addSubview(panelDivider)
        content.addSubview(scroll)
        content.addSubview(jumpButton)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // No pinned header height: the stack's insets + rows already
            // define it EXACTLY (required internal constraints), and a
            // hard 32/56pt pin disagreed with that fitting size by 1-2pt —
            // an unsatisfiable system on every reader layout pass, with a
            // randomly chosen constraint broken each time (the shape-
            // shifting 'narrow window' bug's last root).
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panelDivider.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: chatPanel.topAnchor),
            chatPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chatPanel.trailingAnchor.constraint(equalTo: panelDivider.leadingAnchor),
            chatPanel.bottomAnchor.constraint(equalTo: playerBar.topAnchor),
            panelDivider.topAnchor.constraint(equalTo: divider.bottomAnchor),
            panelDivider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            panelDivider.widthAnchor.constraint(equalToConstant: 7),
            speakersScroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            speakersScroll.leadingAnchor.constraint(equalTo: panelDivider.trailingAnchor),
            {
                let saved = UserDefaults.standard.double(forKey: "speakersPanelWidth")
                let c = speakersScroll.widthAnchor.constraint(
                    equalToConstant: saved >= 120 ? saved : 170)
                c.priority = NSLayoutConstraint.Priority(999)
                self.speakersWidthConstraint = c
                return c
            }(),
            speakersScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            speakersScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            playerBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerBar.trailingAnchor.constraint(equalTo: panelDivider.leadingAnchor),
            playerBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            jumpButton.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            // Anchor to the transcript scroll, not the window bottom — the
            // player bar lives below the scroll now and the button was
            // floating on top of it.
            jumpButton.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -16),
        ])

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                self?.updateJumpButton()
            }

        self.view = content
    }

    private var keyMonitor: Any? = nil

    override func viewDidLoad() {
        super.viewDidLoad()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshIfChanged()
        }
        // Transport keys while a recording with audio is on screen:
        // space = play/pause, left/right arrow = -/+15 s. Never while the
        // user is actually typing somewhere (field editors are editable
        // NSTextViews; our transcript view is not).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self,
                  self.audioPath != nil,
                  self.view.window != nil,
                  self.view.window?.isKeyWindow == true,
                  ev.window == self.view.window else { return ev }
            if let editor = self.view.window?.firstResponder as? NSTextView,
               editor.isEditable { return ev }
            switch ev.keyCode {
            case 49:   // space
                self.togglePlay()
                return nil
            case 123:  // left arrow
                self.seek(to: (self.player?.currentTime ?? 0) - 15, andPlay: false)
                return nil
            case 124:  // right arrow
                self.seek(to: (self.player?.currentTime ?? 0) + 15, andPlay: false)
                return nil
            default:
                return ev
            }
        }
        refreshIfChanged(force: true)
    }

    func show(path: String?) {
        // A different meeting is a different conversation.
        if path != fixedPath {
            chatHistory.removeAll()
            chatPending = nil
            renderChatLog()
        }
        fixedPath = path
        refreshIfChanged(force: true)
    }

    /// Re-render the transcript at the current uiZoom (⌘+/⌘-).
    func zoomChanged() {
        render(empty: snapshot.blocks.isEmpty)
    }

    // MARK: chat with the transcript

    @objc private func chatToggleClicked() {
        chatBody.isHidden.toggle()
        if !chatBody.isHidden {
            view.window?.makeFirstResponder(chatField)
        }
    }

    @objc private func chatSend() {
        let q = chatField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !chatBusy, let launcher = launcherPath(),
              !lastResolvedPath.isEmpty else { return }
        let path = lastResolvedPath
        chatBusy = true
        chatField.isEnabled = false
        chatField.stringValue = ""
        chatPending = q
        renderChatLog()
        // Fold recent turns into the question so follow-ups have context —
        // cmd_ask itself is single-shot. The transcript is re-read by the
        // CLI on every call, which is what makes live chat live.
        var question = q
        if !chatHistory.isEmpty {
            let hist = chatHistory.suffix(3)
                .map { "Q: \($0.q)\nA: \($0.a)" }.joined(separator: "\n")
            question = "Earlier in this chat:\n\(hist)\n\nNew question: \(q)"
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["ask", "--plain", "--file", path, question]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        DispatchQueue.global().async { [weak self] in
            var answer = ""
            do {
                try proc.run()
                // Read to EOF BEFORE waitUntilExit (64 KB pipe deadlock).
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                answer = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch {}
            if answer.isEmpty {
                answer = "(no answer — is the claude CLI or a local LLM configured? See /tmp/meetink-*.log)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.chatHistory.append((q: q, a: answer))
                self.chatPending = nil
                self.chatBusy = false
                self.chatField.isEnabled = true
                self.renderChatLog()
                self.view.window?.makeFirstResponder(self.chatField)
            }
        }
    }

    private func renderChatLog() {
        let out = NSMutableAttributedString()
        let size = round(12 * uiZoom)
        let qAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: size),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let aAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.labelColor,
        ]
        for turn in chatHistory {
            out.append(NSAttributedString(string: "\(turn.q)\n", attributes: qAttrs))
            out.append(NSAttributedString(string: "\(turn.a)\n\n", attributes: aAttrs))
        }
        if let pending = chatPending {
            out.append(NSAttributedString(string: "\(pending)\n", attributes: qAttrs))
            out.append(NSAttributedString(
                string: "thinking…\n",
                attributes: [.font: NSFont.systemFont(ofSize: size),
                             .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        chatLog.textStorage?.setAttributedString(out)
        chatLog.scrollToEndOfDocument(nil)
    }

    private var pinnedToBottom: Bool {
        guard let scroll = textView.enclosingScrollView else { return true }
        let visible = scroll.contentView.bounds
        return visible.maxY >= textView.frame.height - 40
    }

    private func updateJumpButton() {
        // Only meaningful while text is streaming in — an archived
        // recording has no "live" to jump to.
        let live = fixedPath == nil && recordingPID() != nil
        jumpButton.isHidden = pinnedToBottom || !live
    }

    @objc private func jumpToEnd() {
        textView.scrollToEndOfDocument(nil)
        jumpButton.isHidden = true
    }

    /// Clicking away from the title field commits the edit — Enter was
    /// the only save path, so click-away silently discarded typing and
    /// the next poll repopulated the old (event) title: 'my rename
    /// reverted'.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) == titleField else { return }
        commitTitleEdit()
    }

    private func commitTitleEdit() {
        let newName = titleField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, !lastResolvedPath.isEmpty,
              newName != meetingDisplayName(lastResolvedPath) else { return }
        if let newPath = renameMeeting(txtPath: lastResolvedPath, displayName: newName) {
            if fixedPath != nil { fixedPath = newPath }
            refreshIfChanged(force: true)
        }
    }

    /// Enter in the title field renames the meeting on disk (folder +
    /// same-basename siblings, live symlink retargeted) and re-points this
    /// page at the new path.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard control == titleField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTitleEdit()
            view.window?.makeFirstResponder(textView.superview)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            titleField.stringValue = meetingDisplayName(lastResolvedPath)
            view.window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    /// The … menu: contextual actions for the current page — Link Event
    /// and Delete on recordings, Discard on the live view (the forgotten
    /// 14-hour capture must die WITHOUT a trip through post-processing).
    @objc private func showActionsMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ sel: Selector) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
        }
        let liveRecording = fixedPath == nil && recordingPID() != nil
        if liveRecording {
            add("Discard Recording…", #selector(discardRecording))
        } else if !lastResolvedPath.isEmpty {
            // Event linking moved to the header's calendar dropdown.
            add("Relabel Speakers (fast)…", #selector(relabelSpeakers))
            menu.addItem(.separator())
            add("Delete Meeting…", #selector(deleteMeeting))
        } else {
            add("No transcript open", #selector(showActionsMenu))
            menu.items.last?.isEnabled = false
        }
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: menuButton)
        } else {
            menu.popUp(positioning: nil, at: .zero, in: menuButton)
        }
    }

    @objc private func discardRecording() {
        let alert = NSAlert()
        alert.messageText = "Discard this recording?"
        alert.informativeText = "Stops recording immediately and deletes the "
            + "transcript and audio. No post-processing runs. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        guard alert.runModal() == .alertSecondButtonReturn,
              let launcher = launcherPath() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["discard"]
        DispatchQueue.global().async { [weak self] in
            try? proc.run()
            proc.waitUntilExit()
            DispatchQueue.main.async { self?.refreshIfChanged(force: true) }
        }
    }

    @objc private func deleteMeeting() {
        let path = lastResolvedPath
        guard !path.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(meetingDisplayName(path))”?"
        alert.informativeText = "The meeting (transcript, summary, audio) moves to the Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        stopPlayback()
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if (dir as NSString).lastPathComponent == base {
            try? fm.trashItem(at: URL(fileURLWithPath: dir), resultingItemURL: nil)
        } else {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            where item.hasPrefix(base + ".") {
                try? fm.trashItem(at: URL(fileURLWithPath: dir + "/" + item),
                                  resultingItemURL: nil)
            }
        }
        killPostprocIfOrphaned(deletedPath: path)
        onMeetingDeleted?()
    }

    /// Calendar events around the recording's start (4 h before to 8 h
    /// after), via the agent's --from/--to window. Selecting one renames
    /// the meeting to the event title and records the attendees — in
    /// meta.json and as the transcript's # attendees: header, the same
    /// line the live tooling reads.
    @objc private func linkEvent() {
        guard !lastResolvedPath.isEmpty else { return }
        let start = snapshot.startedAt ?? meetingRecordingDate(lastResolvedPath)
        let agent = "\(mkHome)/bin/MeetinkAgent.app/Contents/MacOS/meetink-agent"
        guard FileManager.default.isExecutableFile(atPath: agent) else { return }
        let iso = ISO8601DateFormatter()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agent)
        var eventArgs = ["events",
                         "--from", iso.string(from: start.addingTimeInterval(-4 * 3600)),
                         "--to", iso.string(from: start.addingTimeInterval(8 * 3600))]
        if let hidden = configValue("hidden_calendars"), !hidden.isEmpty {
            eventArgs += ["--hidden-calendars", hidden]
        }
        proc.arguments = eventArgs
        let pipe = Pipe()
        proc.standardOutput = pipe
        eventButton.isEnabled = false
        DispatchQueue.global().async { [weak self] in
            defer { DispatchQueue.main.async { self?.eventButton.isEnabled = true } }
            do { try proc.run() } catch { return }
            // Read to EOF BEFORE waitUntilExit — a day's events with
            // attendees overflows the 64 KB pipe buffer, the agent blocks
            // mid-write, and waiting first deadlocks both processes (field
            // case: button stuck disabled forever after the permission
            // prompt resolved).
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let events = (try? JSONSerialization.jsonObject(with: data)
                          as? [[String: Any]]) ?? []
            DispatchQueue.main.async { self?.showEventMenu(events, near: start) }
        }
    }

    private func showEventMenu(_ events: [[String: Any]], near start: Date) {
        fetchedEvents = events
        let menu = NSMenu()
        // "No Event" unlinks (tag -1). Checkmarked when nothing is linked.
        let none = NSMenuItem(title: "No Event",
                              action: #selector(eventPicked(_:)), keyEquivalent: "")
        none.target = self
        none.tag = -1
        if (meetingMeta(lastResolvedPath)["event"] as? [String: Any]) == nil {
            none.state = .on
        }
        menu.addItem(none)
        menu.addItem(.separator())
        if events.isEmpty {
            menu.addItem(NSMenuItem(
                title: "No calendar events found (is calendar access granted?)",
                action: nil, keyEquivalent: ""))
        }
        let iso = ISO8601DateFormatter()
        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        // Chronological list. The LINKED event gets the checkmark; with
        // nothing linked, the event nearest the recording start does
        // (so the eye lands on the likely pick).
        let linked = meetingMeta(lastResolvedPath)["event"] as? [String: Any]
        var marked = -1
        if let linked {
            marked = events.firstIndex(where: {
                ($0["start"] as? String) == (linked["start"] as? String)
                    && ($0["title"] as? String) == (linked["title"] as? String)
            }) ?? -1
        }
        if marked < 0 && linked == nil {
            var best = Double.infinity
            for (i, e) in events.enumerated() {
                guard let d = iso.date(from: (e["start"] as? String) ?? "") else { continue }
                let dist = abs(d.timeIntervalSince(start))
                if dist < best { best = dist; marked = i }
            }
        }
        for (i, e) in events.enumerated() {
            let when = iso.date(from: (e["start"] as? String) ?? "")
            let item = NSMenuItem(
                title: "\(when.map { tf.string(from: $0) } ?? "?")   \((e["title"] as? String) ?? "(untitled)")",
                action: #selector(eventPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            if i == marked { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: eventButton.bounds.height + 4),
                   in: eventButton)
    }

    @objc private func eventPicked(_ sender: NSMenuItem) {
        if sender.tag == -1 {
            // Unlink: drop the event record; the title and headers stay.
            setMeetingMeta(lastResolvedPath, "event", NSNull())
            refreshIfChanged(force: true)
            return
        }
        guard sender.tag >= 0, sender.tag < fetchedEvents.count else { return }
        let e = fetchedEvents[sender.tag]
        let newPath = applyEventToMeeting(txtPath: lastResolvedPath, event: e)
        if fixedPath != nil { fixedPath = newPath }
        refreshIfChanged(force: true)
    }

    /// Fast recluster: propagates per-segment corrections (exemplar
    /// anchoring) without retranscribing — about a minute, vs a full
    /// reprocess's many. The transcript reloads via the file watcher.
    @objc private func relabelSpeakers() {
        guard let launcher = launcherPath(), !lastResolvedPath.isEmpty else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["relabel", lastResolvedPath]
        DispatchQueue.global().async { [weak self] in
            try? proc.run()
            proc.waitUntilExit()
            DispatchQueue.main.async { self?.refreshIfChanged(force: true) }
        }
    }

    /// Re-run the whole pipeline on this recording's kept audio (spools
    /// preferred, m4a fallback — cmd_reprocess). The transcript reloads by
    /// itself through the file watcher as the refine rewrites it.
    @objc private func reprocess() {
        guard let launcher = launcherPath(), !lastResolvedPath.isEmpty else { return }
        reprocessButton.isEnabled = false
        reprocessButton.title = "Reprocessing…"
        let path = lastResolvedPath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["reprocess", path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        DispatchQueue.global().async { [weak self] in
            do { try proc.run() } catch { return }
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self?.reprocessButton.isEnabled = true
                self?.reprocessButton.title = "Reprocess"
                self?.refreshIfChanged(force: true)
                // Exit code only — substring-matching 'error' false-positived
                // on successful runs.
                if proc.terminationStatus != 0 {
                    let alert = NSAlert()
                    alert.messageText = "Reprocess failed (exit \(proc.terminationStatus))"
                    alert.informativeText = out.replacingOccurrences(
                        of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openFolder() {
        guard !lastResolvedPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: lastResolvedPath)])
    }

    /// Save a copy of the transcript wherever the user picks — the save
    /// panel grants write access to the chosen location by consent, so
    /// Downloads works without a standing TCC grant.
    @objc private func downloadTranscript() {
        guard !lastResolvedPath.isEmpty else { return }
        let panel = NSSavePanel()
        // "_transcript_7-30" — the meeting's month-day, no leading zeros.
        let df = DateFormatter()
        df.dateFormat = "M-d"
        let suffix = "_transcript_" + df.string(from: meetingRecordingDate(lastResolvedPath))
        panel.nameFieldStringValue = meetingDisplayName(lastResolvedPath)
            .replacingOccurrences(of: "/", with: "-") + suffix + ".txt"
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { [weak self] response in
            guard response == .OK, let dest = panel.url, let self else { return }
            let content = self.exportHeader()
                + ((try? String(contentsOfFile: self.lastResolvedPath, encoding: .utf8)) ?? "")
            try? content.write(to: dest, atomically: true, encoding: .utf8)
        }
    }

    /// Context block prepended to exports (Download / Copy All) — built
    /// at EXPORT time so it always reflects the current labels and edits.
    /// Written for the next reader, human or LLM: who spoke and how much,
    /// what calendar event this was (attendees ≠ speakers), and the
    /// caveat that low-share unlabeled voices are usually diarization
    /// artifacts, not extra participants.
    private func exportHeader() -> String {
        var lines: [String] = []
        lines.append("# Meeting: \(meetingDisplayName(lastResolvedPath))")
        var dateLine = "# Date: \(formatMeetingDate(snapshot.startedAt ?? meetingRecordingDate(lastResolvedPath)))"
        if let dur = meetingDuration(lastResolvedPath, isLive: false) {
            dateLine += "  ·  Duration: \(formatDuration(dur))"
        }
        lines.append(dateLine)
        let meta = meetingMeta(lastResolvedPath)
        if let trimmed = meta["trimmed_trailing_s"] as? Int, trimmed >= 60 {
            lines.append("# Note: \(trimmed / 60) minutes of trailing silence were "
                + "trimmed (the recording ran past the end of the meeting).")
        }
        if let event = meta["event"] as? [String: Any] {
            if let t = event["title"] as? String, !t.isEmpty {
                var ev = "# Calendar event: \(t)"
                if let st = event["start"] as? String, !st.isEmpty { ev += " — \(st)" }
                lines.append(ev)
            }
            if let att = event["attendees"] as? [String], !att.isEmpty {
                lines.append("# Event attendees (invited — not necessarily who spoke): "
                    + att.joined(separator: ", "))
            }
        }
        let hidden = hiddenSpeakerNames()
        let visible = snapshot.talkShare.filter { !hidden.contains($0.speaker.uppercased()) }
        let vTotal = max(visible.reduce(0) { $0 + $1.fraction }, 0.0001)
        if !visible.isEmpty {
            lines.append("# Speakers by talk share: " + visible.map {
                "\($0.speaker) \(Int(($0.fraction / vTotal * 100).rounded()))%"
            }.joined(separator: ", "))
        }
        let hiddenPresent = snapshot.talkShare.filter { hidden.contains($0.speaker.uppercased()) }
        if !hiddenPresent.isEmpty {
            lines.append("# Non-participants (excluded from shares): "
                + hiddenPresent.map(\.speaker).joined(separator: ", "))
        }
        if visible.contains(where: { $0.speaker.hasPrefix("Speaker ") }) {
            lines.append("# Note: unlabeled 'Speaker N' voices with low share are usually "
                + "cross-talk or hard-to-diarize moments, not additional participants "
                + "(possible, but unlikely).")
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    @objc private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(exportHeader() + (rawText.isEmpty ? textView.string : rawText),
                     forType: .string)
        copyButton.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = "Copy All"
        }
    }

    // MARK: Click-to-name

    /// Right-click menu on the transcript: structured segment editing.
    /// Recordings only — a live transcript is being written by capture.
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent,
                  at charIndex: Int) -> NSMenu? {
        let liveRecording = fixedPath == nil && recordingPID() != nil
        guard !liveRecording, !lastResolvedPath.isEmpty,
              let line = lineIndex(forChar: charIndex) else { return menu }
        let edit = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.representedObject = ["line": line, "char": charIndex]
            edit.addItem(i)
        }
        add("Edit Segment…", #selector(menuEditSegment(_:)))
        add("Reassign Segment to…", #selector(menuReassignSegment(_:)))
        add("Split Segment Here", #selector(menuSplitSegment(_:)))
        add("Delete Segment…", #selector(menuDeleteSegment(_:)))
        edit.addItem(.separator())
        for item in menu.items where item.action == #selector(NSText.copy(_:)) {
            edit.addItem(item.copy() as! NSMenuItem)
        }
        return edit
    }

    private func lineIndex(forChar charIndex: Int) -> Int? {
        for (line, range) in lineRanges
        where charIndex >= range.location && charIndex < range.location + range.length + 1 {
            return line
        }
        return nil
    }

    /// Rewrite ONE line's speaker label (not the whole cluster — that's
    /// the panel's job). This is how a freshly split half changes hands:
    /// same-speaker halves render as one block, but the right-click knows
    /// which LINE it landed on, and once the label differs the block view
    /// separates them naturally.
    @objc private func menuReassignSegment(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Int],
              let line = info["line"], line < snapshot.lines.count else { return }
        let seg = snapshot.lines[line]
        let alert = NSAlert()
        alert.messageText = "Reassign this segment"
        alert.informativeText = String(seg.text.prefix(120))
        alert.addButton(withTitle: "Reassign")
        alert.addButton(withTitle: "Cancel")
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 220, height: 25))
        combo.addItems(withObjectValues: enrolledProfiles())
        combo.placeholderString = "Name"
        combo.completes = true
        combo.numberOfVisibleItems = 16
        combo.delegate = ComboAutoOpen.shared
        alert.accessoryView = combo
        alert.window.initialFirstResponder = combo
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = combo.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return }
        guard var (all, idx) = readTranscriptLines(), line < idx.count else { return }
        snapshotBeforeFirstEdit()
        all[idx[line]] = "[\(seg.timestamp)] \(name): \(seg.text)"
        var entry: [String: Any] = ["label": name]
        entry["t"] = line < lineOffsets.count ? lineOffsets[line] : 0
        // Keep the words — the text didn't change, only the label.
        let tPath = (lastResolvedPath as NSString).deletingPathExtension + ".timing.json"
        if let data = FileManager.default.contents(atPath: tPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tl = obj["lines"] as? [[String: Any]], line < tl.count {
            entry["words"] = tl[line]["words"] ?? []
        }
        spliceTiming(line: line, with: [entry])
        writeTranscriptLines(all)
    }

    @objc private func menuEditSegment(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Int],
              let line = info["line"] else { return }
        editSegment(line)
    }

    @objc private func menuSplitSegment(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Int],
              let line = info["line"], let ch = info["char"],
              let range = lineRanges[line] else { return }
        splitSegment(line, atChar: ch - range.location)
    }

    @objc private func menuDeleteSegment(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Int],
              let line = info["line"], line < snapshot.lines.count else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this segment?"
        alert.informativeText = String(snapshot.lines[line].text.prefix(120))
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        deleteSegment(line)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, url.scheme == "meetink-play",
           let idx = Int(url.host ?? ""), idx < lineOffsets.count {
            seek(to: lineOffsets[idx], andPlay: true)
            return true
        }
        guard let url = link as? URL, url.scheme == "meetink-assign" else { return false }
        // Label travels percent-encoded in ?label= (it can be anything:
        // "Speaker 3", "GREG", "ADRIANA 2"). The old host-only form
        // (meetink-assign://3) is still accepted.
        var label: String? = nil
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            label = comps.queryItems?.first(where: { $0.name == "label" })?.value
        }
        if label == nil, let num = url.host { label = "Speaker \(num)" }
        guard let label, !label.isEmpty else { return false }
        promptForName(label: label)
        return true
    }

    private func promptForName(label: String) {
        let alert = NSAlert()
        let isUnnamed = label.hasPrefix("Speaker ") || label == "THEM"
        alert.messageText = isUnnamed ? "Who is \(label)?" : "Reassign \(label)?"
        alert.informativeText = "Names the speaker, rewrites the transcript, and "
            + "enrolls their voice when the session's voice data is still available."
        alert.addButton(withTitle: isUnnamed ? "Assign" : "Reassign")
        alert.addButton(withTitle: "Cancel")
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 220, height: 25))
        combo.addItems(withObjectValues: enrolledProfiles())
        combo.placeholderString = "Name"
        combo.completes = true
        combo.numberOfVisibleItems = 16
        combo.delegate = ComboAutoOpen.shared
        alert.accessoryView = combo
        alert.window.initialFirstResponder = combo
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = combo.stringValue.trimmingCharacters(in: .whitespaces)
        // Only path-hostile input is rejected — "Greg (AE)", "Jean-Luc"
        // and "J.R." are all legitimate names.
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return }
        runAssign(label: label, name: name)
    }

    private func runAssign(label: String, name: String) {
        guard let launcher = launcherPath() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["profile", "assign", label, name]
        // Rewrite THIS page's transcript (plain files supported).
        var env = ProcessInfo.processInfo.environment
        env["MEETINK_TRANSCRIPT"] = fixedPath ?? liveSymlinkPath()
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        DispatchQueue.global().async { [weak self] in
            do { try proc.run() } catch { return }
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            // Always re-render on completion: the label rewrite preserves
            // the inode AND often the size (same-length name), so the
            // change detector can't see it ('sometimes the name updates,
            // sometimes not until I reopen the meeting').
            DispatchQueue.main.async { self?.refreshIfChanged(force: true) }
            if proc.terminationStatus != 0 || out.lowercased().contains("error") {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't assign \(label)"
                    let plain = out.replacingOccurrences(
                        of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
                    alert.informativeText = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                    alert.runModal()
                }
            }
        }
    }

    // MARK: Watch + render

    func refreshIfChanged(force: Bool = false) {
        let target = fixedPath ?? liveSymlinkPath()
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: target))
            .map { dest -> String in
                dest.hasPrefix("/") ? dest : (target as NSString).deletingLastPathComponent + "/" + dest
            } ?? target

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved) else {
            if force || !snapshot.lines.isEmpty || !lastResolvedPath.isEmpty {
                snapshot = TranscriptSnapshot()
                rawText = ""
                lastResolvedPath = ""
                lastInode = 0; lastSize = 0
                render(empty: true)
            }
            return
        }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        // mtime too: in-place label rewrites keep the inode by design and
        // can keep the size (same-length name) — mtime always moves.
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        if force || inode != lastInode || size != lastSize
            || mtime != lastMtime || resolved != lastResolvedPath {
            lastInode = inode; lastSize = size; lastMtime = mtime
            lastResolvedPath = resolved
            if let text = try? String(contentsOfFile: resolved, encoding: .utf8) {
                rawText = text
                snapshot = parseTranscript(text)
                render(empty: false)
            }
        } else {
            updateHeader()
        }
    }

    // MARK: Playback

    /// Audio exists next to archived transcripts when "keep audio" was on.
    /// Never for the in-flight live recording.
    private func updatePlayerAvailability() {
        let base = (lastResolvedPath as NSString).deletingPathExtension
        // Recordings archive .m4a; imports keep the SOURCE's extension —
        // probe everything AVAudioPlayer handles ('no audio' on an import
        // whose .mp3 sat right there was this list being one item long).
        var candidate = base + ".m4a"
        for ext in ["m4a", "mp3", "wav", "aiff", "aac", "caf", "mp4"] {
            let p = base + "." + ext
            if FileManager.default.fileExists(atPath: p) { candidate = p; break }
        }
        let liveRecording = fixedPath == nil && recordingPID() != nil
        let available = !liveRecording && !lastResolvedPath.isEmpty
            && FileManager.default.fileExists(atPath: candidate)
        if available && audioPath != candidate {
            audioPath = candidate
            player?.stop()
            player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: candidate))
            player?.prepareToPlay()
            buildLineOffsets(base: base)
            if let pending = pendingSampleSpeaker {
                pendingSampleSpeaker = nil
                DispatchQueue.main.async { [weak self] in self?.playNextSegment(of: pending) }
            }
            refreshIfChanged(force: true)   // re-render so links become play-links
        } else if !available && audioPath != nil {
            audioPath = nil
            stopPlayback()
        }
        // Archived transcripts always show the bar (consistent UX); it just
        // says so when no audio was kept. Live views hide it entirely.
        let archived = !liveRecording && !lastResolvedPath.isEmpty && !snapshot.lines.isEmpty
        playerBar.isHidden = !archived
        playerBarHeight?.constant = archived ? 34 : 0
        playerBar.edgeInsets = archived
            ? NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12) : NSEdgeInsets()
        for v in playerBar.arrangedSubviews { v.isHidden = (audioPath == nil) }
        noAudioLabel.isHidden = !(archived && audioPath == nil)
        reprocessButton.isHidden = !(archived && audioPath != nil)
        titleField.isHidden = !archived
        if archived, view.window?.firstResponder != titleField.currentEditor() {
            titleField.stringValue = meetingDisplayName(lastResolvedPath)
        }
        updatePlayerUI()
    }

    /// Per-line seconds into the audio. Primary source: the refine pass's
    /// timing sidecar (exact spool-timeline offsets). Fallback: wall-clock
    /// line stamps minus the Started header.
    private func buildLineOffsets(base: String) {
        lineOffsets = []
        if let data = FileManager.default.contents(atPath: base + ".timing.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["lines"] as? [[String: Any]],
           arr.count == snapshot.lines.count {
            lineOffsets = arr.map { ($0["t"] as? Double) ?? 0 }
            return
        }
        func daySeconds(_ hms: String) -> Double? {
            let p = hms.split(separator: ":").compactMap { Double($0) }
            return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : nil
        }
        var startSec: Double? = nil
        if let started = snapshot.startedAt {
            let c = Calendar.current.dateComponents([.hour, .minute, .second], from: started)
            startSec = Double(c.hour! * 3600 + c.minute! * 60 + c.second!)
        }
        lineOffsets = snapshot.lines.map { l in
            guard let t = daySeconds(l.timestamp) else { return 0 }
            guard let s0 = startSec else { return t }   // imports: stamps are relative
            var d = t - s0
            if d < -3600 { d += 86400 }                 // crossed midnight
            return max(0, d)
        }
    }

    private func seek(to offset: Double, andPlay: Bool) {
        guard let player else { return }
        player.currentTime = max(0, min(offset, player.duration - 0.1))
        if andPlay && !player.isPlaying {
            player.play()
            startPlayTimer()
        }
        updatePlayerUI()
        highlightCurrentLine(scrollTo: true)
    }

    @objc private func togglePlay() {
        guard let player else { return }
        if player.isPlaying { player.pause(); playTimer?.invalidate() }
        else { player.play(); startPlayTimer() }
        updatePlayerUI()
    }
    @objc private func back10() { seek(to: (player?.currentTime ?? 0) - 10, andPlay: false) }
    @objc private func fwd10() { seek(to: (player?.currentTime ?? 0) + 10, andPlay: false) }
    @objc private func scrubbed() {
        guard let player else { return }
        seek(to: scrubber.doubleValue * player.duration, andPlay: false)
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playTimer?.invalidate()
        if currentSpeakingName != nil {
            currentSpeakingName = nil
            speakersTable.reloadData()
        }
        if let r = highlightedRange {
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
            highlightedRange = nil
        }
    }

    private func startPlayTimer() {
        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.updatePlayerUI()
            self.highlightCurrentLine(scrollTo: false)
            if !p.isPlaying { self.playTimer?.invalidate(); self.updatePlayerUI() }
        }
    }

    private func updatePlayerUI() {
        let playing = player?.isPlaying == true
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                   accessibilityDescription: playing ? "Pause" : "Play")
        guard let p = player else { timeLabel.stringValue = ""; return }
        func fmt(_ t: Double) -> String {
            let s = Int(t)
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                             : String(format: "%02d:%02d", s / 60, s % 60)
        }
        timeLabel.stringValue = "\(fmt(p.currentTime)) / \(fmt(p.duration))"
        if !scrubber.isHighlighted, p.duration > 0 {
            scrubber.doubleValue = p.currentTime / p.duration
        }
    }

    /// Highlight the line ("segment") currently being spoken.
    private func highlightCurrentLine(scrollTo: Bool) {
        guard let p = player, !lineOffsets.isEmpty else { return }
        let t = p.currentTime
        // Last line whose offset <= t.
        var idx = -1
        for (i, off) in lineOffsets.enumerated() { if off <= t { idx = i } else { break } }
        guard idx >= 0, let range = lineRanges[idx] else { return }
        if let old = highlightedRange, old == range { return }
        if let old = highlightedRange {
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
        }
        textView.layoutManager?.addTemporaryAttribute(
            .backgroundColor,
            value: NSColor.systemYellow.withAlphaComponent(0.28),
            forCharacterRange: range)
        highlightedRange = range
        if scrollTo { textView.scrollRangeToVisible(range) }
        // Mirror who's talking into the speakers panel (subtle row tint).
        let name = idx < snapshot.lines.count ? snapshot.lines[idx].speaker : nil
        if name != currentSpeakingName {
            currentSpeakingName = name
            speakersTable.reloadData()
        }
    }

    private func updateSpeakersPanel() {
        let fresh = snapshot.talkShare.map { (name: $0.speaker, fraction: $0.fraction) }
        // Reload only on change — a reload mid-click would eat the click.
        if fresh.map(\.name) != speakers.map(\.name)
            || fresh.map({ Int($0.fraction * 100) }) != speakers.map({ Int($0.fraction * 100) }) {
            speakers = fresh
            rebuildPanelRows()
        }
    }

    /// Visible speakers first (shares renormalized WITHOUT the hidden
    /// ones — the Zoom announcer shouldn't own 4% of a meeting), then a
    /// collapsible "Hidden (n)" section.
    private func rebuildPanelRows() {
        let hiddenNames = hiddenSpeakerNames()
        let visible = speakers.filter { !hiddenNames.contains($0.name.uppercased()) }
        let hidden = speakers.filter { hiddenNames.contains($0.name.uppercased()) }
        let vTotal = max(visible.reduce(0) { $0 + $1.fraction }, 0.0001)
        var rows: [PanelRow] = visible.map {
            .speaker(name: $0.name, fraction: $0.fraction / vTotal, hidden: false)
        }
        if !hidden.isEmpty {
            rows.append(.toggle(count: hidden.count))
            if showHiddenSpeakers {
                rows += hidden.map {
                    .speaker(name: $0.name, fraction: $0.fraction, hidden: true)
                }
            }
        }
        panelRows = rows
        speakersTable.reloadData()
    }

    @objc private func speakerRowClicked() {
        let row = speakersTable.clickedRow
        guard row >= 0, row < panelRows.count else { return }
        switch panelRows[row] {
        case .toggle:
            showHiddenSpeakers.toggle()
            rebuildPanelRows()
        case .speaker(let name, _, _):
            // With audio: clicking a name hops to their next segment after
            // the playhead. Renaming is the pencil button. Without audio
            // the click falls back to renaming (nothing to play).
            if audioPath != nil {
                playNextSegment(of: name)
            } else {
                promptForName(label: name)
            }
        }
    }

    @objc private func pencilClicked(_ sender: NSButton) {
        let row = speakersTable.row(for: sender)
        guard row >= 0, row < panelRows.count,
              case .speaker(let name, _, _) = panelRows[row] else { return }
        promptForName(label: name)
    }

    // MARK: Segment editing (recordings only)
    //
    // No freeform document editing — every mutation is structured and
    // per-segment via the right-click menu: Edit… (bounded freeform inside
    // one segment), Split Here (two segments, both keeping the speaker),
    // Delete. The transcript file stays the source of truth: edits rewrite
    // it in place (inode preserved, the watcher re-renders), timing.json
    // is spliced in lockstep, and the first edit snapshots
    // <base>.pre-edit.txt.

    private func snapshotBeforeFirstEdit() {
        let pre = (lastResolvedPath as NSString).deletingPathExtension + ".pre-edit.txt"
        if !FileManager.default.fileExists(atPath: pre) {
            try? FileManager.default.copyItem(atPath: lastResolvedPath, toPath: pre)
        }
    }

    /// The transcript's raw lines plus the indices of its content lines
    /// (the "[HH:MM:SS] SPEAKER: text" ones, in order — the same order
    /// snapshot.lines and timing.json use).
    private func readTranscriptLines() -> (all: [String], contentIdx: [Int])? {
        guard let text = try? String(contentsOfFile: lastResolvedPath, encoding: .utf8)
        else { return nil }
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        var idx: [Int] = []
        for (i, l) in all.enumerated() where l.range(
            of: #"^\[\d{2}:\d{2}:\d{2}\] [^:]+: "#, options: .regularExpression) != nil {
            idx.append(i)
        }
        return (all, idx)
    }

    private func writeTranscriptLines(_ all: [String]) {
        // Non-atomic on purpose: an atomic write swaps the inode and
        // orphans every watcher/tail on the old one.
        try? (all.joined(separator: "\n") + "\n")
            .write(toFile: lastResolvedPath, atomically: false, encoding: .utf8)
        refreshIfChanged(force: true)
    }

    /// Splice timing.json's lines array alongside a transcript edit:
    /// replace entry `line` with `entries` (empty = delete).
    private func spliceTiming(line: Int, with entries: [[String: Any]]) {
        let tPath = (lastResolvedPath as NSString).deletingPathExtension + ".timing.json"
        guard let data = FileManager.default.contents(atPath: tPath),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var lines = obj["lines"] as? [[String: Any]],
              line < lines.count,
              lines.count == snapshot.lines.count else { return }   // misaligned: leave it
        lines.replaceSubrange(line...line, with: entries)
        obj["lines"] = lines
        if let out = try? JSONSerialization.data(withJSONObject: obj) {
            try? out.write(to: URL(fileURLWithPath: tPath))
        }
    }

    private func editSegment(_ line: Int) {
        guard line < snapshot.lines.count else { return }
        let seg = snapshot.lines[line]
        let alert = NSAlert()
        alert.messageText = "Edit segment"
        alert.informativeText = "\(seg.speaker) — \(seg.timestamp). Clear the text to delete the segment."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 84))
        let tv = NSTextView(frame: scroll.bounds)
        tv.string = seg.text
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.isRichText = false
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = tv
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newText = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        applySegmentText(line, newText)
    }

    private func applySegmentText(_ line: Int, _ newText: String) {
        guard var (all, idx) = readTranscriptLines(), line < idx.count else { return }
        snapshotBeforeFirstEdit()
        let seg = snapshot.lines[line]
        if newText.isEmpty {
            all.remove(at: idx[line])
            spliceTiming(line: line, with: [])
        } else {
            all[idx[line]] = "[\(seg.timestamp)] \(seg.speaker): \(newText)"
            // The line's word timings no longer match its text — keep the
            // start offset, drop the words (highlight degrades to
            // segment-level for this line only).
            var entry: [String: Any] = ["label": seg.speaker, "words": []]
            entry["t"] = line < lineOffsets.count ? lineOffsets[line] : 0
            spliceTiming(line: line, with: [entry])
        }
        writeTranscriptLines(all)
    }

    private func deleteSegment(_ line: Int) {
        applySegmentText(line, "")
    }

    private func splitSegment(_ line: Int, atChar offset: Int) {
        guard var (all, idx) = readTranscriptLines(), line < idx.count,
              line < snapshot.lines.count else { return }
        let seg = snapshot.lines[line]
        let text = seg.text as NSString
        guard offset > 0, offset < text.length else { return }
        // Snap the cut to the nearest word boundary.
        var cut = offset
        while cut < text.length,
              !CharacterSet.whitespaces.contains(
                Unicode.Scalar(text.character(at: cut)) ?? " ") { cut += 1 }
        let first = text.substring(to: cut).trimmingCharacters(in: .whitespaces)
        let second = text.substring(from: cut).trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, !second.isEmpty else { return }
        snapshotBeforeFirstEdit()

        // Second half's timestamp: the timing entry's word whose text
        // consumes `first`, else the first half's stamp.
        var t2 = line < lineOffsets.count ? lineOffsets[line] : 0
        var words1: [[String: Any]] = []
        var words2: [[String: Any]] = []
        let tPath = (lastResolvedPath as NSString).deletingPathExtension + ".timing.json"
        if let data = FileManager.default.contents(atPath: tPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tl = obj["lines"] as? [[String: Any]], line < tl.count,
           let words = tl[line]["words"] as? [[String: Any]] {
            var consumed = 0
            for w in words {
                let wlen = ((w["w"] as? String) ?? "").count + 1
                if consumed < first.count {
                    words1.append(w)
                } else {
                    if words2.isEmpty, let s0 = w["s"] as? Double { t2 = s0 }
                    words2.append(w)
                }
                consumed += wlen
            }
        }
        var stamp2 = seg.timestamp
        if let started = snapshot.startedAt, t2 > 0 {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            stamp2 = df.string(from: started.addingTimeInterval(t2))
        }

        all[idx[line]] = "[\(seg.timestamp)] \(seg.speaker): \(first)"
        all.insert("[\(stamp2)] \(seg.speaker): \(second)", at: idx[line] + 1)
        let t1 = line < lineOffsets.count ? lineOffsets[line] : 0
        spliceTiming(line: line, with: [
            ["t": t1, "label": seg.speaker, "words": words1],
            ["t": t2, "label": seg.speaker, "words": words2],
        ])
        writeTranscriptLines(all)
    }

    /// Speaker whose sample should start playing once the player is ready
    /// (set by the Profiles page's listen-through before audio loads).
    private var pendingSampleSpeaker: String? = nil

    /// The transcript whose audio is audibly playing right now — the
    /// meetings page marks its row green so leaving the page doesn't lose
    /// track of what's making sound.
    var playingTranscriptPath: String? {
        guard player?.isPlaying == true, let audioPath else { return nil }
        return (audioPath as NSString).deletingPathExtension + ".txt"
    }

    func playSpeakerSample(_ speaker: String) {
        pendingSampleSpeaker = speaker
        if audioPath != nil {
            playNextSegment(of: speaker)
            pendingSampleSpeaker = nil
        }
    }

    /// Jump to this speaker's next segment after the current playhead
    /// (wrapping to their first segment past the end).
    private func playNextSegment(of speaker: String) {
        guard player != nil, !lineOffsets.isEmpty else { return }
        let t = player?.currentTime ?? 0
        let idxs = snapshot.lines.indices.filter {
            snapshot.lines[$0].speaker == speaker && $0 < lineOffsets.count
        }
        guard let first = idxs.first else { return }
        let next = idxs.first { lineOffsets[$0] > t + 0.5 } ?? first
        seek(to: lineOffsets[next], andPlay: true)
    }

    // Speakers panel table.
    func numberOfRows(in tableView: NSTableView) -> Int { panelRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("speaker-cell")
        let cell: NSTableCellView
        let nameField: NSTextField
        let pctField: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView,
           reused.subviews.count >= 3,
           let n = reused.subviews[0] as? NSTextField,
           let p = reused.subviews[1] as? NSTextField {
            cell = reused; nameField = n; pctField = p
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            nameField = NSTextField(labelWithString: "")
            nameField.font = NSFont.boldSystemFont(ofSize: 12)
            nameField.lineBreakMode = .byTruncatingTail
            nameField.translatesAutoresizingMaskIntoConstraints = false
            pctField = NSTextField(labelWithString: "")
            pctField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            pctField.textColor = .secondaryLabelColor
            pctField.alignment = .right
            pctField.translatesAutoresizingMaskIntoConstraints = false
            let pencil = NSButton(title: "", target: self, action: #selector(pencilClicked(_:)))
            pencil.image = NSImage(systemSymbolName: "pencil",
                                   accessibilityDescription: "Rename speaker")
            pencil.isBordered = false
            pencil.contentTintColor = .tertiaryLabelColor
            pencil.toolTip = "Assign / reassign this speaker"
            pencil.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(nameField)
            cell.addSubview(pctField)
            cell.addSubview(pencil)
            NSLayoutConstraint.activate([
                nameField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                nameField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                pctField.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 6),
                pctField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                pctField.widthAnchor.constraint(equalToConstant: 34),
                pencil.leadingAnchor.constraint(equalTo: pctField.trailingAnchor, constant: 2),
                pencil.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                pencil.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                pencil.widthAnchor.constraint(equalToConstant: 18),
            ])
        }
        guard row < panelRows.count else { return cell }
        switch panelRows[row] {
        case .toggle(let count):
            nameField.stringValue = (showHiddenSpeakers ? "▾ Hidden" : "▸ Hidden")
                + " (\(count))"
            nameField.textColor = .tertiaryLabelColor
            nameField.toolTip = "Non-participants (e.g. the Zoom recording "
                + "announcer) — click to show"
            pctField.stringValue = ""
            cell.subviews.last?.isHidden = true   // no pencil on the toggle
        case .speaker(let name, let fraction, let hidden):
            nameField.stringValue = name
            nameField.textColor = hidden ? .tertiaryLabelColor : color(for: name)
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 5
            cell.layer?.backgroundColor = name == currentSpeakingName
                ? color(for: name).withAlphaComponent(0.13).cgColor
                : NSColor.clear.cgColor
            nameField.toolTip = audioPath != nil
                ? "Click to play their next segment" : "Click to name this speaker"
            pctField.stringValue = "\(Int((fraction * 100).rounded()))%"
            cell.subviews.last?.isHidden = false
        }
        return cell
    }

    private func render(empty: Bool) {
        colorMap = speakerColorMap(snapshot)
        // Hidden speakers read as annotations, not participants — dark
        // gray in the transcript body, same treatment the sidebar's
        // hidden section uses.
        for name in colorMap.keys
        where hiddenSpeakerNames().contains(name.uppercased()) {
            colorMap[name] = .tertiaryLabelColor
        }
        speakersTable.reloadData()
        lineRanges.removeAll()
        highlightedRange = nil
        updatePlayerAvailability()
        let wasPinned = pinnedToBottom
        let out = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: round(13 * uiZoom))
        let monoFont = NSFont.monospacedDigitSystemFont(ofSize: round(11 * uiZoom),
                                                        weight: .regular)

        if empty {
            out.append(NSAttributedString(
                string: "No transcript yet.\n\nStart a recording, or open one from Meetings.",
                attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor]))
        } else {
            let headerPara = NSMutableParagraphStyle()
            headerPara.paragraphSpacingBefore = 10
            let bodyPara = NSMutableParagraphStyle()
            bodyPara.paragraphSpacing = 2
            bodyPara.lineSpacing = 1.5

            for block in snapshot.blocks {
                var speakerAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: round(13 * uiZoom)),
                    .foregroundColor: color(for: block.speaker),
                    .paragraphStyle: headerPara,
                ]
                // Renaming lives ONLY in the speakers panel — inline names
                // are play targets (when audio exists) or inert, so the
                // transcript behaves identically with or without audio.
                var stampAttrs: [NSAttributedString.Key: Any] = [
                    .font: monoFont,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: headerPara,
                ]
                // With audio available, the NAME and TIMESTAMP both mean
                // "play from here" — renaming lives in the speakers panel.
                if audioPath != nil, let first = block.parts.first,
                   let purl = URL(string: "meetink-play://\(first.line)") {
                    speakerAttrs[.link] = purl
                    speakerAttrs[.toolTip] = "Play from here"
                    speakerAttrs[.underlineStyle] = 0
                    speakerAttrs[.cursor] = NSCursor.pointingHand
                    stampAttrs[.link] = purl
                    stampAttrs[.toolTip] = "Play from here"
                    stampAttrs[.cursor] = NSCursor.pointingHand
                }
                out.append(NSAttributedString(string: block.speaker, attributes: speakerAttrs))
                out.append(NSAttributedString(
                    string: "  \(block.timestamp)\n", attributes: stampAttrs))
                for (pi, part) in block.parts.enumerated() {
                    let runStart = out.length
                    let sep = pi == block.parts.count - 1 ? "\n" : " "
                    var bodyAttrs: [NSAttributedString.Key: Any] = [
                        .font: bodyFont,
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: bodyPara,
                    ]
                    // Any word plays its segment. linkTextAttributes is
                    // overridden to just the hand cursor, so body text
                    // keeps its normal look.
                    bodyAttrs[.cursor] = NSCursor.iBeam
                    if audioPath != nil,
                       let purl = URL(string: "meetink-play://\(part.line)") {
                        bodyAttrs[.link] = purl
                    }
                    out.append(NSAttributedString(string: part.text + sep,
                                                  attributes: bodyAttrs))
                    lineRanges[part.line] = NSRange(location: runStart,
                                                    length: (part.text as NSString).length)
                }
            }
        }

        // Preserve the reading position; only pinned readers follow the edge.
        let savedOrigin = textView.enclosingScrollView?.contentView.bounds.origin
        textView.textStorage?.setAttributedString(out)
        if wasPinned {
            textView.scrollToEndOfDocument(nil)
        } else if let origin = savedOrigin {
            textView.enclosingScrollView?.documentView?.scroll(origin)
        }
        updateJumpButton()
        updateHeader()
    }

    private func updateHeader() {
        let recording = recordingPID() != nil && fixedPath == nil
        statusDot.textColor = recording ? .systemRed : .tertiaryLabelColor

        var parts: [String] = []
        if !lastResolvedPath.isEmpty {
            parts.append(formatMeetingDate(
                snapshot.startedAt ?? meetingRecordingDate(lastResolvedPath)))
        }
        if let started = snapshot.startedAt {
            let end: Date? = snapshot.endedAt ?? (recording ? Date() : nil)
            if let end {
                let secs = max(0, Int(end.timeIntervalSince(started)))
                parts.append(String(format: "%02d:%02d", secs / 60, secs % 60))
            }
        }
        parts.append("\(snapshot.lines.count) lines")
        if !recording && snapshot.endedAt != nil { parts.append("ended") }
        // Scoped to THIS meeting: another meeting's post-processing must
        // not take over every page (field report: in a new live meeting
        // while an old one processed, the live header said 'processing').
        if let pp = postprocState(), let target = postprocPath(),
           !lastResolvedPath.isEmpty,
           target == lastResolvedPath
           || (target as NSString).deletingLastPathComponent
              == (lastResolvedPath as NSString).deletingLastPathComponent {
            parts.append("post-processing… \(pp)")
            statusDot.textColor = .systemOrange
        }
        if fixedPath == nil && !recording && snapshot.lines.isEmpty {
            parts = ["not recording"]
        }
        headerField.stringValue = parts.joined(separator: "   ")
        // Populate here, not only on render: the page polls while detached
        // from the window, and an already-rendered transcript never
        // re-renders on attach — the title stayed "(untitled)" (field bug).
        // No renaming while a post-process/reprocess is running — the
        // pipeline holds paths open and a mid-run rename races it (it
        // recovers by inode now, but there's no reason to invite it).
        titleField.isEnabled = postprocState() == nil
        if !titleField.isHidden, titleField.currentEditor() == nil,
           !lastResolvedPath.isEmpty {
            let name = meetingDisplayName(lastResolvedPath)
            if titleField.stringValue != name { titleField.stringValue = name }
        }
        // Event dropdown label follows the linked event.
        eventButton.isHidden = lastResolvedPath.isEmpty
        if !lastResolvedPath.isEmpty {
            let linked = (meetingMeta(lastResolvedPath)["event"]
                          as? [String: Any])?["title"] as? String
            let label = (linked?.isEmpty == false) ? linked! : "No Event"
            if eventButton.title != label { eventButton.title = label }
        }
        updateSpeakersPanel()
    }
}

// MARK: - Meetings list page

/// Table with Finder-ish affordances: ⌘⌫ deletes the selection, and a
/// single click on the NAME of the already-selected row begins an inline
/// rename — deferred past the double-click window so double-click still
/// means "open". Any new click cancels the pending rename.
final class MeetingsTable: NSTableView {
    var onDeleteKey: (() -> Void)?
    var onNameClickWhileSelected: ((Int) -> Void)?
    private var pendingRename: DispatchWorkItem?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51,  // delete/backspace
           event.modifierFlags.contains(.command),
           !selectedRowIndexes.isEmpty {
            onDeleteKey?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        pendingRename?.cancel()
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        let wasSingleSelection = r >= 0
            && selectedRowIndexes == IndexSet(integer: r)
        let onName = column(at: p) == 0
        super.mouseDown(with: event)
        guard wasSingleSelection, onName, event.clickCount == 1,
              selectedRowIndexes == IndexSet(integer: r) else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.onNameClickWhileSelected?(r)
        }
        pendingRename = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }
}

final class MeetingsViewController: NSViewController, NSTableViewDataSource,
                                    NSTableViewDelegate, NSMenuDelegate,
                                    NSTextFieldDelegate {
    private let table = MeetingsTable()
    /// Path of the meeting whose name cell is mid-edit; pauses the 2 s
    /// refresh (a reload would replace the cell under the field editor).
    private var inlineEditPath: String?
    private enum MeetingStatus { case live, processing, playing, ended }
    /// Wired by MainWindowController to the reader: the txt path whose
    /// audio is currently playing (nil when paused/stopped).
    var playingProvider: (() -> String?)? = nil
    private var files: [(path: String, name: String, date: Date,
                         status: MeetingStatus, duration: TimeInterval?)] = []
    private var durCache: [String: (mtime: Date, dur: TimeInterval?)] = [:]
    private var sortKey = "date"
    private var sortAscending = false
    private var refreshTimer: Timer?
    var onOpen: ((String) -> Void)?

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Meeting"
        nameCol.width = 420
        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = "Date"
        dateCol.width = 150
        let durCol = NSTableColumn(identifier: .init("duration"))
        durCol.title = "Length"
        durCol.width = 70
        let statusCol = NSTableColumn(identifier: .init("status"))
        statusCol.title = "Status"
        statusCol.width = 130
        table.addTableColumn(nameCol)
        table.addTableColumn(dateCol)
        table.addTableColumn(durCol)
        table.addTableColumn(statusCol)
        // Click a header to sort; date descending is the default.
        for col in table.tableColumns {
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: col.identifier.rawValue,
                ascending: col.identifier.rawValue == "name")
        }
        table.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.onDeleteKey = { [weak self] in
            guard let self else { return }
            self.deleteRows(Array(self.table.selectedRowIndexes))
        }
        table.onNameClickWhileSelected = { [weak self] row in
            self?.beginInlineRename(row: row)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Rename…", action: #selector(renameClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteClicked), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        self.view = scroll
    }

    private func clickedFile() -> (path: String, name: String)? {
        let row = table.clickedRow
        guard row >= 0, row < files.count else { return nil }
        return (files[row].path, files[row].name)
    }

    /// Right-click target rows: the multi-selection when the click landed
    /// inside it, else just the clicked row.
    private func targetRows() -> [Int] {
        let clicked = table.clickedRow
        guard clicked >= 0 else { return Array(table.selectedRowIndexes) }
        return table.selectedRowIndexes.contains(clicked)
            ? Array(table.selectedRowIndexes) : [clicked]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Rename is single-meeting-only.
        menu.items.first { $0.action == #selector(renameClicked) }?
            .isHidden = targetRows().count > 1
    }

    /// Rename a meeting: new display name → slug, stamped prefix kept.
    /// Folder-style sessions rename the folder + every same-basename file
    /// (the invariant titling relies on); flat legacy files rename in place.
    @objc private func renameClicked() {
        guard let f = clickedFile() else { return }
        // Renaming moves the folder out from under an in-flight job — the
        // reader's title field locks during processing, but this path
        // didn't (field case: meeting renamed mid-import, the 20-minute
        // pyannote run nearly wrote into a vanished directory).
        if let pp = postprocPath(),
           (pp as NSString).deletingLastPathComponent
               == (f.path as NSString).deletingLastPathComponent {
            let alert = NSAlert()
            alert.messageText = "This meeting is still processing"
            alert.informativeText = "Rename it when post-processing finishes."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rename meeting"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = f.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = renameMeeting(txtPath: f.path, displayName: field.stringValue)
        refresh()
    }

    @objc private func deleteClicked() {
        deleteRows(targetRows())
    }

    private func deleteRows(_ rowsIn: [Int]) {
        let rows = rowsIn.filter { $0 < files.count }
        guard !rows.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = rows.count == 1
            ? "Delete “\(files[rows[0]].name)”?"
            : "Delete \(rows.count) meetings?"
        alert.informativeText = "Transcripts, summaries and audio move to the Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let fm = FileManager.default
        for row in rows {
            let path = files[row].path
            let dir = (path as NSString).deletingLastPathComponent
            let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if (dir as NSString).lastPathComponent == base {
                try? fm.trashItem(at: URL(fileURLWithPath: dir), resultingItemURL: nil)
            } else {
                for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
                where item.hasPrefix(base + ".") {
                    try? fm.trashItem(at: URL(fileURLWithPath: dir + "/" + item),
                                      resultingItemURL: nil)
                }
            }
            killPostprocIfOrphaned(deletedPath: path)
        }
        refresh()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: inline rename (slow click on the selected row's name)

    private func beginInlineRename(row: Int) {
        guard row >= 0, row < files.count, inlineEditPath == nil else { return }
        let f = files[row]
        // Same rule as the context-menu rename: nothing moves under a
        // running post-process job.
        if let pp = postprocPath(),
           (pp as NSString).deletingLastPathComponent
               == (f.path as NSString).deletingLastPathComponent { return }
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                as? NSTableCellView,
              let tf = cell.textField else { return }
        inlineEditPath = f.path
        tf.isEditable = true
        tf.isSelectable = true
        tf.delegate = self
        tf.stringValue = f.name
        view.window?.makeFirstResponder(tf)
        tf.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField,
              let path = inlineEditPath else { return }
        tf.isEditable = false
        tf.isSelectable = false
        inlineEditPath = nil
        let newName = tf.stringValue.trimmingCharacters(in: .whitespaces)
        if !newName.isEmpty, newName != meetingDisplayName(path) {
            _ = renameMeeting(txtPath: path, displayName: newName)
        }
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        // Esc = cancel: restore the old name so end-editing is a no-op.
        if commandSelector == #selector(NSResponder.cancelOperation(_:)),
           let path = inlineEditPath, let tf = control as? NSTextField {
            tf.stringValue = meetingDisplayName(path)
            view.window?.makeFirstResponder(table)
            return true
        }
        return false
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    func refresh() {
        // A reload would tear the field editor out of a mid-flight
        // inline rename; the 2 s tick resumes when editing ends.
        guard inlineEditPath == nil else { return }
        let dir = transcriptsDir()
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        var out: [(String, String, Date)] = []
        for item in items {
            var path = dir + "/" + item
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let base: String
            if isDir.boolValue {
                // Per-session folder: the transcript inside is named after
                // the folder. Anything else (project dirs, _context, .idx)
                // won't have that file and is skipped.
                guard !item.hasPrefix("."), !item.hasPrefix("_"),
                      !item.hasSuffix(".idx") else { continue }
                let candidate = path + "/" + item + ".txt"
                guard fm.fileExists(atPath: candidate) else { continue }
                path = candidate
                base = item
            } else {
                // Legacy flat transcript. `live.txt` is a symlink and its
                // lstat says "file" only when we follow it — skip by name.
                guard item.hasSuffix(".txt"),
                      item != "live.txt",
                      !item.hasSuffix(".live-raw.txt") else { continue }
                base = String(item.dropLast(4))
            }
            // Recording date (filename stamp), never mtime — reprocess and
            // label edits touch the file constantly.
            let date = meetingRecordingDate(path)
            _ = base
            out.append((path, meetingDisplayName(path), date))
        }
        out.sort { $0.2 > $1.2 }
        // Per-row status: red live, orange while its post-process runs.
        let liveTarget = (try? fm.destinationOfSymbolicLink(atPath: liveSymlinkPath()))
        let recording = recordingPID() != nil
        let processing = postprocPath()
        let playing = playingProvider?()
        let fm2 = FileManager.default
        var stamped: [(String, String, Date, MeetingStatus, TimeInterval?)] = out.map {
            let st: MeetingStatus = (recording && $0.0 == liveTarget) ? .live
                : ($0.0 == processing ? .processing
                   : ($0.0 == playing ? .playing : .ended))
            // Durations are cached by mtime; the live row recomputes so it
            // ticks.
            var dur: TimeInterval? = nil
            let mtime = ((try? fm2.attributesOfItem(atPath: $0.0))?[.modificationDate]
                         as? Date) ?? .distantPast
            if st != .live, let hit = durCache[$0.0], hit.mtime == mtime {
                dur = hit.dur
            } else {
                dur = meetingDuration($0.0, isLive: st == .live)
                if st != .live { durCache[$0.0] = (mtime, dur) }
            }
            return ($0.0, $0.1, $0.2, st, dur)
        }
        stamped.sort { a, b in
            let r: Bool
            switch sortKey {
            case "name":     r = a.1.localizedCaseInsensitiveCompare(b.1) == .orderedAscending
            case "duration": r = (a.4 ?? -1) < (b.4 ?? -1)
            case "status":   r = "\(a.3)" < "\(b.3)"
            default:         r = a.2 < b.2
            }
            return sortAscending ? r : !r
        }
        let changed = stamped.map(\.0) != files.map(\.path)
            || stamped.map(\.3) != files.map(\.status)
            || stamped.map { Int(($0.4 ?? 0) / 60) } != files.map { Int(($0.duration ?? 0) / 60) }
        files = stamped.map { (path: $0.0, name: $0.1, date: $0.2, status: $0.3, duration: $0.4) }
        if changed { table.reloadData() }
    }

    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        sortKey = key
        sortAscending = d.ascending
        refresh()
    }

    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < files.count else { return }
        onOpen?(files[row].path)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "name"
        let cellID = NSUserInterfaceItemIdentifier("cell-\(id)")
        let text: String
        if id == "date" {
            text = formatMeetingDate(files[row].date)
        } else if id == "duration" {
            text = files[row].duration.map(formatDuration) ?? "—"
        } else if id == "status" {
            switch files[row].status {
            case .live:       text = "● live"
            case .processing: text = "● processing"
            case .playing:    text = "● playing"
            case .ended:      text = "● ended"
            }
        } else {
            text = files[row].name
        }
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        if id == "date" || id == "duration" {
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        } else if id == "status" {
            cell.textField?.font = NSFont.systemFont(ofSize: 12)
            let dotColor: NSColor
            switch files[row].status {
            case .live:       dotColor = .systemRed
            case .processing: dotColor = .systemOrange
            case .playing:    dotColor = .systemGreen
            case .ended:      dotColor = .tertiaryLabelColor
            }
            let attr = NSMutableAttributedString(string: text)
            attr.addAttribute(.foregroundColor, value: dotColor,
                              range: NSRange(location: 0, length: 1))
            attr.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                              range: NSRange(location: 1, length: attr.length - 1))
            cell.textField?.attributedStringValue = attr
        }
        return cell
    }
}

// MARK: - Vocab page

final class VocabViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let addField = NSTextField()
    private var entries: [String] = []

    override func loadView() {
        let content = NSView()

        let hint = NSTextField(wrappingLabelWithString:
            "Names and jargon whisper should recognize during live transcription. "
            + "Applied immediately — the vocabulary is read on every chunk.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        let col = NSTableColumn(identifier: .init("entry"))
        col.title = "Entry"
        col.width = 420
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        scroll.documentView = table

        addField.placeholderString = "Add a name or term…"
        addField.translatesAutoresizingMaskIntoConstraints = false
        addField.target = self
        addField.action = #selector(addEntry)

        let addButton = NSButton(title: "Add", target: self, action: #selector(addEntry))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(title: "Remove Selected", target: self,
                                    action: #selector(removeSelected))
        removeButton.bezelStyle = .rounded
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(hint)
        content.addSubview(scroll)
        content.addSubview(addField)
        content.addSubview(addButton)
        content.addSubview(removeButton)
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            addField.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            addField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            addField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            addButton.leadingAnchor.constraint(equalTo: addField.trailingAnchor, constant: 8),
            addButton.centerYAnchor.constraint(equalTo: addField.centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 16),
            removeButton.centerYAnchor.constraint(equalTo: addField.centerYAnchor),
            removeButton.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            addField.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        self.view = content
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        load()
    }

    private func load() {
        let text = (try? String(contentsOfFile: vocabPath(), encoding: .utf8)) ?? ""
        entries = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        table.reloadData()
    }

    private func save() {
        // Same shape the file already uses: comma-separated, one line.
        let dir = (vocabPath() as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (entries.joined(separator: ", ") + "\n")
            .write(toFile: vocabPath(), atomically: true, encoding: .utf8)
    }

    @objc private func addEntry() {
        let value = addField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        if !entries.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            entries.append(value)
            save()
            table.reloadData()
        }
        addField.stringValue = ""
    }

    @objc private func removeSelected() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        entries = entries.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        save()
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("vocab-cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = entries[row]
        return cell
    }
}

// MARK: - Upload page (queue + progress)

final class UploadJob {
    let url: URL
    var status: String = "queued"
    var finalPath: String? = nil
    var done: Bool = false
    var failed: Bool = false
    init(url: URL) { self.url = url }
}

final class UploadViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var jobs: [UploadJob] = []
    private var running = false
    var isBusy: Bool { running }
    /// (name, status) for the Activity page — active/queued jobs only.
    func jobSummaries() -> [(String, String)] {
        jobs.filter { !$0.done && !$0.failed }
            .map { ($0.url.lastPathComponent, $0.status) }
    }
    var onOpenTranscript: ((String) -> Void)?

    private let dropLabel = NSTextField(labelWithString: "Drop audio files here to transcribe")
    private let dropBox = NSBox()

    override func loadView() {
        let content = NSView()

        dropBox.boxType = .custom
        dropBox.cornerRadius = 14
        dropBox.borderWidth = 2
        dropBox.borderColor = NSColor.systemIndigo.withAlphaComponent(0.5)
        dropBox.fillColor = NSColor.systemIndigo.withAlphaComponent(0.06)
        dropBox.translatesAutoresizingMaskIntoConstraints = false

        dropLabel.font = NSFont.boldSystemFont(ofSize: 16)
        dropLabel.textColor = .systemIndigo
        dropLabel.translatesAutoresizingMaskIntoConstraints = false
        let sub = NSTextField(labelWithString:
            "wav · m4a · mp3 · aiff · flac · mp4 · mov — multiple files queue up")
        sub.font = NSFont.systemFont(ofSize: 11)
        sub.textColor = .tertiaryLabelColor
        sub.translatesAutoresizingMaskIntoConstraints = false
        dropBox.contentView?.addSubview(dropLabel)
        dropBox.contentView?.addSubview(sub)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        let fileCol = NSTableColumn(identifier: .init("file"))
        fileCol.title = "File"
        fileCol.width = 260
        let statusCol = NSTableColumn(identifier: .init("status"))
        statusCol.title = "Status"
        statusCol.width = 300
        table.addTableColumn(fileCol)
        table.addTableColumn(statusCol)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        scroll.documentView = table

        content.addSubview(dropBox)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            dropBox.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            dropBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            dropBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            dropBox.heightAnchor.constraint(equalToConstant: 110),
            dropLabel.centerXAnchor.constraint(equalTo: dropBox.centerXAnchor),
            dropLabel.centerYAnchor.constraint(equalTo: dropBox.centerYAnchor, constant: -10),
            sub.centerXAnchor.constraint(equalTo: dropBox.centerXAnchor),
            sub.topAnchor.constraint(equalTo: dropLabel.bottomAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: dropBox.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        self.view = content
    }

    func setDragActive(_ active: Bool) {
        dropBox.borderColor = NSColor.systemIndigo.withAlphaComponent(active ? 1.0 : 0.5)
        dropBox.fillColor = NSColor.systemIndigo.withAlphaComponent(active ? 0.15 : 0.06)
    }

    func enqueue(_ urls: [URL]) {
        for url in urls {
            jobs.append(UploadJob(url: url))
        }
        table.reloadData()
        pump()
    }

    /// One job at a time from the app's side; the launcher's machine-wide
    /// lock still guards against external concurrent refines.
    private func pump() {
        guard !running, let job = jobs.first(where: { !$0.done && !$0.failed && $0.status == "queued" }),
              let launcher = launcherPath() else { return }
        running = true
        job.status = "starting…"
        table.reloadData()

        // Output goes to a LOG FILE, not pipes: a pipe's reader dies with
        // the app, and the next write SIGPIPEs the whole import (field
        // case: 20 minutes of pyannote lost to an app rebuild). The job
        // polls the log; if the app restarts mid-run the import finishes
        // on its own and the meeting appears with its results.
        let logPath = "/tmp/meetink-upload-\(Int(Date().timeIntervalSince1970)).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
            job.failed = true; job.status = "couldn't open log"; running = false
            table.reloadData(); return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["refine", job.url.path]
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        var offset: UInt64 = 0
        let poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak job] _ in
            guard let reader = FileHandle(forReadingAtPath: logPath) else { return }
            defer { try? reader.close() }
            try? reader.seek(toOffset: offset)
            let data = reader.readDataToEndOfFile()
            offset += UInt64(data.count)
            guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
            for raw in chunk.components(separatedBy: "\n") {
                let line = raw.replacingOccurrences(
                    of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                var newStatus: String? = nil
                if line.hasPrefix("refine: progress"),
                   let pct = Int(line.split(separator: " ").last ?? "") {
                    let phase = line.contains(" diarize ") ? "identifying speakers" : "transcribing"
                    newStatus = "\(phase) \(pct)%"
                } else if line.hasPrefix("refine: status ") {
                    newStatus = String(line.dropFirst("refine: status ".count))
                } else if line.hasPrefix("TRANSCRIPT_PATH: ") {
                    job?.finalPath = String(line.dropFirst("TRANSCRIPT_PATH: ".count))
                }
                if let st = newStatus { job?.status = st }
            }
            self?.table.reloadData()
        }
        proc.terminationHandler = { [weak self, weak job] p in
            DispatchQueue.main.async {
                poll.invalidate()
                guard let self else { return }
                if p.terminationStatus == 0, job?.finalPath != nil {
                    job?.done = true
                    job?.status = "complete"
                } else if p.terminationStatus == 0 {
                    job?.done = true
                    job?.status = "complete (see Meetings)"
                } else {
                    job?.failed = true
                    job?.status = "failed — see \(logPath)"
                }
                self.running = false
                self.table.reloadData()
                self.pump()
            }
        }
        do { try proc.run() } catch {
            poll.invalidate()
            job.failed = true
            job.status = "couldn't launch"
            running = false
            table.reloadData()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { jobs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let job = jobs[row]
        let id = tableColumn?.identifier.rawValue ?? "file"
        if id == "file" {
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: job.url.lastPathComponent)
            field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        // Status column: text, or the completion button.
        let cell = NSTableCellView()
        if job.done {
            let button = NSButton(title: "Upload complete — go to transcript",
                                  target: self, action: #selector(goToTranscript(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = row
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            let field = NSTextField(labelWithString: job.status)
            field.textColor = job.failed ? .systemRed : .secondaryLabelColor
            field.font = NSFont.systemFont(ofSize: 11)
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    @objc private func goToTranscript(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < jobs.count,
              let path = jobs[sender.tag].finalPath else { return }
        onOpenTranscript?(path)
    }
}

// MARK: - Profiles page

/// Voice profiles: rename, delete, and see which meetings a person was in.
final class ProfilesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let meetingsTable = NSTableView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private var profiles: [(name: String, samples: Int)] = []
    private var meetings: [(name: String, path: String)] = []   // for the selected profile
    private let hiddenBox = NSButton(
        checkboxWithTitle: "Hidden (not counted as a participant)", target: nil, action: nil)
    /// Wired by MainWindowController: open this transcript and play the
    /// given speaker's first segment — "listen to a sample" to confirm a
    /// profile is who you think it is.
    var onListen: ((String, String) -> Void)?
    private var selectedProfile: String? = nil

    override func loadView() {
        let root = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let nameCol = NSTableColumn(identifier: .init("name")); nameCol.title = "Profile"; nameCol.width = 220
        let sampCol = NSTableColumn(identifier: .init("samples")); sampCol.title = "Voice samples"; sampCol.width = 120
        table.addTableColumn(nameCol); table.addTableColumn(sampCol)
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Rename…", action: #selector(renameProfile), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteProfile), keyEquivalent: ""))
        for i in menu.items { i.target = self }
        table.menu = menu
        scroll.documentView = table

        // Meetings this voice was heard in; double-click one to open it
        // and hear the person speak (confirms the profile is who you
        // think it is — we store embeddings, not audio, so the meetings
        // themselves are the samples).
        let meetScroll = NSScrollView()
        meetScroll.hasVerticalScroller = true
        meetScroll.translatesAutoresizingMaskIntoConstraints = false
        let meetCol = NSTableColumn(identifier: .init("meeting"))
        meetCol.title = "Heard in (double-click to listen)"
        meetCol.width = 420
        meetingsTable.addTableColumn(meetCol)
        meetingsTable.dataSource = self
        meetingsTable.delegate = self
        meetingsTable.target = self
        meetingsTable.doubleAction = #selector(listenToMeeting)
        meetScroll.documentView = meetingsTable
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        hiddenBox.font = NSFont.systemFont(ofSize: 11)
        hiddenBox.target = self
        hiddenBox.action = #selector(hiddenToggled)
        hiddenBox.isHidden = true
        hiddenBox.toolTip = "Hidden speakers collapse in the transcript sidebar "
            + "and don't count toward talk share (e.g. the Zoom announcer)"
        hiddenBox.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll); root.addSubview(meetScroll)
        root.addSubview(hiddenBox); root.addSubview(detail)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.55),
            meetScroll.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            meetScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            meetScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            meetScroll.bottomAnchor.constraint(equalTo: hiddenBox.topAnchor, constant: -8),
            hiddenBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hiddenBox.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -6),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        self.view = root
    }

    override func viewWillAppear() { super.viewWillAppear(); refresh() }

    private func refresh() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8179/profiles")!)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            var out: [(String, Int)] = []
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["profiles"] as? [[String: Any]] {
                out = arr.compactMap { p in
                    guard let n = p["name"] as? String else { return nil }
                    return (n, (p["samples"] as? Int) ?? 0)
                }
            }
            DispatchQueue.main.async {
                self?.profiles = out.map { (name: $0.0, samples: $0.1) }
                self?.table.reloadData()
                self?.detail.stringValue = out.isEmpty
                    ? "No profiles (is the diarize server running?)" : "Select a profile to see recent meetings."
            }
        }.resume()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView == meetingsTable ? meetings.count : profiles.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == meetingsTable {
            let cell = NSTableCellView()
            let f = NSTextField(labelWithString: meetings[row].name)
            f.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(f); cell.textField = f
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                f.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        let id = tableColumn?.identifier.rawValue ?? "name"
        let cell = NSTableCellView()
        let f = NSTextField(labelWithString: id == "name" ? profiles[row].name : "\(profiles[row].samples)")
        f.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(f); cell.textField = f
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            f.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) != meetingsTable else { return }
        let row = table.selectedRow
        guard row >= 0, row < profiles.count else { return }
        let name = profiles[row].name.uppercased()
        selectedProfile = name
        hiddenBox.isHidden = false
        hiddenBox.state = hiddenSpeakerNames().contains(name) ? .on : .off
        DispatchQueue.global().async { [weak self] in
            // Which recent meetings does this voice appear in?
            let dir = transcriptsDir()
            let fm = FileManager.default
            var hits: [(String, String)] = []
            let folders = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted(by: >)
            for item in folders.prefix(60) {
                let tx = dir + "/" + item + "/" + item + ".txt"
                guard fm.fileExists(atPath: tx),
                      let txt = try? String(contentsOfFile: tx, encoding: .utf8) else { continue }
                if txt.contains("] \(name):") { hits.append((item, tx)) }
                if hits.count >= 15 { break }
            }
            DispatchQueue.main.async {
                guard let self, self.selectedProfile == name else { return }
                self.meetings = hits.map { (name: $0.0, path: $0.1) }
                self.meetingsTable.reloadData()
                self.detail.stringValue = hits.isEmpty
                    ? "\(name): not heard in recent meetings."
                    : "Double-click a meeting to open it and play \(name)'s first segment."
            }
        }
    }

    /// Toggle the selected profile's membership in hidden_speakers —
    /// same config key the transcript sidebar reads.
    @objc private func hiddenToggled() {
        guard let name = selectedProfile else { return }
        var names = (configValue("hidden_speakers") ?? "Zoom")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        names.removeAll { $0.uppercased() == name }
        if hiddenBox.state == .on { names.append(name.capitalized) }
        configSetValue("hidden_speakers", names.joined(separator: ","))
    }

    @objc private func listenToMeeting() {
        let row = meetingsTable.clickedRow >= 0 ? meetingsTable.clickedRow : meetingsTable.selectedRow
        guard row >= 0, row < meetings.count, let speaker = selectedProfile else { return }
        onListen?(meetings[row].path, speaker)
    }

    private func clickedName() -> String? {
        let r = table.clickedRow
        return r >= 0 && r < profiles.count ? profiles[r].name : nil
    }

    @objc private func renameProfile() {
        guard let old = clickedName() else { return }
        let alert = NSAlert()
        alert.messageText = "Rename profile “\(old)”"
        alert.informativeText = "Renames the voice profile and merges into an existing one if the name is taken."
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = old
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old else { return }
        // Through the launcher, not the server directly: profile_rename
        // also rewrites the old label across every transcript, which is
        // what keeps the "heard in" list intact after a rename/merge.
        guard let launcher = launcherPath() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["profile", "rename", old, new]
        DispatchQueue.global().async { [weak self] in
            do { try proc.run() } catch { return }
            proc.waitUntilExit()
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func deleteProfile() {
        guard let name = clickedName() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete profile “\(name)”?"
        alert.informativeText = "Their voice will no longer be recognized in future meetings."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8179/profiles/\(enc)")!)
        req.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }.resume()
    }
}

/// Top-anchored coordinates for scroll document views.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A hairline divider with a grabbable hit area — dragging resizes the
/// speakers panel (width persisted across launches).
final class PanelDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)? = nil

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }
}

// MARK: - Activity page

/// Live view of everything the system is doing — recording, post-
/// processing, watch daemon, servers — so 'what is going on right now?'
/// has one answer instead of four log files.
final class ActivityViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let body = NSTextField(wrappingLabelWithString: "")
    private let historyTable = NSTableView()
    private let moreButton = NSButton(title: "Show more", target: nil, action: nil)
    private var history: [String] = []      // newest first
    private var historyShown = 50
    private var timer: Timer? = nil
    /// Wired to the upload queue so in-app jobs show here too.
    var uploadJobsProvider: (() -> [(String, String)])? = nil

    override func loadView() {
        let root = NSView()
        let title = NSTextField(labelWithString: "Activity")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        body.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        body.translatesAutoresizingMaskIntoConstraints = false

        // History: every past event the pipeline logged, newest first.
        let histTitle = NSTextField(labelWithString: "History")
        histTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        histTitle.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let col = NSTableColumn(identifier: .init("event"))
        col.width = 560
        historyTable.addTableColumn(col)
        historyTable.headerView = nil
        historyTable.rowHeight = 20
        historyTable.dataSource = self
        historyTable.delegate = self
        scroll.documentView = historyTable
        moreButton.bezelStyle = .rounded
        moreButton.controlSize = .small
        moreButton.target = self
        moreButton.action = #selector(showMore)
        moreButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(body)
        root.addSubview(histTitle)
        root.addSubview(scroll)
        root.addSubview(moreButton)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            histTitle.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 20),
            histTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.topAnchor.constraint(equalTo: histTitle.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: moreButton.topAnchor, constant: -8),
            moreButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            moreButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        self.view = root
    }

    @objc private func showMore() {
        historyShown += 100
        loadHistory()
    }

    private func loadHistory() {
        let path = "\(mkHome)/activity.log"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            history = []
            historyTable.reloadData()
            return
        }
        let all = text.split(separator: "\n").map(String.init).reversed()
        history = Array(all.prefix(historyShown))
        moreButton.isHidden = all.count <= historyShown
        historyTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { history.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let cell = NSTableCellView()
        let f = NSTextField(labelWithString: history[row])
        f.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        f.textColor = .secondaryLabelColor
        f.lineBreakMode = .byTruncatingTail
        f.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(f)
        cell.textField = f
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            f.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            f.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        loadHistory()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.loadHistory()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
    }

    private func pidAlive(_ pidFile: String) -> Bool {
        guard let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return kill(pid, 0) == 0
    }

    private func refresh() {
        var lines: [String] = []
        if recordingPID() != nil {
            let live = (try? FileManager.default.destinationOfSymbolicLink(
                atPath: liveSymlinkPath())) ?? ""
            let dur = live.isEmpty ? nil : meetingDuration(live, isLive: true)
            lines.append("● Recording — \(meetingDisplayName(live))"
                + (dur.map { "  (\(formatDuration($0)))" } ?? ""))
        } else {
            lines.append("○ Not recording")
        }
        if let pp = postprocState() {
            let target = postprocPath().map(meetingDisplayName) ?? "?"
            lines.append("● Post-processing — \(target)")
            lines.append("    \(pp)")
        } else {
            lines.append("○ No post-processing")
        }
        for (name, status) in uploadJobsProvider?() ?? [] {
            lines.append("● Upload — \(name): \(status)")
        }
        let watchOn = configBool("watch_enabled")
        let mode = (configValue("watch_mode") ?? "auto") == "notify" ? "notify-only" : "automatic"
        let daemonUp = pidAlive("/tmp/meetink-watch.pid")
        lines.append(watchOn
            ? "\(daemonUp ? "●" : "⚠") Watch — \(mode)\(daemonUp ? "" : " (daemon not running)")"
            : "○ Watch — disabled")
        lines.append(pidAlive("/tmp/meetink-whisper.pid")
            ? "● whisper-server — running" : "○ whisper-server — stopped")
        lines.append("\nLogs: /tmp/meetink-watch.log · /tmp/meetink-refine.log · /tmp/meetink-capture.log")
        body.stringValue = lines.joined(separator: "\n")
    }
}

// MARK: - Settings page

/// Checkbox settings, persisted as key=value lines in ~/.meetink/config —
/// the same file the launcher reads (mk_config_bool), so a toggle here
/// changes behavior on the very next recording with no restart of anything.
final class SettingsViewController: NSViewController {
    private let keepSpoolsBox = NSButton(
        checkboxWithTitle: "Keep audio spools", target: nil, action: nil)
    private let watchModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let calendarsStack = NSStackView()
    private var calendarBoxes: [(box: NSButton, id: String)] = []
    private let keepAudioBox = NSButton(
        checkboxWithTitle: "Keep audio recording", target: nil, action: nil)

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "Settings")
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        keepAudioBox.target = self
        keepAudioBox.action = #selector(toggled(_:))
        keepSpoolsBox.target = self
        keepSpoolsBox.action = #selector(toggled(_:))
        watchModePopup.addItems(withTitles: [
            "Disabled", "Notify only (ask before recording)", "Automatic"])
        watchModePopup.target = self
        watchModePopup.action = #selector(watchModeChanged)

        func caption(_ text: String) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text)
            f.font = NSFont.systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            return f
        }

        let audioCaption = caption(
            "After each meeting (or file import), save the audio as a single "
            + "listenable .m4a in the meeting's folder.")
        let spoolsCaption = caption(
            "Keep the raw microphone and system-audio streams as two separate "
            + "wav files — replayable end-to-end with `meetink simulate`.")
        let watchRow = NSStackView(views: [
            NSTextField(labelWithString: "Meeting watch:"), watchModePopup])
        watchRow.orientation = .horizontal
        watchRow.spacing = 8
        let watchCaption = caption(
            "Watches the calendar and running meeting apps whenever Meetink "
            + "is running. Automatic starts recordings by itself; Notify only "
            + "sends a notification with a Start button instead.")
        let calTitle = NSTextField(labelWithString: "Calendars")
        calTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let calCaption = caption(
            "Unchecked calendars are ignored by auto-record and the "
            + "Link Event picker (e.g. calendars you merely subscribe to).")
        calendarsStack.orientation = .vertical
        calendarsStack.alignment = .leading
        calendarsStack.spacing = 4

        let footnote = caption(
            "Applies from the next recording. Stored in ~/.meetink/config "
            + "(keep_audio, keep_spools, watch_enabled, hidden_calendars).")

        let stack = NSStackView(views: [
            title,
            watchRow, watchCaption,
            keepAudioBox, audioCaption,
            keepSpoolsBox, spoolsCaption,
            calTitle, calCaption, calendarsStack,
            footnote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: title)
        stack.setCustomSpacing(2, after: watchRow)
        stack.setCustomSpacing(18, after: watchCaption)
        stack.setCustomSpacing(2, after: keepAudioBox)
        stack.setCustomSpacing(18, after: audioCaption)
        stack.setCustomSpacing(2, after: keepSpoolsBox)
        stack.setCustomSpacing(20, after: spoolsCaption)
        stack.setCustomSpacing(2, after: calTitle)
        stack.setCustomSpacing(8, after: calCaption)
        stack.setCustomSpacing(24, after: calendarsStack)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable: the calendars list grows past the window bottom.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24),
        ])
        self.view = scroll
        _ = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        keepAudioBox.state = configBool("keep_audio") ? .on : .off
        keepSpoolsBox.state = configBool("keep_spools") ? .on : .off
        if !configBool("watch_enabled") {
            watchModePopup.selectItem(at: 0)
        } else {
            watchModePopup.selectItem(at: (configValue("watch_mode") ?? "auto") == "notify" ? 1 : 2)
        }
        loadCalendars()
    }

    /// Populate the Calendars section from the agent (grouped by account).
    private func loadCalendars() {
        let agent = "\(mkHome)/bin/MeetinkAgent.app/Contents/MacOS/meetink-agent"
        guard FileManager.default.isExecutableFile(atPath: agent) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agent)
        proc.arguments = ["calendars"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        DispatchQueue.global().async { [weak self] in
            do { try proc.run() } catch { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let cals = (try? JSONSerialization.jsonObject(with: data)
                        as? [[String: String]]) ?? []
            DispatchQueue.main.async { self?.renderCalendars(cals) }
        }
    }

    private func renderCalendars(_ cals: [[String: String]]) {
        for v in calendarsStack.arrangedSubviews { v.removeFromSuperview() }
        calendarBoxes = []
        let hidden = Set((configValue("hidden_calendars") ?? "")
            .split(separator: ",").map(String.init))
        let grouped = Dictionary(grouping: cals) { $0["account"] ?? "Other" }
        for account in grouped.keys.sorted() {
            let header = NSTextField(labelWithString: account)
            header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            calendarsStack.addArrangedSubview(header)
            for cal in grouped[account]! .sorted(by: { ($0["title"] ?? "") < ($1["title"] ?? "") }) {
                let box = NSButton(checkboxWithTitle: cal["title"] ?? "?",
                                   target: self, action: #selector(calendarToggled))
                box.font = NSFont.systemFont(ofSize: 12)
                box.state = hidden.contains(cal["id"] ?? "") ? .off : .on
                calendarsStack.addArrangedSubview(box)
                calendarBoxes.append((box, cal["id"] ?? ""))
            }
        }
        if cals.isEmpty {
            calendarsStack.addArrangedSubview(NSTextField(
                labelWithString: "No calendars (grant calendar access first)."))
        }
    }

    @objc private func calendarToggled() {
        let hidden = calendarBoxes.filter { $0.box.state == .off }.map(\.id)
        configSetValue("hidden_calendars", hidden.joined(separator: ","))
    }

    @objc private func toggled(_ sender: NSButton) {
        let key = sender == keepAudioBox ? "keep_audio" : "keep_spools"
        configSetValue(key, sender.state == .on ? "true" : "false")
    }

    @objc private func watchModeChanged() {
        switch watchModePopup.indexOfSelectedItem {
        case 0:
            configSetValue("watch_enabled", "false")
        case 1:
            configSetValue("watch_enabled", "true")
            configSetValue("watch_mode", "notify")
        default:
            configSetValue("watch_enabled", "true")
            configSetValue("watch_mode", "auto")
        }
    }
}

// MARK: - Today page

/// The day at a glance: the last 3 and next 8 calendar meetings that
/// have other attendees, each with a Start Recording / Go to Transcript
/// action, and the event covering the current time highlighted.
final class TodayViewController: NSViewController {
    /// Open a transcript in the reader; nil = the live view.
    var onOpen: ((String?) -> Void)?

    private let stack = NSStackView()
    private var events: [[String: Any]] = []
    private var refreshTimer: Timer?
    private var fetching = false
    private var startingEventStart: String?  // start ISO of an in-flight start
    private let iso = ISO8601DateFormatter()
    /// The row the view scrolls to when the page appears: the whole day
    /// renders, but the viewport starts at the 3rd-most-recent past
    /// event so "now" is what you see, with just a little history above.
    private weak var scrollAnchor: NSView?
    private var wantsAnchorScroll = false

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildRows()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchEvents()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        wantsAnchorScroll = true
        applyAnchorScroll()
        fetchEvents()
    }

    /// Agent `events` over the whole local day.
    private func fetchEvents() {
        guard !fetching else { return }
        fetching = true
        let dayStart = Calendar.current.startOfDay(for: Date())
        fetchAgentEvents(from: dayStart,
                         to: dayStart.addingTimeInterval(24 * 3600)) { [weak self] all in
            guard let self else { return }
            self.fetching = false
            // Only meetings with other attendees — solo calendar blocks
            // (focus time, reminders) aren't recordable conversations.
            self.events = all.filter {
                (($0["attendees"] as? [[String: String]]) ?? []).count >= 2
            }
            self.rebuildRows()
        }
    }

    /// Recorded meetings that carry an event record (or a matching title),
    /// so rows can offer "Go to Transcript" instead of a re-record.
    private func recordedIndex() -> [(path: String, title: String, start: String, date: Date)] {
        let dir = transcriptsDir()
        let fm = FileManager.default
        var out: [(String, String, String, Date)] = []
        for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            let folder = dir + "/" + item
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder, isDirectory: &isDir),
                  isDir.boolValue, !item.hasPrefix("."), !item.hasPrefix("_") else { continue }
            let txt = folder + "/" + item + ".txt"
            guard fm.fileExists(atPath: txt) else { continue }
            let meta = meetingMeta(txt)
            let ev = meta["event"] as? [String: Any]
            let title = (ev?["title"] as? String)
                ?? (meta["title"] as? String) ?? ""
            let start = (ev?["start"] as? String) ?? ""
            out.append((txt, title, start, meetingRecordingDate(txt)))
        }
        return out
    }

    private func transcriptFor(_ e: [String: Any],
                               in index: [(path: String, title: String, start: String, date: Date)]) -> String? {
        let title = (e["title"] as? String) ?? ""
        let start = (e["start"] as? String) ?? ""
        // Exact event-record match first (title + start distinguishes
        // recurring meetings) …
        if let hit = index.first(where: { $0.start == start && $0.title == title }) {
            return hit.path
        }
        // … then title + recording-time proximity, for watch-started
        // meetings that only got the '# event:' header and meta title.
        guard let sd = iso.date(from: start) else { return nil }
        let ed = (e["end"] as? String).flatMap { iso.date(from: $0) }
            ?? sd.addingTimeInterval(3600)
        return index.first(where: {
            $0.title.caseInsensitiveCompare(title) == .orderedSame
                && $0.date >= sd.addingTimeInterval(-3600)
                && $0.date <= ed.addingTimeInterval(2 * 3600)
        })?.path
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowActions.removeAll()

        let header = NSTextField(labelWithString: "Today")
        header.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(header)
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d"
        let sub = NSTextField(labelWithString: df.string(from: Date()))
        sub.font = NSFont.systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(14, after: sub)

        let now = Date()
        var past: [[String: Any]] = []
        var upcoming: [[String: Any]] = []
        for e in events {
            let end = (e["end"] as? String).flatMap { iso.date(from: $0) }
                ?? (e["start"] as? String).flatMap { iso.date(from: $0) }
            if let end, end < now { past.append(e) } else { upcoming.append(e) }
        }

        if past.isEmpty && upcoming.isEmpty {
            let empty = NSTextField(labelWithString:
                "No meetings with attendees today.")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }

        let index = recordedIndex()
        let liveTxt: String? = {
            guard recordingPID() != nil,
                  let dest = try? FileManager.default
                    .destinationOfSymbolicLink(atPath: liveSymlinkPath()) else { return nil }
            return dest.hasPrefix("/") ? dest
                : (liveSymlinkPath() as NSString).deletingLastPathComponent + "/" + dest
        }()

        // The scroll anchor is the FIRST current/future event: the past
        // renders above it (scroll up for history), but the page opens
        // on what's happening now and next. No past events → no scroll.
        let anchorEvent = past.isEmpty ? nil : upcoming.first
        scrollAnchor = nil
        for (section, list) in [("Earlier", past), ("Up next", upcoming)] where !list.isEmpty {
            let label = NSTextField(labelWithString: section)
            label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(label)
            for e in list {
                let row = makeRow(e, index: index, liveTxt: liveTxt, now: now)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                           constant: -32).isActive = true
                if let anchorEvent,
                   (e["start"] as? String) == (anchorEvent["start"] as? String),
                   (e["title"] as? String) == (anchorEvent["title"] as? String) {
                    scrollAnchor = row
                }
            }
            stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
        }
        applyAnchorScroll()
    }

    /// Scroll so the anchor row sits at the top of the viewport. Runs
    /// only when armed by viewDidAppear — timer rebuilds must not yank
    /// the scroll position out from under the user.
    private func applyAnchorScroll() {
        guard wantsAnchorScroll, let anchor = scrollAnchor,
              let scroll = view as? NSScrollView,
              let doc = scroll.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        let frame = anchor.convert(anchor.bounds, to: doc)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, frame.minY - 8)))
        scroll.reflectScrolledClipView(scroll.contentView)
        wantsAnchorScroll = false
    }

    private func makeRow(_ e: [String: Any],
                         index: [(path: String, title: String, start: String, date: Date)],
                         liveTxt: String?, now: Date) -> NSView {
        let title = (e["title"] as? String) ?? "(untitled)"
        let start = (e["start"] as? String).flatMap { iso.date(from: $0) }
        let end = (e["end"] as? String).flatMap { iso.date(from: $0) }
        let attendeeCount = ((e["attendees"] as? [[String: String]]) ?? []).count
        let isNow = start.map { s in
            s <= now && now <= (end ?? s.addingTimeInterval(3600))
        } ?? false
        let isPast = (end ?? .distantFuture) < now

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = isNow
            ? NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        // Uniform row height — button-less (past) and badge-bearing (now)
        // rows otherwise fit to different intrinsic sizes.
        let minHeight = box.heightAnchor.constraint(greaterThanOrEqualToConstant: 58)
        minHeight.priority = NSLayoutConstraint.Priority(999)
        minHeight.isActive = true

        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        var when = start.map { tf.string(from: $0) } ?? "?"
        if let end { when += " – " + tf.string(from: end) }
        let timeLabel = NSTextField(labelWithString: when)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = isPast ? .tertiaryLabelColor : .secondaryLabelColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13,
                                            weight: isNow ? .semibold : .regular)
        titleLabel.textColor = isPast ? .secondaryLabelColor : .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let who = NSTextField(labelWithString: "\(attendeeCount) attendees")
        who.font = NSFont.systemFont(ofSize: 11)
        who.textColor = .tertiaryLabelColor

        let left = NSStackView(views: [timeLabel, titleLabel, who])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2

        let h = NSStackView()
        h.orientation = .horizontal
        h.spacing = 8
        h.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        h.translatesAutoresizingMaskIntoConstraints = false
        h.addArrangedSubview(left)
        h.addArrangedSubview(NSView())

        if isNow {
            let badge = NSTextField(labelWithString: "NOW")
            badge.font = NSFont.systemFont(ofSize: 10, weight: .bold)
            badge.textColor = .controlAccentColor
            h.addArrangedSubview(badge)
        }

        let button = NSButton(title: "", target: self, action: #selector(rowAction(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        let recorded = transcriptFor(e, in: index)
        let startISO = (e["start"] as? String) ?? ""
        if let recorded, recorded == liveTxt {
            button.title = "Go to Transcript"
            rowActions[startISO + title] = { [weak self] in self?.onOpen?(nil) }
        } else if let recorded {
            button.title = "Go to Transcript"
            rowActions[startISO + title] = { [weak self] in self?.onOpen?(recorded) }
        } else if isPast {
            button.isHidden = true
        } else if startingEventStart == startISO {
            button.title = "Starting…"
            button.isEnabled = false
        } else if liveTxt != nil {
            // Something else is already recording — one capture at a time.
            button.title = "Start Recording"
            button.isEnabled = false
        } else {
            button.title = "Start Recording"
            rowActions[startISO + title] = { [weak self] in
                self?.startRecording(for: e)
            }
        }
        button.identifier = NSUserInterfaceItemIdentifier(startISO + title)
        h.addArrangedSubview(button)

        box.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: box.topAnchor),
            h.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            h.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    private var rowActions: [String: () -> Void] = [:]

    @objc private func rowAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        rowActions[id]?()
    }

    /// Start + link via the shared helper; the local state just drives
    /// the "Starting…" button.
    private func startRecording(for e: [String: Any]) {
        startingEventStart = (e["start"] as? String) ?? ""
        rebuildRows()
        startRecordingAndLinkEvent(e) { [weak self] in
            self?.startingEventStart = nil
            self?.rebuildRows()
        }
    }
}

// MARK: - Main window (status strip + sidebar + detail)

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let sidebarItems = ["Today", "Meetings", "Upload"]
    private let sidebar = NSTableView()

    private let stripDot = NSTextField(labelWithString: "●")
    private let stripLabel = NSTextField(labelWithString: "")
    private let recordButton = NSButton(title: "Start Recording", target: nil, action: nil)
    private let liveButton = NSButton(title: "Open Live Transcript", target: nil, action: nil)
    /// Wired by AppDelegate to the same start/stop paths the menubar uses.
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?

    private let detailContainer = NSView()
    private var currentDetail: NSViewController?

    let todayVC = TodayViewController()
    let meetingsVC = MeetingsViewController()
    let vocabVC = VocabViewController()
    let uploadVC = UploadViewController()
    let readerVC = TranscriptViewController()
    let settingsVC = SettingsViewController()
    let profilesVC = ProfilesViewController()
    let activityVC = ActivityViewController()
    private let settingsButton = NSButton()
    private let activityButton = NSButton()
    private let profilesButton = NSButton()
    private let vocabButton = NSButton()

    private var pollTimer: Timer?

    convenience init(forRealUse: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Meetink"
        window.center()
        window.setFrameAutosaveName("MeetinkMainWindow")
        // CONTENT minimum, not frame minimum: the layout floor below
        // demands 640x400 of content, and a frame-based minSize includes
        // the ~28pt title bar — dragging to the minimum made the two
        // requirements unsatisfiable and Auto Layout broke a random
        // constraint (field repro: quit, reopen, resize before opening a
        // recording — the squeeze, again).
        window.contentMinSize = NSSize(width: 640, height: 400)
        self.init(window: window)
        buildUI()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStrip()
        }
        updateStrip()
    }

    private func buildUI() {
        guard let window = self.window else { return }
        let container = DropContainerView(frame: window.contentView?.bounds ?? .zero)
        container.onAudioDrop = { [weak self] urls in
            guard let self else { return }
            self.uploadVC.enqueue(urls)
            self.showPage(2)
            self.sidebar.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        }
        container.onDragState = { [weak self] active in
            self?.uploadVC.setDragActive(active)
        }
        window.contentView = container
        guard let content = window.contentView else { return }

        // Status strip.
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.spacing = 8
        strip.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        strip.translatesAutoresizingMaskIntoConstraints = false
        stripDot.font = NSFont.systemFont(ofSize: 12)
        stripLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        recordButton.bezelStyle = .rounded
        recordButton.controlSize = .small
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        liveButton.bezelStyle = .rounded
        liveButton.controlSize = .small
        liveButton.target = self
        liveButton.action = #selector(openLive)
        strip.addArrangedSubview(stripDot)
        strip.addArrangedSubview(stripLabel)
        strip.addArrangedSubview(NSView())
        strip.addArrangedSubview(recordButton)
        strip.addArrangedSubview(liveButton)

        let stripDivider = NSBox()
        stripDivider.boxType = .separator
        stripDivider.translatesAutoresizingMaskIntoConstraints = false

        // Sidebar.
        let sideScroll = NSScrollView()
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        sideScroll.hasVerticalScroller = false
        let col = NSTableColumn(identifier: .init("nav"))
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.rowHeight = 30
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.style = .sourceList
        sideScroll.documentView = sidebar

        // Utility pages, pinned at the bottom of the sidebar (below the
        // nav table — they never scroll away). Top to bottom: Settings,
        // Activity, Profiles, Vocab.
        func styleUtilityButton(_ b: NSButton, _ title: String,
                                _ symbol: String, _ action: Selector) {
            b.title = title
            if let icon = NSImage(systemSymbolName: symbol,
                                  accessibilityDescription: title) {
                b.image = icon
                b.imagePosition = .imageLeading
            }
            b.isBordered = false
            b.alignment = .left
            b.font = NSFont.systemFont(ofSize: 13)
            b.contentTintColor = .secondaryLabelColor
            b.target = self
            b.action = action
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        styleUtilityButton(settingsButton, "Settings", "gearshape",
                           #selector(openSettings))
        styleUtilityButton(activityButton, "Activity", "list.bullet.rectangle",
                           #selector(openActivity))
        styleUtilityButton(profilesButton, "Profiles", "person.2",
                           #selector(openProfiles))
        styleUtilityButton(vocabButton, "Vocab", "character.book.closed",
                           #selector(openVocab))

        let sideDivider = NSBox()
        sideDivider.boxType = .separator
        sideDivider.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(strip)
        content.addSubview(stripDivider)
        content.addSubview(sideScroll)
        content.addSubview(settingsButton)
        content.addSubview(activityButton)
        content.addSubview(profilesButton)
        content.addSubview(vocabButton)
        content.addSubview(sideDivider)
        content.addSubview(detailContainer)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: content.topAnchor),
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 34),
            stripDivider.topAnchor.constraint(equalTo: strip.bottomAnchor),
            stripDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stripDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sideScroll.topAnchor.constraint(equalTo: stripDivider.bottomAnchor),
            sideScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sideScroll.widthAnchor.constraint(equalToConstant: 150),
            sideScroll.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -4),
            settingsButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            settingsButton.widthAnchor.constraint(equalToConstant: 130),
            settingsButton.heightAnchor.constraint(equalToConstant: 26),
            activityButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            activityButton.widthAnchor.constraint(equalToConstant: 130),
            activityButton.heightAnchor.constraint(equalToConstant: 26),
            activityButton.topAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 2),
            profilesButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            profilesButton.widthAnchor.constraint(equalToConstant: 130),
            profilesButton.heightAnchor.constraint(equalToConstant: 26),
            profilesButton.topAnchor.constraint(equalTo: activityButton.bottomAnchor, constant: 2),
            vocabButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            vocabButton.widthAnchor.constraint(equalToConstant: 130),
            vocabButton.heightAnchor.constraint(equalToConstant: 26),
            vocabButton.topAnchor.constraint(equalTo: profilesButton.bottomAnchor, constant: 2),
            vocabButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            sideDivider.topAnchor.constraint(equalTo: stripDivider.bottomAnchor),
            sideDivider.leadingAnchor.constraint(equalTo: sideScroll.trailingAnchor),
            sideDivider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sideDivider.widthAnchor.constraint(equalToConstant: 1),
            detailContainer.topAnchor.constraint(equalTo: stripDivider.bottomAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: sideDivider.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Without a floor here the whole lower region has no minimum,
            // Auto Layout collapses the window to its 36 pt fitting size,
            // and the frame autosave then faithfully preserves the collapse
            // forever (field case: "I only see the status bar").
            detailContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
            // Hard floor on the whole content: Auto Layout resolves
            // conflicts by resizing the WINDOW when it can (minSize does
            // not bind constraint-driven resizes — field case: squeezed to
            // 618 pt twice). With a required floor, a bad constraint now
            // breaks visibly in Console instead of crushing the window.
            {
                let c = content.widthAnchor.constraint(greaterThanOrEqualToConstant: 640)
                c.priority = NSLayoutConstraint.Priority(999)
                return c
            }(),
            {
                let c = content.heightAnchor.constraint(greaterThanOrEqualToConstant: 400)
                c.priority = NSLayoutConstraint.Priority(999)
                return c
            }(),
        ])

        meetingsVC.onOpen = { [weak self] path in
            self?.openTranscript(path)
        }
        uploadVC.onOpenTranscript = { [weak self] path in
            self?.openTranscript(path)
        }
        readerVC.onMeetingDeleted = { [weak self] in
            self?.showPage(1)
            self?.sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            self?.meetingsVC.refresh()
        }
        todayVC.onOpen = { [weak self] path in
            self?.openTranscript(path)
        }
        activityVC.uploadJobsProvider = { [weak self] in
            (self?.uploadVC.jobSummaries() ?? [])
        }
        meetingsVC.playingProvider = { [weak self] in
            self?.readerVC.playingTranscriptPath
        }
        profilesVC.onListen = { [weak self] path, speaker in
            self?.openTranscript(path)
            self?.readerVC.playSpeakerSample(speaker)
        }

        // Today is the launch page — the day at a glance.
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showPage(0)
    }

    private func setDetail(_ vc: NSViewController) {
        if let old = currentDetail {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        currentDetail = vc
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(vc.view)
        NSLayoutConstraint.activate([
            vc.view.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            vc.view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    func showPage(_ index: Int) {
        switch index {
        case 0: setDetail(todayVC)
        case 1: setDetail(meetingsVC)
        case 3: setDetail(settingsVC)
        case 4: setDetail(activityVC)
        case 5: setDetail(profilesVC)
        case 6: setDetail(vocabVC)
        default: setDetail(uploadVC)
        }
    }

    @objc private func openSettings() {
        sidebar.deselectAll(nil)
        showPage(3)
    }

    @objc private func openActivity() {
        sidebar.deselectAll(nil)
        showPage(4)
    }

    @objc private func openProfiles() {
        sidebar.deselectAll(nil)
        showPage(5)
    }

    @objc private func openVocab() {
        sidebar.deselectAll(nil)
        showPage(6)
    }

    func openTranscript(_ path: String?) {
        readerVC.show(path: path)
        setDetail(readerVC)
        sidebar.deselectAll(nil)
        if path == nil {
            sidebar.selectRowIndexes(IndexSet(), byExtendingSelection: false)
        }
    }

    @objc private func openLive() {
        openTranscript(nil)
    }

    @objc private func toggleRecording() {
        // Disable until the next strip poll confirms the state flip — a
        // double-click must not fire start twice (or stop a just-started
        // recording).
        recordButton.isEnabled = false
        if recordingPID() != nil {
            onStopRecording?()
        } else {
            onStartRecording?()
        }
    }

    private func updateStrip() {
        let recording = recordingPID() != nil
        stripDot.textColor = recording ? .systemRed : .tertiaryLabelColor
        stripLabel.stringValue = recording ? "Recording" : "Not recording"
        recordButton.title = recording ? "Stop Recording" : "Start Recording"
        recordButton.isEnabled = true
        liveButton.title = recording ? "Open Live Transcript" : "Open Latest Transcript"
    }

    // Sidebar table.
    func numberOfRows(in tableView: NSTableView) -> Int { sidebarItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("nav-cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let field = NSTextField(labelWithString: "")
            field.font = NSFont.systemFont(ofSize: 13)
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = sidebarItems[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard sidebar.selectedRow >= 0 else { return }
        showPage(sidebar.selectedRow)
    }
}

// MARK: - App delegate (menubar + lifecycle)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var mainWC: MainWindowController?
    private var pollTimer: Timer?
    private var lastRecording = false
    private var reallyQuit = false

    // --- Watch daemon (app-owned auto-record) ---
    // The watcher used to live only inside the REPL process; now the app
    // reconciles it against the watch_enabled config key on every state
    // poll: spawn when enabled, terminate when disabled or on quit. The
    // daemon also carries MEETINK_WATCH_OWNER_PID so it exits by itself
    // if the app dies uncleanly (no orphaned recordings).
    private var watchProcess: Process? = nil
    // Today's events for the menu bar's "Start … Recording" rows —
    // refreshed every 5 min off the poll; never fetched menu-open-time
    // (the agent call takes seconds).
    private var cachedEvents: [[String: Any]] = []
    private var lastEventsFetch = Date.distantPast

    // Long-call guard state (silence detector + duration backstop).
    private var guardRecordingPath: String? = nil
    private var guardLogOffset: UInt64 = 0
    private var lastAudibleAt = Date()
    private var silenceNotifyInFlight = false
    private var backstopHoursFired = 0
    private var backstopInFlight = false

    private func reconcileWatchDaemon() {
        let wants = configBool("watch_enabled")
        let running = watchProcess?.isRunning == true
        if wants && !running {
            guard let launcher = launcherPath() else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: launcher)
            proc.arguments = ["watch-daemon"]
            var env = ProcessInfo.processInfo.environment
            env["MEETINK_WATCH_OWNER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            proc.environment = env
            let logPath = "/tmp/meetink-watch.log"
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile()
                proc.standardOutput = h
                proc.standardError = h
            }
            try? proc.run()
            watchProcess = proc
        } else if !wants && running {
            watchProcess?.terminate()
            watchProcess = nil
        }
    }

    private func stopWatchDaemon() {
        watchProcess?.terminate()
        watchProcess = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if reallyQuit {
            // Quit Completely — but warn when quitting would strand work.
            // In-flight uploads are child processes of THIS app (they die
            // with it), and the stop pipeline's refine gets SIGPIPEd when
            // its output pipe closes. A live recording survives (launcher-
            // owned) but keeps running headless, which surprises people.
            var reasons: [String] = []
            if recordingPID() != nil {
                reasons.append("A recording is in progress — it will KEEP "
                    + "recording in the background. Use Stop Recording first "
                    + "if you want it to end.")
            }
            if mainWC?.uploadVC.isBusy == true {
                reasons.append("A file transcription is running — quitting "
                    + "aborts it.")
            }
            if postprocState() != nil {
                reasons.append("A meeting is still post-processing — "
                    + "quitting may abort the refine pass.")
            }
            if !reasons.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Quit Meetink completely?"
                alert.informativeText = reasons.joined(separator: "\n\n")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit Anyway")
                if alert.runModal() == .alertFirstButtonReturn {
                    reallyQuit = false
                    return .terminateCancel
                }
            }
            return .terminateNow
        }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.attributeDescriptor(forKeyword: AEKeyword(0x7768793F) /* 'why?' */) != nil {
            return .terminateNow   // shutdown / restart / logout
        }
        mainWC?.window?.close()
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    @objc private func quitCompletely() {
        reallyQuit = true
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopWatchDaemon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance, enforced at runtime. The app is reachable via
        // several path identities (~/.meetink/bin, an /Applications
        // symlink, direct binary exec from a terminal) and LaunchServices
        // will happily run them side by side. Two instances share
        // NSUserDefaults, so a stale instance from before a fix keeps
        // rewriting state (field case: a fixed layout bug kept 'coming
        // back' because an old build was still running and squeezing the
        // saved window frame). Newest launch wins; older instances are
        // asked to quit.
        let me = NSRunningApplication.current
        for other in NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.meetink.app")
        where other.processIdentifier != me.processIdentifier {
            // Polite quit first — but OUR OWN applicationShouldTerminate
            // intercepts it (Quit-to-menu-bar), so a stale instance
            // politely REFUSES the takeover and lives on, re-saving its
            // broken state (field case: pre-fix build kept resurrecting a
            // squeezed window frame for days). Escalate to force after a
            // grace second; the old instance's child daemons exit on their
            // own via owner-pid watchdogs.
            other.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !other.isTerminated { other.forceTerminate() }
            }
        }

        buildMainMenu()
        // Dock / ⌘Tab icon from the bundled icns (the new logo); the
        // drawn mark is only the bare-binary fallback.
        if let icnsPath = Bundle.main.path(forResource: "Meetink", ofType: "icns"),
           let icon = NSImage(contentsOfFile: icnsPath) {
            NSApp.applicationIconImage = icon
        } else {
            NSApp.applicationIconImage = mWaveformImage(
                size: 512,
                barColor: NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 1),
                tile: NSColor(srgbRed: 0.98, green: 0.98, blue: 1.0, alpha: 1))
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(recording: false)
        rebuildMenu()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollState()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let closing = note.object as? NSWindow,
                      closing == self.mainWC?.window else { return }
                NSApp.setActivationPolicy(.accessory)
            }

        showApp()
    }

    @objc private func zoomIn() { adjustZoom(0.1) }
    @objc private func zoomOut() { adjustZoom(-0.1) }
    @objc private func zoomReset() { adjustZoom(1.0 - uiZoom) }

    private func adjustZoom(_ delta: CGFloat) {
        uiZoom = min(1.8, max(0.7, uiZoom + delta))
        configSetValue("ui_zoom", String(format: "%.1f", uiZoom))
        mainWC?.readerVC.zoomChanged()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "meetink" {
            if url.host == "transcribe" {
                showApp(page: 2)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showApp()
        return true
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Meetink",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit to Menu Bar",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = NSMenuItem(title: "Find…",
                              action: #selector(NSResponder.performTextFinderAction(_:)),
                              keyEquivalent: "f")
        find.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        editMenu.addItem(find)
        let findNext = NSMenuItem(title: "Find Next",
                                  action: #selector(NSResponder.performTextFinderAction(_:)),
                                  keyEquivalent: "g")
        findNext.tag = Int(NSTextFinder.Action.nextMatch.rawValue)
        editMenu.addItem(findNext)
        editItem.submenu = editMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let zi = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        zi.target = self
        viewMenu.addItem(zi)
        // ⌘= is what fingers actually press for "⌘+" on ANSI keyboards —
        // a hidden twin that still answers its key equivalent.
        let ziAlt = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        ziAlt.target = self
        ziAlt.isHidden = true
        ziAlt.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(ziAlt)
        let zo = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        zo.target = self
        viewMenu.addItem(zo)
        let zr = NSMenuItem(title: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0")
        zr.target = self
        viewMenu.addItem(zr)
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    /// Blocking actionable notification via the agent (call on a
    /// background queue). Returns the clicked action, or the default on
    /// timeout / missing agent.
    private func agentNotify(title: String, body: String, actions: [String],
                             defaultAction: String, timeout: Int,
                             linger: Int) -> String {
        guard let agent = agentPathIfPresent() else { return defaultAction }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: agent)
        proc.arguments = ["notify", "--title", title, "--body", body,
                          "--actions", actions.joined(separator: ","),
                          "--default", defaultAction,
                          "--timeout", String(timeout),
                          "--linger", String(linger)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        do { try proc.run() } catch { return defaultAction }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? defaultAction : out
    }

    /// Long-call guards, evaluated on the 2 s poll while recording:
    ///
    /// 1. SILENCE — capture logs a gate line per chunk; "→ transcribe"
    ///    means a stream had audio. 5 straight minutes without one on
    ///    EITHER stream → "Still want to record?" with Stop/Keep buttons.
    ///    Re-arms after every notification, so each new stretch of
    ///    silence asks again (not once per recording).
    /// 2. DURATION BACKSTOP — at 4 h (and each hour after) ask the same
    ///    question. Never auto-stops; the user decides.
    private func recordingGuards(recording: Bool) {
        guard recording else {
            guardRecordingPath = nil
            return
        }
        let live = liveSymlinkPath()
        guard let target = try? FileManager.default
            .destinationOfSymbolicLink(atPath: live) else { return }
        if target != guardRecordingPath {
            guardRecordingPath = target
            guardLogOffset = 0
            lastAudibleAt = Date()
            backstopHoursFired = 0
        }

        // -- silence, from the capture log's gate lines --
        if let fh = FileHandle(forReadingAtPath: "/tmp/meetink-capture.log") {
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            if size < guardLogOffset { guardLogOffset = 0 }   // fresh session truncated it
            if size > guardLogOffset {
                // Cap the read; at 2 s cadence the appended slice is tiny.
                let start = max(guardLogOffset, size > 262_144 ? size - 262_144 : 0)
                try? fh.seek(toOffset: start)
                let chunk = String(data: fh.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guardLogOffset = size
                if chunk.contains("→ transcribe") { lastAudibleAt = Date() }
            }
        }
        let silent = Date().timeIntervalSince(lastAudibleAt)
        if silent >= 300, !silenceNotifyInFlight {
            silenceNotifyInFlight = true
            lastAudibleAt = Date()   // re-arm: continued silence asks again in 5 min
            let mins = Int(silent / 60)
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                let response = self.agentNotify(
                    title: "Still want to record?",
                    body: "\(mins) minutes of silence on both streams.",
                    actions: ["Stop recording", "Keep recording"],
                    defaultAction: "Keep recording",
                    timeout: 240, linger: 25)
                DispatchQueue.main.async {
                    self.silenceNotifyInFlight = false
                    if response.lowercased().contains("stop") {
                        self.stopRecording()
                    } else {
                        self.lastAudibleAt = Date()
                    }
                }
            }
        }

        // -- duration backstop --
        guard let dur = meetingDuration(target, isLive: true),
              dur >= 4 * 3600, !backstopInFlight else { return }
        let stage = Int((dur - 4 * 3600) / 3600)   // 0 at 4 h, 1 at 5 h…
        guard stage >= backstopHoursFired else { return }
        backstopInFlight = true
        let hours = Int(dur / 3600)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let response = self.agentNotify(
                title: "Recording for \(hours) hours",
                body: "Long recordings are usually forgotten ones — still going?",
                actions: ["Stop recording", "Keep recording"],
                defaultAction: "Keep recording",
                timeout: 240, linger: 25)
            DispatchQueue.main.async {
                self.backstopHoursFired = stage + 1
                self.backstopInFlight = false
                if response.lowercased().contains("stop") {
                    self.stopRecording()
                }
            }
        }
    }

    private func agentPathIfPresent() -> String? {
        let p = "\(mkHome)/bin/MeetinkAgent.app/Contents/MacOS/meetink-agent"
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    private func pollState() {
        reconcileWatchDaemon()
        let recording = recordingPID() != nil
        recordingGuards(recording: recording)
        if recording != lastRecording {
            lastRecording = recording
            updateStatusIcon(recording: recording)
            rebuildMenu()
        }
        if Date().timeIntervalSince(lastEventsFetch) > 300 {
            lastEventsFetch = Date()
            fetchAgentEvents(from: Date().addingTimeInterval(-6 * 3600),
                             to: Date().addingTimeInterval(12 * 3600)) { [weak self] events in
                self?.cachedEvents = events
                self?.rebuildMenu()
            }
        }
    }

    /// Events happening right now (or starting within 15 min) that have
    /// other attendees — the menu bar offers one-click linked starts.
    private func currentAttendeeEvents() -> [[String: Any]] {
        let iso = ISO8601DateFormatter()
        let now = Date()
        return cachedEvents.filter { e in
            guard (((e["attendees"] as? [[String: String]]) ?? []).count >= 2),
                  let start = (e["start"] as? String).flatMap({ iso.date(from: $0) })
            else { return false }
            let end = (e["end"] as? String).flatMap { iso.date(from: $0) }
                ?? start.addingTimeInterval(3600)
            return start.addingTimeInterval(-15 * 60) <= now && now <= end
        }
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            let img = menubarMarkImage(tint: .systemRed)
                ?? mWaveformImage(size: 18, barColor: .systemRed)
            img.isTemplate = false
            button.image = img
        } else {
            let img = menubarMarkImage()
                ?? mWaveformImage(size: 18, barColor: .black)
            img.isTemplate = true
            button.image = img
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let recording = recordingPID() != nil

        let status = NSMenuItem(
            title: recording ? "● Recording" : "Not recording",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: recording ? "Stop Recording" : "Start New Recording",
            action: recording ? #selector(stopRecording) : #selector(startRecording),
            keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = launcherPath() != nil
        menu.addItem(toggle)

        // One-click linked starts for whatever is on the calendar right
        // now (multiple rows when events overlap).
        if !recording {
            for e in currentAttendeeEvents() {
                let title = (e["title"] as? String) ?? "(untitled)"
                let item = NSMenuItem(
                    title: "Start “\(title)” Recording",
                    action: #selector(startEventRecording(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = e
                item.isEnabled = launcherPath() != nil
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let show = NSMenuItem(title: "Open Meetink",
                              action: #selector(showAppAction), keyEquivalent: "t")
        show.target = self
        menu.addItem(show)

        let upload = NSMenuItem(title: "Transcribe Audio",
                                action: #selector(transcribeAudio), keyEquivalent: "u")
        upload.target = self
        menu.addItem(upload)

        let repl = NSMenuItem(title: "Open REPL",
                              action: #selector(openREPL), keyEquivalent: "r")
        repl.target = self
        menu.addItem(repl)

        let folder = NSMenuItem(title: "Open Transcripts Folder",
                                action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Completely",
                              action: #selector(quitCompletely), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func runLauncher(_ subcommand: String) {
        guard let launcher = launcherPath() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = [subcommand]
        var env = ProcessInfo.processInfo.environment
        env["MEETINK_NO_TAIL"] = "1"
        proc.environment = env
        let logPath = "/tmp/meetink-app-launcher.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write("--- meetink \(subcommand) @ \(Date())\n".data(using: .utf8)!)
            proc.standardOutput = h
            proc.standardError = h
        }
        try? proc.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.pollState()
        }
    }

    @objc private func startRecording() {
        runLauncher("start")
        showApp()
        mainWC?.openTranscript(nil)
    }

    @objc private func stopRecording() { runLauncher("stop") }

    @objc private func startEventRecording(_ sender: NSMenuItem) {
        guard let e = sender.representedObject as? [String: Any] else { return }
        startRecordingAndLinkEvent(e) { [weak self] in self?.rebuildMenu() }
    }
    @objc private func showAppAction() { showApp() }

    @objc private func transcribeAudio() { showApp(page: 2) }

    @objc private func openREPL() {
        guard let launcher = launcherPath() else { return }
        let hasITerm = FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
        let script: String
        if hasITerm {
            script = """
            tell application "iTerm2"
                activate
                create window with default profile command "\(launcher)"
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                do script "\(launcher)"
            end tell
            """
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: transcriptsDir()))
    }

    private func showApp(page: Int? = nil) {
        if mainWC == nil {
            mainWC = MainWindowController(forRealUse: true)
            mainWC?.onStartRecording = { [weak self] in self?.startRecording() }
            mainWC?.onStopRecording = { [weak self] in self?.stopRecording() }
        }
        NSApp.setActivationPolicy(.regular)
        mainWC?.showWindow(nil)
        // Recover from any collapsed autosaved frame (see the constraint
        // floor in MainWindowController.buildUI).
        // Sanitize the autosaved frame. A layout bug in a past session can
        // persist its damage through frame autosave (field cases: collapsed
        // to the 36pt status strip; ballooned to ~4000pt tall and squeezed
        // narrow) — and the app then looks broken forever even after the
        // bug is fixed, until the user deletes the saved frame by hand.
        // Any degenerate frame — too small, larger than the screen, or
        // substantially off-screen — resets to the default size instead.
        if let w = mainWC?.window {
            let screen = (w.screen ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let f = w.frame
            let degenerate = f.height < 450 || f.width < 640
                || f.height > screen.height + 100 || f.width > screen.width + 100
                || !f.intersects(screen.insetBy(dx: -40, dy: -40))
            if degenerate {
                w.setFrame(NSRect(x: 0, y: 0, width: 960, height: 680), display: true)
                w.center()
            }
        }
        mainWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let page {
            mainWC?.showPage(page)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
