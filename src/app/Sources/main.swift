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
//     every one of them — but ONLY if the app has a real main menu: key
//     equivalents (⌘F/⌘C/⌘A/⌘W) resolve through NSApp.mainMenu, which apps
//     launched via bare NSApplication.run() don't get for free.
//
// Activation policy is dynamic: .regular while the transcript window is
// open (so the app appears in ⌘Tab and the Dock and can't be "lost"),
// .accessory when the window closes (menubar-only, no Dock clutter).
//
// The app only READS (live.txt + the localhost status ports). The write
// paths are Start/Stop and speaker assignment, which shell out to the
// launcher. NOTE: when recording is started from here, macOS attributes the
// mic/screen permissions to THIS app (the responsible process) — first
// Start triggers fresh permission prompts; the ad-hoc codesign in build_app
// keeps the bundle identity (and therefore the grants) stable.

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

/// Enrolled profile names, for the assignment dialog's suggestions.
func enrolledProfiles() -> [String] {
    let dir = "\(mkHome)/profiles"
    let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return items.filter { $0.hasSuffix(".npz") }
        .map { String($0.dropLast(4)) }
        .sorted()
}

// MARK: - The M-waveform mark

/// Draws the meetink mark: a five-bar waveform whose silhouette reads as an
/// "M" — outer bars tall, valleys between, a mid-height center. Used at
/// 18 pt (template) in the menu bar and at 512 pt (tinted tile) as the
/// Dock/⌘Tab icon, so there's no .icns asset to keep in sync.
func mWaveformImage(size: CGFloat, barColor: NSColor, tile: NSColor? = nil) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        if let tile = tile {
            let inset = rect.insetBy(dx: size * 0.04, dy: size * 0.04)
            let bg = NSBezierPath(roundedRect: inset,
                                  xRadius: size * 0.22, yRadius: size * 0.22)
            tile.setFill()
            bg.fill()
        }
        // Heights as fractions of the drawable height: M silhouette.
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
            let bar = NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: barHeight),
                xRadius: barWidth / 2, yRadius: barWidth / 2)
            bar.fill()
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

/// Consecutive lines from the same speaker, rendered as one block —
/// the 3 s chunk cadence produces runs of short lines from one voice, and
/// reading them as a paragraph beats reading them as a transcript of hiccups.
struct SpeakerBlock {
    let timestamp: String   // first line's timestamp
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

    /// Char-count share per speaker — a cheap, surprisingly good proxy for
    /// talk time (characters don't under-weight long monologues the way
    /// line counts do).
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
        } else if var c = current, !rawLine.isEmpty, !rawLine.hasPrefix("---") {
            // Continuation of a wrapped utterance (whisper text can contain
            // embedded newlines) — belongs to the previous speaker line.
            c = TranscriptLine(timestamp: c.timestamp, speaker: c.speaker,
                               text: c.text + " " + rawLine)
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

let unknownSpeakerRegex = try! NSRegularExpression(pattern: #"^Speaker (\d+)$"#)

func unknownSpeakerNumber(_ speaker: String) -> String? {
    let ns = speaker as NSString
    guard let m = unknownSpeakerRegex.firstMatch(
        in: speaker, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return ns.substring(with: m.range(at: 1))
}

// MARK: - Drag-and-drop import

let audioExtensions: Set<String> = [
    "wav", "m4a", "mp3", "aiff", "aif", "caf", "flac", "ogg", "opus",
    "mp4", "mov", "webm", "aac", "mkv",
]

/// Content-view wrapper that accepts audio-file drops anywhere in the
/// window. Decoding happens through ffmpeg in the refine pipeline, so the
/// extension list can be generous.
final class DropContainerView: NSView {
    var onAudioDrop: ((URL) -> Void)?
    var onDragState: ((Bool) -> Void)?   // drives the "drop to transcribe" overlay

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func audioURL(from sender: NSDraggingInfo) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: opts) as? [URL] else { return nil }
        return urls.first { audioExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = audioURL(from: sender) != nil
        onDragState?(ok)
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragState?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragState?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragState?(false)
        guard let url = audioURL(from: sender) else { return false }
        onAudioDrop?(url)
        return true
    }
}

// MARK: - Transcript window

final class TranscriptWindowController: NSWindowController, NSTextViewDelegate {
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

    // Import windows watch ONE specific transcript file; the main window
    // (fixedPath == nil) follows the live.txt symlink.
    private var fixedPath: String? = nil
    // True while an import is transcribing into this window — the poll
    // stays quiet so the progress UI isn't replaced by the empty state.
    var suspendWatching = false
    // Transcription in flight (distinct from suspendWatching: a blank
    // drop-target window pauses watching without importing anything yet).
    private(set) var importing = false
    // Window opened via "Transcribe Audio" — an invitation to drop a file.
    private var isDropTarget = false
    // Routed to AppDelegate.startImport — drops open a NEW window there.
    var importHandler: ((URL) -> Void)?

    private let dropOverlay = NSBox()
    private let progressBox = NSStackView()
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")

    // IMPORTANT: no default value on fixedPath. With one, a bare
    // TranscriptWindowController() resolves to NSWindowController's
    // INHERITED init() (exact match beats defaulted-parameter synthesis)
    // and yields a controller with a nil window — every window created
    // that way is stillborn. Field-debugged; do not "simplify" this back.
    convenience init(fixedPath: String?, autosave: Bool = false) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = fixedPath.map { ($0 as NSString).lastPathComponent }
            ?? "Meetink — Live Transcript"
        window.center()
        // Only the main live window persists its frame — a shared autosave
        // name across windows is first-claim-wins and the rest silently lose.
        if autosave {
            window.setFrameAutosaveName("MeetinkTranscriptWindow")
        }
        self.init(window: window)
        self.fixedPath = fixedPath
        // Wrap the content view so audio files can be dropped anywhere in
        // the window to transcribe them (routes through `meetink refine`).
        let container = DropContainerView(frame: window.contentView?.bounds ?? .zero)
        container.onAudioDrop = { [weak self] url in self?.importHandler?(url) }
        container.onDragState = { [weak self] active in
            self?.dropOverlay.isHidden = !active
        }
        window.contentView = container
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

        // Header bar: recording dot + elapsed + talk-share + copy button,
        // pinned above the text view.
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
        header.addArrangedSubview(NSView())   // spacer
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
        textView.usesFindBar = true                    // ⌘F, native find bar
        textView.isIncrementalSearchingEnabled = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        // Speaker labels carry .link attributes for click-to-name; empty
        // linkTextAttributes stops AppKit repainting them blue-underlined
        // over our per-speaker colors.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = self
        scroll.documentView = textView

        // Floating "jump to live" button — appears only when the user has
        // scrolled away from the bottom, so catching up is one click.
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.bezelStyle = .rounded
        jumpButton.controlSize = .regular
        jumpButton.title = " Jump to live"
        jumpButton.image = NSImage(systemSymbolName: "arrow.down.to.line",
                                   accessibilityDescription: "Jump to live")
        jumpButton.imagePosition = .imageLeading
        jumpButton.target = self
        jumpButton.action = #selector(jumpToLive)
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

        // Drag-over affordance: indigo dashed panel with a prompt, shown by
        // DropContainerView's drag-state callback.
        dropOverlay.boxType = .custom
        dropOverlay.cornerRadius = 14
        dropOverlay.borderWidth = 2
        dropOverlay.borderColor = NSColor.systemIndigo.withAlphaComponent(0.8)
        dropOverlay.fillColor = NSColor.systemIndigo.withAlphaComponent(0.10)
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay.isHidden = true
        let dropLabel = NSTextField(labelWithString: "Drop audio file to transcribe")
        dropLabel.font = NSFont.boldSystemFont(ofSize: 18)
        dropLabel.textColor = .systemIndigo
        dropLabel.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay.contentView?.addSubview(dropLabel)
        content.addSubview(dropOverlay)

        // Import-progress panel: filename + bar + status, centered over the
        // text area while `meetink refine` chews on a dropped file.
        progressBox.orientation = .vertical
        progressBox.alignment = .centerX
        progressBox.spacing = 10
        progressBox.translatesAutoresizingMaskIntoConstraints = false
        progressBox.isHidden = true
        progressLabel.font = NSFont.boldSystemFont(ofSize: 14)
        progressLabel.alignment = .center
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        let progressHint = NSTextField(
            labelWithString: "Parakeet · roughly a minute per hour of audio")
        progressHint.font = NSFont.systemFont(ofSize: 11)
        progressHint.textColor = .secondaryLabelColor
        progressBox.addArrangedSubview(progressLabel)
        progressBox.addArrangedSubview(progressBar)
        progressBox.addArrangedSubview(progressHint)
        content.addSubview(progressBox)

        NSLayoutConstraint.activate([
            dropOverlay.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 14),
            dropOverlay.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            dropOverlay.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            dropOverlay.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            dropLabel.centerXAnchor.constraint(equalTo: dropOverlay.centerXAnchor),
            dropLabel.centerYAnchor.constraint(equalTo: dropOverlay.centerYAnchor),
            progressBox.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            progressBox.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 320),
        ])

        // Track scrolling so the jump button can show/hide live.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                self?.updateJumpButton()
            }
    }

    // MARK: Import progress (driven by AppDelegate.startImport)

    func beginImportProgress(filename: String) {
        importing = true
        suspendWatching = true
        textView.textStorage?.setAttributedString(NSAttributedString())
        progressLabel.stringValue = "Transcribing \(filename)…"
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        progressBox.isHidden = false
        statusDot.textColor = .systemOrange
        headerField.stringValue = "Importing \(filename)"
    }

    func updateImportProgress(_ pct: Int) {
        if progressBar.isIndeterminate {
            progressBar.isIndeterminate = false
            progressBar.stopAnimation(nil)
        }
        progressBar.doubleValue = Double(pct)
    }

    /// nil path = failure (caller alerts; a drop-target window goes back
    /// to inviting a drop, others resume showing what they had).
    func finishImport(path: String?) {
        progressBox.isHidden = true
        importing = false
        if let p = path {
            isDropTarget = false
            suspendWatching = false
            fixedPath = p
            window?.title = (p as NSString).lastPathComponent
            refreshIfChanged(force: true)
        } else if isDropTarget {
            showDropPrompt()
        } else {
            suspendWatching = false
            refreshIfChanged(force: true)
        }
    }

    var isImporting: Bool { importing }
    var isShowingImport: Bool { fixedPath != nil }
    /// "Empty" = safe to fill with a dropped import: nothing transcribing
    /// here and no transcript on display. A window tied to content gets a
    /// sibling window instead (see AppDelegate.startImport).
    var isEmptyViewer: Bool { !importing && snapshot.lines.isEmpty }

    /// Blank drop-target mode — what "Transcribe Audio" opens: a persistent
    /// window inviting a drop, which then shows progress and the result.
    func showDropPrompt() {
        isDropTarget = true
        suspendWatching = true
        window?.title = "Transcribe Audio"
        statusDot.textColor = .systemIndigo
        headerField.stringValue = "waiting for a file"
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacingBefore = 160
        let out = NSMutableAttributedString(
            string: "Drop an audio file here\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 20),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: para])
        let subPara = NSMutableParagraphStyle()
        subPara.alignment = .center
        out.append(NSAttributedString(
            string: "\nwav · m4a · mp3 · aiff · flac · mp4 · mov — anything with an audio track",
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.tertiaryLabelColor,
                         .paragraphStyle: subPara]))
        textView.textStorage?.setAttributedString(out)
    }

    /// Back to following the live symlink — used when the main window was
    /// repurposed by a drop and the user asks for the live transcript.
    func returnToLive() {
        guard !isImporting else { return }
        fixedPath = nil
        window?.title = "Meetink — Live Transcript"
        refreshIfChanged(force: true)
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

    private func updateJumpButton() {
        jumpButton.isHidden = pinnedToBottom
    }

    @objc private func jumpToLive() {
        textView.scrollToEndOfDocument(nil)
        jumpButton.isHidden = true
    }

    @objc private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rawText.isEmpty ? textView.string : rawText, forType: .string)
        // Momentary feedback without a popover's ceremony.
        copyButton.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.title = "Copy All"
        }
    }

    // MARK: Click-to-name (NSTextViewDelegate)

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
            + "enrolls their voice so future meetings recognize them automatically. "
            + "Works while the diarize server still holds this session's voices."
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
        // Rewrite THIS window's transcript: import windows watch a plain
        // file that isn't the live symlink, and profile_assign rewrites
        // whatever MEETINK_TRANSCRIPT names.
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
            // Success rewrites the transcript on disk — the poll picks the
            // change up within 0.5 s, no manual refresh needed. Only surface
            // failures (e.g. cluster no longer in the server's memory).
            if proc.terminationStatus != 0 || out.lowercased().contains("error") {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't assign Speaker \(number)"
                    // Strip ANSI colors from launcher output for display.
                    let plain = out.replacingOccurrences(
                        of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
                    alert.informativeText = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                    alert.runModal()
                }
            }
            _ = self  // keep controller alive through the callback
        }
    }

    // MARK: File watching + render

    func refreshIfChanged(force: Bool = false) {
        if suspendWatching { return }
        let symlink = fixedPath ?? liveSymlinkPath()
        let resolved = (try? FileManager.default.destinationOfSymbolicLink(atPath: symlink))
            .map { dest -> String in
                dest.hasPrefix("/") ? dest : (symlink as NSString).deletingLastPathComponent + "/" + dest
            } ?? symlink

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

        // Any change — growth, in-place rewrite (same inode, size shrinks or
        // matches), rename (inode flip), retarget (path flip) — triggers a
        // full re-read. Transcripts are small; correctness beats cleverness.
        if force || inode != lastInode || size != lastSize || resolved != lastResolvedPath {
            lastInode = inode; lastSize = size; lastResolvedPath = resolved
            if let text = try? String(contentsOfFile: resolved, encoding: .utf8) {
                rawText = text
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
                // Unknown speakers are clickable → click-to-name dialog.
                // The tooltip advertises it; enrolled names aren't links.
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

        textView.textStorage?.setAttributedString(out)
        if wasPinned {
            textView.scrollToEndOfDocument(nil)
        }
        updateJumpButton()
        updateHeader()
    }

    private func updateHeader() {
        if suspendWatching { return }   // progress panel owns the header
        let recording = recordingPID() != nil
        statusDot.textColor = recording ? .systemRed : .tertiaryLabelColor

        var parts: [String] = []
        if let started = snapshot.startedAt {
            let end = snapshot.endedAt ?? Date()
            let secs = max(0, Int(end.timeIntervalSince(started)))
            parts.append(String(format: "%02d:%02d", secs / 60, secs % 60))
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

// MARK: - Menubar + app lifecycle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var transcriptWC: TranscriptWindowController?
    private var importWCs: [TranscriptWindowController] = []
    private var pollTimer: Timer?
    private var lastRecording = false
    private var reallyQuit = false

    /// ⌘Q / Dock-quit / switcher-quit means "put the window away" — the
    /// menubar presence is the app and should survive (Slack/Discord
    /// pattern). Real exit is the menubar's "Quit Completely". System
    /// shutdown/logout must still work: those quit events carry a 'why?'
    /// reason attribute, and we always honor them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if reallyQuit { return .terminateNow }
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.attributeDescriptor(forKeyword: AEKeyword(0x7768793F) /* 'why?' */) != nil {
            return .terminateNow   // shutdown / restart / logout
        }
        transcriptWC?.window?.close()
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    @objc private func quitCompletely() {
        reallyQuit = true
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        // Dock/⌘Tab icon: the bundle's Meetink.icns is the source of truth;
        // this runtime copy only covers running the bare binary outside the
        // bundle (dev/testing). Indigo glyph on a light tile — the glyph
        // carries the color so macOS 26's auto dark-mode icon variant
        // (dark tile, glyph preserved) stays recognizable.
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

        // Window-close drops us back to menubar-only (.accessory) once the
        // LAST window (main or import) goes away, so the Dock/⌘Tab entry
        // only exists while there's a window to switch to.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let closing = note.object as? NSWindow else { return }
                self.importWCs.removeAll { $0.window == closing }
                let mainOpen = self.transcriptWC?.window.map {
                    $0.isVisible && $0 != closing } ?? false
                let importsOpen = self.importWCs.contains {
                    $0.window.map { $0.isVisible && $0 != closing } ?? false }
                if !mainOpen && !importsOpen {
                    NSApp.setActivationPolicy(.accessory)
                }
            }

        showTranscript()
    }

    /// meetink://transcribe — the REPL's /upload opens the same picker the
    /// menubar action uses (URL scheme is the one IPC channel an already-
    /// running app gets for free).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "meetink" {
            if url.host == "transcribe" {
                transcribeAudio()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        showTranscript()
        return true
    }

    /// Key equivalents (⌘F/⌘C/⌘A/⌘W/⌘Q) resolve through the main menu —
    /// which a bare NSApplication.run() app doesn't have until we build one.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Meetink",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        // ⌘Q routes through applicationShouldTerminate → retreats to the
        // menu bar rather than exiting (see note there).
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
        let findPrev = NSMenuItem(title: "Find Previous",
                                  action: #selector(NSResponder.performTextFinderAction(_:)),
                                  keyEquivalent: "G")
        findPrev.tag = Int(NSTextFinder.Action.previousMatch.rawValue)
        editMenu.addItem(findPrev)
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
            img.isTemplate = true   // adapts to menubar light/dark
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

        let upload = NSMenuItem(title: "Transcribe Audio",
                                action: #selector(transcribeAudio), keyEquivalent: "u")
        upload.target = self
        upload.isEnabled = launcherPath() != nil
        menu.addItem(upload)

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
            transcriptWC = TranscriptWindowController(fixedPath: nil, autosave: true)
            transcriptWC?.importHandler = { [weak self] url in
                guard let self else { return }
                self.startImport(url, into: self.transcriptWC)
            }
        }
        // "Show Transcript" means the LIVE transcript — if a drop
        // repurposed the main window into an import view, put it back.
        if transcriptWC?.isShowingImport == true {
            transcriptWC?.returnToLive()
        }
        // Visible window → appear in ⌘Tab and the Dock so the app can't be
        // "lost" behind other windows. Back to .accessory on window close.
        NSApp.setActivationPolicy(.regular)
        transcriptWC?.showWindow(nil)
        transcriptWC?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Audio-file import

    /// Menubar "Transcribe Audio" (and /upload via meetink://transcribe):
    /// opens a persistent blank window inviting a drag-and-drop. The window
    /// stays put — progress renders in it, then the finished transcript.
    /// Deliberately NOT a file picker: modal panels from a menubar app are
    /// easy to lose, and the drop flow is the one every other window
    /// already teaches.
    @objc private func transcribeAudio() {
        let wc = TranscriptWindowController(fixedPath: nil)
        wc.importHandler = { [weak self, weak wc] u in
            self?.startImport(u, into: wc)
        }
        importWCs.append(wc)
        wc.showDropPrompt()
        NSApp.setActivationPolicy(.regular)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drops pass the window they landed on as `into`; it's reused only if
    /// it's an empty viewer, otherwise a new window opens. Menubar/URL
    /// invocations pass nil (always a new window).
    private func startImport(_ url: URL, into target: TranscriptWindowController?) {
        if recordingPID() != nil {
            let alert = NSAlert()
            alert.messageText = "Recording in progress"
            alert.informativeText =
                "Stop the current recording before importing an audio file."
            alert.runModal()
            return
        }
        guard let launcher = launcherPath() else { return }

        // Occupancy decides: an empty window (no transcript, not busy)
        // gets filled; a window tied to content spawns a sibling.
        let wc: TranscriptWindowController
        if let target, target.isEmptyViewer {
            wc = target
        } else {
            wc = TranscriptWindowController(fixedPath: nil)
            wc.importHandler = { [weak self, weak wc] u in
                self?.startImport(u, into: wc)
            }
            importWCs.append(wc)
        }
        wc.window?.title = "Import — \(url.lastPathComponent)"
        NSApp.setActivationPolicy(.regular)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        wc.beginImportProgress(filename: url.lastPathComponent)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcher)
        proc.arguments = ["refine", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Stream the launcher's output live: "refine: progress <label> <pct>"
        // lines drive the bar; "TRANSCRIPT_PATH: ..." names the final file
        // (titling renames it, so the pre-import name is useless).
        var lineBuffer = Data()
        var finalPath: String? = nil
        var allOutput = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak wc] handle in
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
                if line.hasPrefix("refine: progress"),
                   let pct = Int(line.split(separator: " ").last ?? "") {
                    DispatchQueue.main.async { wc?.updateImportProgress(pct) }
                } else if line.hasPrefix("TRANSCRIPT_PATH: ") {
                    finalPath = String(line.dropFirst("TRANSCRIPT_PATH: ".count))
                }
            }
        }
        proc.terminationHandler = { [weak wc] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                if p.terminationStatus == 0, let path = finalPath {
                    wc?.finishImport(path: path)
                } else {
                    wc?.finishImport(path: nil)
                    let alert = NSAlert()
                    alert.messageText = "Couldn't transcribe \(url.lastPathComponent)"
                    alert.informativeText = String(allOutput.suffix(400))
                    alert.runModal()
                }
            }
        }
        try? proc.run()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
