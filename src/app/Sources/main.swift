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
    return kill(pid, 0) == 0 ? pid : nil
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

// MARK: - The M-waveform mark

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

/// Rename a meeting to a new display name: slugify, keep the timestamp
/// prefix, move the session folder + every same-basename file (or the flat
/// siblings), and retarget live.txt if it pointed at the old path. Returns
/// the transcript's new path, or nil when nothing moved.
func renameMeeting(txtPath: String, displayName: String) -> String? {
    var slug = displayName.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    guard !slug.isEmpty else { return nil }
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

/// Display name for a transcript path: timestamp prefix stripped, slug
/// prettified — same rule everywhere a meeting is shown.
func meetingDisplayName(_ txtPath: String) -> String {
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
    private var headerHeight: NSLayoutConstraint? = nil
    private let speakersTable = NSTableView()
    private enum PanelRow {
        case speaker(name: String, fraction: Double, hidden: Bool)
        case toggle(count: Int)
    }
    private var panelRows: [PanelRow] = []
    private var speakers: [(name: String, fraction: Double)] = []
    private var showHiddenSpeakers = false
    private let statusDot = NSTextField(labelWithString: "●")
    private let copyButton = NSButton(title: "Copy All", target: nil, action: nil)
    private let folderButton = NSButton(title: "Open Folder", target: nil, action: nil)
    private let reprocessButton = NSButton(title: "Reprocess", target: nil, action: nil)
    private let jumpButton = NSButton(title: "", target: nil, action: nil)

    private var pollTimer: Timer?
    private var lastInode: UInt64 = 0
    private var lastSize: UInt64 = 0
    private var lastResolvedPath: String = ""
    private var rawText: String = ""
    private var snapshot = TranscriptSnapshot()
    private var colorMap: [String: NSColor] = [:]

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
        reprocessButton.bezelStyle = .rounded
        reprocessButton.controlSize = .small
        reprocessButton.font = NSFont.systemFont(ofSize: 11)
        reprocessButton.target = self
        reprocessButton.action = #selector(reprocess)
        reprocessButton.toolTip = "Re-run transcription, diarization and audio "
            + "enhancement on this meeting's kept audio"
        reprocessButton.isHidden = true
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = NSFont.systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyAll)

        strip.addArrangedSubview(statusDot)
        strip.addArrangedSubview(headerField)
        strip.addArrangedSubview(NSView())
        strip.addArrangedSubview(reprocessButton)
        strip.addArrangedSubview(folderButton)
        strip.addArrangedSubview(copyButton)

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

        let panelDivider = NSBox()
        panelDivider.boxType = .separator
        panelDivider.translatesAutoresizingMaskIntoConstraints = false

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

        content.addSubview(header)
        content.addSubview(divider)
        content.addSubview(playerBar)
        content.addSubview(speakersScroll)
        content.addSubview(panelDivider)
        content.addSubview(scroll)
        content.addSubview(jumpButton)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            {
                let h = header.heightAnchor.constraint(equalToConstant: 32)
                self.headerHeight = h
                return h
            }(),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panelDivider.leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: playerBar.topAnchor),
            panelDivider.topAnchor.constraint(equalTo: divider.bottomAnchor),
            panelDivider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            panelDivider.widthAnchor.constraint(equalToConstant: 1),
            speakersScroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            speakersScroll.leadingAnchor.constraint(equalTo: panelDivider.trailingAnchor),
            speakersScroll.widthAnchor.constraint(equalToConstant: 170),
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
        fixedPath = path
        refreshIfChanged(force: true)
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

    /// Enter in the title field renames the meeting on disk (folder +
    /// same-basename siblings, live symlink retargeted) and re-points this
    /// page at the new path.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard control == titleField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let newName = titleField.stringValue
            if let newPath = renameMeeting(txtPath: lastResolvedPath, displayName: newName) {
                if fixedPath != nil { fixedPath = newPath }
                view.window?.makeFirstResponder(textView.superview)
                refreshIfChanged(force: true)
            } else {
                titleField.stringValue = meetingDisplayName(lastResolvedPath)
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            titleField.stringValue = meetingDisplayName(lastResolvedPath)
            view.window?.makeFirstResponder(nil)
            return true
        }
        return false
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

    @objc private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rawText.isEmpty ? textView.string : rawText, forType: .string)
        copyButton.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = "Copy All"
        }
    }

    // MARK: Click-to-name

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
        guard !name.isEmpty, !name.contains("."), !name.contains("/") else { return }
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
        DispatchQueue.global().async {
            do { try proc.run() } catch { return }
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
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

        if force || inode != lastInode || size != lastSize || resolved != lastResolvedPath {
            lastInode = inode; lastSize = size; lastResolvedPath = resolved
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
        let candidate = base + ".m4a"
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
        headerHeight?.constant = archived ? 56 : 32
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
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

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
                    .font: NSFont.boldSystemFont(ofSize: 13),
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
        if !recording, let pp = postprocState() {
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
        updateSpeakersPanel()
    }
}

// MARK: - Meetings list page

final class MeetingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private enum MeetingStatus { case live, processing, playing, ended }
    /// Wired by MainWindowController to the reader: the txt path whose
    /// audio is currently playing (nil when paused/stopped).
    var playingProvider: (() -> String?)? = nil
    private var files: [(path: String, name: String, date: Date, status: MeetingStatus)] = []
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
        let statusCol = NSTableColumn(identifier: .init("status"))
        statusCol.title = "Status"
        statusCol.width = 130
        table.addTableColumn(nameCol)
        table.addTableColumn(dateCol)
        table.addTableColumn(statusCol)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.usesAlternatingRowBackgroundColors = true
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Rename…", action: #selector(renameClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteClicked), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        table.menu = menu
        scroll.documentView = table
        self.view = scroll
    }

    private func clickedFile() -> (path: String, name: String)? {
        let row = table.clickedRow
        guard row >= 0, row < files.count else { return nil }
        return (files[row].path, files[row].name)
    }

    /// Rename a meeting: new display name → slug, stamped prefix kept.
    /// Folder-style sessions rename the folder + every same-basename file
    /// (the invariant titling relies on); flat legacy files rename in place.
    @objc private func renameClicked() {
        guard let f = clickedFile() else { return }
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
        guard let f = clickedFile() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(f.name)”?"
        alert.informativeText = "The meeting (transcript, summary, audio) moves to the Trash."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let dir = (f.path as NSString).deletingLastPathComponent
        let base = ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension
        let fm = FileManager.default
        if (dir as NSString).lastPathComponent == base {
            try? fm.trashItem(at: URL(fileURLWithPath: dir), resultingItemURL: nil)
        } else {
            for item in (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            where item.hasPrefix(base + ".") {
                try? fm.trashItem(at: URL(fileURLWithPath: dir + "/" + item),
                                  resultingItemURL: nil)
            }
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

    override func viewDidAppear() {
        super.viewDidAppear()
        refresh()
    }

    func refresh() {
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
            // Display name: strip the timestamp prefix, prettify the slug.
            var name = base
            if let r = name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}(-\d{2})?_?"#,
                                  options: .regularExpression) {
                name.removeSubrange(r)
            }
            name = name.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "(untitled)" }
            out.append((path, name, date))
        }
        out.sort { $0.2 > $1.2 }
        // Per-row status: red live, orange while its post-process runs.
        let liveTarget = (try? fm.destinationOfSymbolicLink(atPath: liveSymlinkPath()))
        let recording = recordingPID() != nil
        let processing = postprocPath()
        let playing = playingProvider?()
        let stamped: [(String, String, Date, MeetingStatus)] = out.map {
            let st: MeetingStatus = (recording && $0.0 == liveTarget) ? .live
                : ($0.0 == processing ? .processing
                   : ($0.0 == playing ? .playing : .ended))
            return ($0.0, $0.1, $0.2, st)
        }
        let changed = stamped.map(\.0) != files.map(\.path)
            || stamped.map(\.3) != files.map(\.status)
        files = stamped.map { (path: $0.0, name: $0.1, date: $0.2, status: $0.3) }
        if changed { table.reloadData() }
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
        if id == "date" {
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

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["refine", job.url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        var lineBuffer = Data()
        var allOutput = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak job] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lineBuffer.append(data)
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
                guard let raw = String(data: lineData, encoding: .utf8) else { continue }
                let line = raw.replacingOccurrences(
                    of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                allOutput += line + "\n"
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
                if let st = newStatus {
                    DispatchQueue.main.async {
                        job?.status = st
                        self?.table.reloadData()
                    }
                }
            }
        }
        proc.terminationHandler = { [weak self, weak job] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                if p.terminationStatus == 0, job?.finalPath != nil {
                    job?.done = true
                    job?.status = "complete"
                } else {
                    job?.failed = true
                    job?.status = "failed — " + String(allOutput.suffix(120))
                }
                self.running = false
                self.table.reloadData()
                self.pump()
            }
        }
        do { try proc.run() } catch {
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

// MARK: - Settings page

/// Checkbox settings, persisted as key=value lines in ~/.meetink/config —
/// the same file the launcher reads (mk_config_bool), so a toggle here
/// changes behavior on the very next recording with no restart of anything.
final class SettingsViewController: NSViewController {
    private let keepSpoolsBox = NSButton(
        checkboxWithTitle: "Keep audio spools", target: nil, action: nil)
    private let watchBox = NSButton(
        checkboxWithTitle: "Auto-record meetings", target: nil, action: nil)
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
        watchBox.target = self
        watchBox.action = #selector(toggled(_:))

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
        let watchCaption = caption(
            "Watch the calendar and running meeting apps; start recording "
            + "automatically (1-minute warning for scheduled meetings). Runs "
            + "whenever Meetink is running — no REPL needed.")
        let footnote = caption(
            "Applies from the next recording. Stored in ~/.meetink/config "
            + "(keep_audio, keep_spools, watch_enabled).")

        let stack = NSStackView(views: [
            title,
            watchBox, watchCaption,
            keepAudioBox, audioCaption,
            keepSpoolsBox, spoolsCaption,
            footnote,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: title)
        stack.setCustomSpacing(2, after: watchBox)
        stack.setCustomSpacing(18, after: watchCaption)
        stack.setCustomSpacing(2, after: keepAudioBox)
        stack.setCustomSpacing(18, after: audioCaption)
        stack.setCustomSpacing(2, after: keepSpoolsBox)
        stack.setCustomSpacing(28, after: spoolsCaption)
        stack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
        self.view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        keepAudioBox.state = configBool("keep_audio") ? .on : .off
        keepSpoolsBox.state = configBool("keep_spools") ? .on : .off
        watchBox.state = configBool("watch_enabled") ? .on : .off
    }

    @objc private func toggled(_ sender: NSButton) {
        let key = sender == keepAudioBox ? "keep_audio"
            : sender == keepSpoolsBox ? "keep_spools" : "watch_enabled"
        configSetValue(key, sender.state == .on ? "true" : "false")
    }
}

// MARK: - Main window (status strip + sidebar + detail)

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let sidebarItems = ["Meetings", "Vocab", "Upload", "Profiles"]
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

    let meetingsVC = MeetingsViewController()
    let vocabVC = VocabViewController()
    let uploadVC = UploadViewController()
    let readerVC = TranscriptViewController()
    let settingsVC = SettingsViewController()
    let profilesVC = ProfilesViewController()
    private let settingsButton = NSButton()

    private var pollTimer: Timer?

    convenience init(forRealUse: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Meetink"
        window.center()
        window.setFrameAutosaveName("MeetinkMainWindow")
        window.minSize = NSSize(width: 640, height: 400)
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

        // Settings, pinned at the bottom of the sidebar (below the nav
        // table, above nothing — it never scrolls away).
        settingsButton.title = "Settings"
        if let gear = NSImage(systemSymbolName: "gearshape",
                              accessibilityDescription: "Settings") {
            settingsButton.image = gear
            settingsButton.imagePosition = .imageLeading
        }
        settingsButton.isBordered = false
        settingsButton.alignment = .left
        settingsButton.font = NSFont.systemFont(ofSize: 13)
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        let sideDivider = NSBox()
        sideDivider.boxType = .separator
        sideDivider.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(strip)
        content.addSubview(stripDivider)
        content.addSubview(sideScroll)
        content.addSubview(settingsButton)
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
            settingsButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
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
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])

        meetingsVC.onOpen = { [weak self] path in
            self?.openTranscript(path)
        }
        uploadVC.onOpenTranscript = { [weak self] path in
            self?.openTranscript(path)
        }
        meetingsVC.playingProvider = { [weak self] in
            self?.readerVC.playingTranscriptPath
        }
        profilesVC.onListen = { [weak self] path, speaker in
            self?.openTranscript(path)
            self?.readerVC.playSpeakerSample(speaker)
        }

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
        case 0: setDetail(meetingsVC)
        case 1: setDetail(vocabVC)
        case 3: setDetail(profilesVC)
        case 4: setDetail(settingsVC)
        default: setDetail(uploadVC)
        }
    }

    @objc private func openSettings() {
        sidebar.deselectAll(nil)
        showPage(4)
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
        if !recording, let pp = postprocState() {
            stripDot.textColor = .systemOrange
            stripLabel.stringValue = "Post-processing… \(pp)"
        }
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
        NSApp.applicationIconImage = mWaveformImage(
            size: 512,
            barColor: NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 1),
            tile: NSColor(srgbRed: 0.98, green: 0.98, blue: 1.0, alpha: 1))

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

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    private func pollState() {
        reconcileWatchDaemon()
        let recording = recordingPID() != nil
        if recording != lastRecording {
            lastRecording = recording
            updateStatusIcon(recording: recording)
            rebuildMenu()
        }
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        if recording {
            let img = mWaveformImage(size: 18, barColor: .systemRed)
            img.isTemplate = false
            button.image = img
        } else {
            let img = mWaveformImage(size: 18, barColor: .black)
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
            title: recording ? "Stop Recording" : "Start Recording",
            action: recording ? #selector(stopRecording) : #selector(startRecording),
            keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = launcherPath() != nil
        menu.addItem(toggle)

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
