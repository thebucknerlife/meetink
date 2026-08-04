import AppKit
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
}

struct TranscriptSnapshot {
    var lines: [TranscriptLine] = []
    var startedAt: Date?
    var endedAt: Date?

    var blocks: [SpeakerBlock] {
        var out: [SpeakerBlock] = []
        for l in lines {
            if var last = out.last, last.speaker == l.speaker {
                last.text += " " + l.text
                out[out.count - 1] = last
            } else {
                out.append(SpeakerBlock(timestamp: l.timestamp,
                                        speaker: l.speaker, text: l.text))
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

final class TranscriptViewController: NSViewController, NSTextViewDelegate {
    private let textView = NSTextView()
    private let headerField = NSTextField(labelWithString: "")
    private let statusDot = NSTextField(labelWithString: "●")
    private let copyButton = NSButton(title: "Copy All", target: nil, action: nil)
    private let jumpButton = NSButton(title: "", target: nil, action: nil)

    private var pollTimer: Timer?
    private var lastInode: UInt64 = 0
    private var lastSize: UInt64 = 0
    private var lastResolvedPath: String = ""
    private var rawText: String = ""
    private var snapshot = TranscriptSnapshot()

    /// nil = follow the live symlink; a path = show that transcript.
    private(set) var fixedPath: String? = nil

    override func loadView() {
        let content = NSView()

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        statusDot.font = NSFont.systemFont(ofSize: 12)
        headerField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        headerField.lineBreakMode = .byTruncatingTail
        headerField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = NSFont.systemFont(ofSize: 11)
        copyButton.target = self
        copyButton.action = #selector(copyAll)

        header.addArrangedSubview(statusDot)
        header.addArrangedSubview(headerField)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(copyButton)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

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
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
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

        content.addSubview(header)
        content.addSubview(divider)
        content.addSubview(scroll)
        content.addSubview(jumpButton)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 32),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            jumpButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                self?.updateJumpButton()
            }

        self.view = content
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshIfChanged()
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
        jumpButton.isHidden = pinnedToBottom
    }

    @objc private func jumpToEnd() {
        textView.scrollToEndOfDocument(nil)
        jumpButton.isHidden = true
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
        guard let url = link as? URL, url.scheme == "meetink-assign",
              let number = url.host else { return false }
        promptForName(speakerNumber: number)
        return true
    }

    private func promptForName(speakerNumber: String) {
        let alert = NSAlert()
        alert.messageText = "Who is Speaker \(speakerNumber)?"
        alert.informativeText = "Names the speaker, rewrites the transcript, and "
            + "enrolls their voice when the session's voice data is still available."
        alert.addButton(withTitle: "Assign")
        alert.addButton(withTitle: "Cancel")
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 220, height: 25))
        combo.addItems(withObjectValues: enrolledProfiles())
        combo.placeholderString = "Name"
        combo.completes = true
        alert.accessoryView = combo
        alert.window.initialFirstResponder = combo
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = combo.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("."), !name.contains("/") else { return }
        runAssign(number: speakerNumber, name: name)
    }

    private func runAssign(number: String, name: String) {
        guard let launcher = launcherPath() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["profile", "assign", number, name]
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
                    alert.messageText = "Couldn't assign Speaker \(number)"
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

    private func render(empty: Bool) {
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
                    .foregroundColor: speakerColor(block.speaker),
                    .paragraphStyle: headerPara,
                ]
                if let num = unknownSpeakerNumber(block.speaker),
                   let url = URL(string: "meetink-assign://\(num)") {
                    speakerAttrs[.link] = url
                    speakerAttrs[.toolTip] = "Click to name this speaker"
                    speakerAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    speakerAttrs[.underlineColor] = speakerColor(block.speaker)
                        .withAlphaComponent(0.35)
                }
                out.append(NSAttributedString(string: block.speaker, attributes: speakerAttrs))
                out.append(NSAttributedString(
                    string: "  \(block.timestamp)\n",
                    attributes: [.font: monoFont,
                                 .foregroundColor: NSColor.tertiaryLabelColor,
                                 .paragraphStyle: headerPara]))
                out.append(NSAttributedString(
                    string: block.text + "\n",
                    attributes: [.font: bodyFont,
                                 .foregroundColor: NSColor.labelColor,
                                 .paragraphStyle: bodyPara]))
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
        if let started = snapshot.startedAt {
            let end: Date? = snapshot.endedAt ?? (recording ? Date() : nil)
            if let end {
                let secs = max(0, Int(end.timeIntervalSince(started)))
                parts.append(String(format: "%02d:%02d", secs / 60, secs % 60))
            }
        }
        parts.append("\(snapshot.lines.count) lines")
        if !recording && snapshot.endedAt != nil { parts.append("ended") }
        if fixedPath == nil && !recording && snapshot.lines.isEmpty {
            parts = ["not recording"]
        }
        let shares = snapshot.talkShare.prefix(5)
            .map { "\($0.speaker) \(Int(($0.fraction * 100).rounded()))%" }
        if !shares.isEmpty {
            parts.append(shares.joined(separator: " · "))
        }
        headerField.stringValue = parts.joined(separator: "   ")
    }
}

// MARK: - Meetings list page

final class MeetingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private var files: [(path: String, name: String, date: Date)] = []
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
        table.addTableColumn(nameCol)
        table.addTableColumn(dateCol)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table
        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
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
            guard item.hasSuffix(".txt"),
                  item != "live.txt",
                  !item.hasSuffix(".live-raw.txt") else { continue }
            let path = dir + "/" + item
            // Skip the symlink target duplicate view: list real files only.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            let date = (attrs[.modificationDate] as? Date) ?? .distantPast
            // Display name: strip the timestamp prefix, prettify the slug.
            var name = String(item.dropLast(4))
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
        let changed = out.map(\.0) != files.map(\.path)
        files = out.map { (path: $0.0, name: $0.1, date: $0.2) }
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
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            text = df.string(from: files[row].date)
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

// MARK: - Main window (status strip + sidebar + detail)

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let sidebarItems = ["Meetings", "Vocab", "Upload"]
    private let sidebar = NSTableView()

    private let stripDot = NSTextField(labelWithString: "●")
    private let stripLabel = NSTextField(labelWithString: "")
    private let liveButton = NSButton(title: "Open Live Transcript", target: nil, action: nil)

    private let detailContainer = NSView()
    private var currentDetail: NSViewController?

    let meetingsVC = MeetingsViewController()
    let vocabVC = VocabViewController()
    let uploadVC = UploadViewController()
    let readerVC = TranscriptViewController()

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
        liveButton.bezelStyle = .rounded
        liveButton.controlSize = .small
        liveButton.target = self
        liveButton.action = #selector(openLive)
        strip.addArrangedSubview(stripDot)
        strip.addArrangedSubview(stripLabel)
        strip.addArrangedSubview(NSView())
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

        let sideDivider = NSBox()
        sideDivider.boxType = .separator
        sideDivider.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(strip)
        content.addSubview(stripDivider)
        content.addSubview(sideScroll)
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
            sideScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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
        ])

        meetingsVC.onOpen = { [weak self] path in
            self?.openTranscript(path)
        }
        uploadVC.onOpenTranscript = { [weak self] path in
            self?.openTranscript(path)
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
        default: setDetail(uploadVC)
        }
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

    private func updateStrip() {
        let recording = recordingPID() != nil
        stripDot.textColor = recording ? .systemRed : .tertiaryLabelColor
        stripLabel.stringValue = recording ? "Recording" : "Not recording"
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if reallyQuit { return .terminateNow }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        }
        NSApp.setActivationPolicy(.regular)
        mainWC?.showWindow(nil)
        // Recover from any collapsed autosaved frame (see the constraint
        // floor in MainWindowController.buildUI).
        if let w = mainWC?.window, w.frame.height < 450 {
            w.setContentSize(NSSize(width: max(w.frame.width, 960), height: 680))
            w.center()
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
