import AppKit
import Foundation

// meetink-app — the native companion: a menubar status item plus a live
// transcript window. The graduated form of the terminal tail window.
//
// Design constraints this file honors (learned the hard way in the terminal
// implementation — see src/lib/window.sh):
//   - The transcript is rewritten IN PLACE (inode-preserving truncate+write)
//     by /profile assign and the /stop consolidation pass, so the watcher
//     re-reads the whole file when it shrinks or changes inode — it never
//     just tails appended bytes.
//   - Titling on /stop RENAMES the file and retargets the live.txt symlink,
//     so the symlink is re-resolved on every poll.
//   - Scroll, selection, copy and ⌘F must all be native. NSTextView gives us
//     every one of them for free (usesFindBar), which is the whole reason
//     this app exists — a terminal tail can't pin a status header without
//     sacrificing scrollback.
//
// The app only READS (live.txt + the localhost status ports). The one write
// path is Start/Stop, which shells out to the launcher. NOTE: when recording
// is started from here, macOS attributes the mic/screen permissions to THIS
// app (the responsible process), not the terminal — first Start triggers
// fresh permission prompts. That's expected; the ad-hoc codesign in
// build_app gives the bundle a stable TCC identity so it's a one-time grant.

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
/// way the launcher resolves it (project subdir of the transcripts base).
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

// MARK: - Transcript model

struct TranscriptLine {
    let timestamp: String
    let speaker: String
    let text: String
}

struct TranscriptSnapshot {
    var headerLines: [String] = []
    var lines: [TranscriptLine] = []
    var startedAt: Date?
    var endedAt: Date?

    /// Char-count share per speaker — a cheap, surprisingly good proxy for
    /// talk time (labels appear once per merged utterance, so line counts
    /// under-weight long monologues; characters don't).
    var talkShare: [(speaker: String, fraction: Double)] {
        var counts: [String: Int] = [:]
        for l in lines { counts[l.speaker, default: 0] += l.text.count }
        let total = max(1, counts.values.reduce(0, +))
        return counts.map { ($0.key, Double($0.value) / Double(total)) }
            .sorted { $0.1 > $1.1 }
    }
}

let lineRegex = try! NSRegularExpression(pattern: #"^\[(\d{2}:\d{2}:\d{2})\] ([^:]+): (.*)$"#)
let isoParser: ISO8601DateFormatter = ISO8601DateFormatter()

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
        } else if var c = current, !rawLine.isEmpty {
            // Continuation of a wrapped utterance (whisper text can contain
            // embedded newlines) — belongs to the previous speaker line.
            c = TranscriptLine(timestamp: c.timestamp, speaker: c.speaker,
                               text: c.text + "\n" + rawLine)
            current = c
        } else {
            if rawLine.hasPrefix("Started:") {
                snap.startedAt = isoParser.date(
                    from: rawLine.replacingOccurrences(of: "Started: ", with: "")
                        .trimmingCharacters(in: .whitespaces))
            }
            if rawLine.hasPrefix("Ended:") {
                snap.endedAt = isoParser.date(
                    from: rawLine.replacingOccurrences(of: "Ended: ", with: "")
                        .trimmingCharacters(in: .whitespaces))
            }
            if !rawLine.isEmpty { snap.headerLines.append(rawLine) }
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

/// Deterministic across launches (String.hashValue is seeded per-process,
/// which would reshuffle everyone's colors on every app restart).
func speakerColor(_ speaker: String) -> NSColor {
    var h = 0
    for u in speaker.unicodeScalars { h = (h &* 31 &+ Int(u.value)) & 0x7fffffff }
    return speakerPalette[h % speakerPalette.count]
}

// MARK: - Transcript window

final class TranscriptWindowController: NSWindowController {
    private let textView = NSTextView()
    private let headerField = NSTextField(labelWithString: "")
    private let statusDot = NSTextField(labelWithString: "●")

    private var pollTimer: Timer?
    private var lastInode: UInt64 = 0
    private var lastSize: UInt64 = 0
    private var lastResolvedPath: String = ""
    private var snapshot = TranscriptSnapshot()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Meetink — Live Transcript"
        window.center()
        window.setFrameAutosaveName("MeetinkTranscriptWindow")
        self.init(window: window)
        buildUI()
        // 0.5s stat-poll: cheap (one lstat + one stat), and simpler + more
        // robust than DispatchSource for a file that gets renamed, truncated
        // and symlink-retargeted underneath us.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshIfChanged()
        }
        refreshIfChanged(force: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // Header bar: recording dot + elapsed + talk-share, pinned above the
        // text view — the thing the terminal tail could never have.
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        statusDot.font = NSFont.systemFont(ofSize: 12)
        headerField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        headerField.lineBreakMode = .byTruncatingTail
        header.addArrangedSubview(statusDot)
        header.addArrangedSubview(headerField)

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
        textView.usesFindBar = true                    // ⌘F, native find bar
        textView.isIncrementalSearchingEnabled = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        content.addSubview(header)
        content.addSubview(divider)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 30),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    /// Pinned-to-bottom detection: only auto-scroll after content changes if
    /// the user was already at (or near) the bottom — scrolling up to read
    /// history must never be yanked away.
    private var pinnedToBottom: Bool {
        guard let scroll = textView.enclosingScrollView else { return true }
        let visible = scroll.contentView.bounds
        let docHeight = textView.frame.height
        return visible.maxY >= docHeight - 40
    }

    func refreshIfChanged(force: Bool = false) {
        let symlink = liveSymlinkPath()
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: symlink))
            .map { dest -> String in
                dest.hasPrefix("/") ? dest : (symlink as NSString).deletingLastPathComponent + "/" + dest
            } ?? symlink

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved) else {
            if force || !snapshot.lines.isEmpty || !lastResolvedPath.isEmpty {
                snapshot = TranscriptSnapshot()
                lastResolvedPath = ""
                lastInode = 0; lastSize = 0
                render(empty: true)
            }
            return
        }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0

        // Any change — growth, in-place rewrite (same inode, size shrinks or
        // matches), rename (inode flip), retarget (path flip) — triggers a
        // full re-read. Transcripts are small; correctness beats cleverness.
        if force || inode != lastInode || size != lastSize || resolved != lastResolvedPath {
            lastInode = inode; lastSize = size; lastResolvedPath = resolved
            if let text = try? String(contentsOfFile: resolved, encoding: .utf8) {
                snapshot = parseTranscript(text)
                render(empty: false)
            }
        } else {
            updateHeader()   // elapsed ticks even when the file is quiet
        }
    }

    private func render(empty: Bool) {
        let wasPinned = pinnedToBottom
        let out = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let monoFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        if empty {
            out.append(NSAttributedString(
                string: "No transcript yet.\n\nStart a recording from the menu bar icon, or run `meetink start`.",
                attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor]))
        } else {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacing = 6
            for line in snapshot.lines {
                out.append(NSAttributedString(
                    string: line.timestamp + "  ",
                    attributes: [.font: monoFont,
                                 .foregroundColor: NSColor.tertiaryLabelColor,
                                 .paragraphStyle: para]))
                out.append(NSAttributedString(
                    string: line.speaker + "  ",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
                                 .foregroundColor: speakerColor(line.speaker),
                                 .paragraphStyle: para]))
                out.append(NSAttributedString(
                    string: line.text + "\n",
                    attributes: [.font: bodyFont,
                                 .foregroundColor: NSColor.labelColor,
                                 .paragraphStyle: para]))
            }
        }

        textView.textStorage?.setAttributedString(out)
        if wasPinned {
            textView.scrollToEndOfDocument(nil)
        }
        updateHeader()
    }

    private func updateHeader() {
        let recording = recordingPID() != nil
        statusDot.textColor = recording ? .systemRed : .tertiaryLabelColor

        var parts: [String] = []
        if let started = snapshot.startedAt {
            let end = snapshot.endedAt ?? (recording ? Date() : snapshot.endedAt ?? Date())
            let secs = Int(end.timeIntervalSince(started))
            if secs >= 0 {
                parts.append(String(format: "%02d:%02d", secs / 60, secs % 60))
            }
        }
        parts.append("\(snapshot.lines.count) lines")
        if !recording && snapshot.endedAt != nil { parts.append("ended") }
        if !recording && snapshot.startedAt == nil && snapshot.lines.isEmpty {
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

// MARK: - Menubar

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var transcriptWC: TranscriptWindowController?
    private var pollTimer: Timer?
    private var lastRecording = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon(recording: false)
        rebuildMenu()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollState()
        }
        showTranscript()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showTranscript()
        return true
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
            let img = NSImage(systemSymbolName: "record.circle.fill",
                              accessibilityDescription: "Recording")?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            img?.isTemplate = false
            button.image = img
        } else {
            let img = NSImage(systemSymbolName: "waveform.circle",
                              accessibilityDescription: "Meetink")
            img?.isTemplate = true
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

        let start = NSMenuItem(title: "Start Recording",
                               action: #selector(startRecording), keyEquivalent: "")
        start.target = self
        start.isEnabled = !recording && launcherPath() != nil
        menu.addItem(start)

        let stop = NSMenuItem(title: "Stop Recording",
                              action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = recording
        menu.addItem(stop)

        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show Transcript",
                              action: #selector(showTranscriptAction), keyEquivalent: "t")
        show.target = self
        menu.addItem(show)

        let folder = NSMenuItem(title: "Open Transcripts Folder",
                                action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Meetink",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func runLauncher(_ subcommand: String) {
        guard let launcher = launcherPath() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = [subcommand]
        // The app IS the tail window — suppress the terminal one the
        // launcher would otherwise open (window.sh also auto-detects the
        // app, this is belt-and-suspenders for older launcher revisions).
        var env = ProcessInfo.processInfo.environment
        env["MEETINK_NO_TAIL"] = "1"
        proc.environment = env
        try? proc.run()
        // Recording state flips within a couple of seconds; poll early so
        // the icon doesn't lag the click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.pollState()
        }
    }

    @objc private func startRecording() { runLauncher("start"); showTranscript() }
    @objc private func stopRecording() { runLauncher("stop") }
    @objc private func showTranscriptAction() { showTranscript() }

    @objc private func openFolder() {
        let base = (liveSymlinkPath() as NSString).deletingLastPathComponent
        NSWorkspace.shared.open(URL(fileURLWithPath: base))
    }

    private func showTranscript() {
        if transcriptWC == nil {
            transcriptWC = TranscriptWindowController()
        }
        transcriptWC?.showWindow(nil)
        transcriptWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
