// MeetinkAgent — the Swift sidecar that owns macOS-native integrations
// for /watch.
//
// Two modes, dispatched on argv[1]:
//
//   meetink-agent events [--hours N]
//       Reads upcoming calendar events from the local Calendar.app
//       (EventKit). N defaults to 8. Outputs a single JSON array on
//       stdout with: id, title, start (ISO-8601), end (ISO-8601),
//       attendees (array of name/email pairs), rsvpStatus (one of
//       accepted/declined/tentative/pending/none), location, notes,
//       calendarTitle. Exits 0. Permission required: Calendar.
//
//   meetink-agent notify --title T --body B [--actions A1,A2,...]
//                        [--default A] [--timeout SECS] [--linger SECS]
//                        [--timeout SECS] [--default ACTION]
//       Shows a macOS UserNotification with action buttons and waits
//       up to SECS (default 60) for the user to click one. Exits 0
//       and prints the clicked action name to stdout, or prints the
//       --default action on timeout. Permission required: Notifications.
//
// Why a single binary with subcommands: the .app bundle (built by
// bin/meetink setup) houses one executable. Modes are cheaper than
// separate bundles, and each invocation is a one-shot: no daemon
// state to manage. The Python /watch loop drives the lifecycle by
// polling and spawning these processes as needed.

import Foundation
import EventKit
import UserNotifications

// MARK: - Logging

func eprint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8) ?? Data())
}

// MARK: - JSON helpers

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func jsonString(_ v: Any) -> String {
    // Tolerant pretty stringifier — JSONSerialization escapes correctly
    // for everything we'd want here.
    if let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return "null"
}

// MARK: - events mode

func cmdEvents(args: [String]) -> Int32 {
    var hours: Int = 8
    // Explicit window (ISO8601) for querying around a PAST moment — the
    // app's "link a calendar event to this recording" needs events near
    // the recording's start, which may be days ago. --hours remains the
    // forward-looking spelling the watcher uses.
    var fromDate: Date? = nil
    var toDate: Date? = nil
    let isoIn = ISO8601DateFormatter()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--hours":
            if i + 1 < args.count, let n = Int(args[i + 1]) {
                hours = n
                i += 2
            } else {
                eprint("--hours expects an integer")
                return 2
            }
        case "--from":
            if i + 1 < args.count, let d = isoIn.date(from: args[i + 1]) {
                fromDate = d
                i += 2
            } else {
                eprint("--from expects an ISO8601 date")
                return 2
            }
        case "--to":
            if i + 1 < args.count, let d = isoIn.date(from: args[i + 1]) {
                toDate = d
                i += 2
            } else {
                eprint("--to expects an ISO8601 date")
                return 2
            }
        default:
            i += 1
        }
    }

    let store = EKEventStore()

    // EventKit permission. macOS 14+ uses requestFullAccessToEvents.
    // We use a semaphore to keep this CLI synchronous; no run loop
    // required for the request itself.
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { ok, _ in
            granted = ok
            sem.signal()
        }
    } else {
        store.requestAccess(to: .event) { ok, _ in
            granted = ok
            sem.signal()
        }
    }
    sem.wait()
    if !granted {
        eprint("Calendar access denied. Grant via System Settings → Privacy & Security → Calendar.")
        return 3
    }

    let now = Date()
    let end = toDate
        ?? Calendar.current.date(byAdding: .hour, value: hours, to: now)
        ?? now.addingTimeInterval(Double(hours) * 3600)
    let start = fromDate
        ?? now.addingTimeInterval(-300)  // 5-min look-behind to catch
                                         // ongoing meetings

    // EKEventStore.events(matching:) only takes predicates spanning ≤4 years.
    // We're well within that.
    let predicate = store.predicateForEvents(
        withStart: start,
        end: end,
        calendars: nil  // all calendars
    )
    // Calendars the user unchecked in Settings (CSV of calendar IDs via
    // --hidden-calendars) are filtered here so every consumer — the app's
    // Link Event picker and the watcher alike — sees the same view.
    var hiddenIds = Set<String>()
    var j = 0
    while j < args.count {
        if args[j] == "--hidden-calendars", j + 1 < args.count {
            hiddenIds = Set(args[j + 1].split(separator: ",").map(String.init))
        }
        j += 1
    }
    let events = store.events(matching: predicate).filter {
        !hiddenIds.contains($0.calendar?.calendarIdentifier ?? "")
    }

    var out: [[String: Any]] = []
    for e in events {
        // Skip all-day events — they're rarely real meetings (focus blocks,
        // PTO markers, birthdays, etc.). The /watch loop ignores them.
        if e.isAllDay { continue }

        // RSVP status of the *current user* on this event.
        var rsvpStatus = "none"
        if let attendees = e.attendees {
            for a in attendees {
                if a.isCurrentUser {
                    switch a.participantStatus {
                    case .accepted:  rsvpStatus = "accepted"
                    case .declined:  rsvpStatus = "declined"
                    case .tentative: rsvpStatus = "tentative"
                    case .pending:   rsvpStatus = "pending"
                    default:         rsvpStatus = "none"
                    }
                    break
                }
            }
        }

        var attendeesArr: [[String: String]] = []
        if let attendees = e.attendees {
            for a in attendees {
                var item: [String: String] = [:]
                if let name = a.name { item["name"] = name }
                // url is mailto:foo@bar.com on Google-backed events.
                if let url = a.url as URL? {
                    let s = url.absoluteString
                    if s.hasPrefix("mailto:") {
                        item["email"] = String(s.dropFirst("mailto:".count))
                    } else {
                        item["email"] = s
                    }
                }
                if !item.isEmpty { attendeesArr.append(item) }
            }
        }

        let dict: [String: Any] = [
            "id":            e.eventIdentifier ?? e.calendarItemIdentifier,
            "title":         e.title ?? "(untitled)",
            "calendarId":    e.calendar?.calendarIdentifier ?? "",
            "start":         isoFormatter.string(from: e.startDate),
            "end":           isoFormatter.string(from: e.endDate),
            "attendees":     attendeesArr,
            "rsvpStatus":    rsvpStatus,
            "location":      e.location ?? "",
            "notes":         e.notes ?? "",
            "calendarTitle": e.calendar.title,
        ]
        out.append(dict)
    }

    // Sort by start time so the consumer doesn't have to.
    out.sort { (a, b) -> Bool in
        let sa = (a["start"] as? String) ?? ""
        let sb = (b["start"] as? String) ?? ""
        return sa < sb
    }

    print(jsonString(out))
    return 0
}

// MARK: - notify mode

class NotifyDelegate: NSObject, UNUserNotificationCenterDelegate {
    let identifier: String
    let actions: [String]
    let defaultAction: String
    var clicked: String?
    let semaphore: DispatchSemaphore

    init(identifier: String, actions: [String], defaultAction: String,
         semaphore: DispatchSemaphore) {
        self.identifier = identifier
        self.actions = actions
        self.defaultAction = defaultAction
        self.semaphore = semaphore
    }

    // Fired when the user clicks an action (or the notification itself).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.actionIdentifier
        if id == UNNotificationDefaultActionIdentifier {
            // User clicked the notification body. Treat as the first
            // action (typically "View" / "Confirm" semantics).
            clicked = actions.first ?? defaultAction
        } else if id == UNNotificationDismissActionIdentifier {
            // User dismissed (X). Treat as the default (typically
            // means: do nothing / proceed normally).
            clicked = defaultAction
        } else {
            clicked = id
        }
        completionHandler()
        semaphore.signal()
    }

    // Show notifications even when the calling app is foreground (which
    // we technically are). Without this the notification is suppressed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

func cmdNotify(args: [String]) -> Int32 {
    var title = "meetink"
    var body = ""
    var actions: [String] = []
    var timeoutSecs: Double = 60.0
    var lingerSecs: Double = 0
    var defaultAction = ""

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--title":
            if i + 1 < args.count { title = args[i + 1]; i += 2 } else { i += 1 }
        case "--body":
            if i + 1 < args.count { body = args[i + 1]; i += 2 } else { i += 1 }
        case "--actions":
            if i + 1 < args.count {
                actions = args[i + 1].split(separator: ",").map { String($0) }
                i += 2
            } else { i += 1 }
        case "--timeout":
            if i + 1 < args.count, let n = Double(args[i + 1]) {
                timeoutSecs = n; i += 2
            } else { i += 1 }
        case "--linger":
            if i + 1 < args.count, let n = Double(args[i + 1]) {
                lingerSecs = n; i += 2
            } else { i += 1 }
        case "--default":
            if i + 1 < args.count { defaultAction = args[i + 1]; i += 2 } else { i += 1 }
        default:
            i += 1
        }
    }
    if defaultAction.isEmpty {
        defaultAction = actions.last ?? ""
    }

    let center = UNUserNotificationCenter.current()

    // Permission. macOS shows the prompt on first call; subsequent
    // calls are silent if already granted.
    let permSem = DispatchSemaphore(value: 0)
    var granted = false
    center.requestAuthorization(options: [.alert, .sound]) { ok, err in
        if let err = err {
            eprint("notification permission error: \(err.localizedDescription)")
        }
        granted = ok
        permSem.signal()
    }
    permSem.wait()
    if !granted {
        eprint("Notifications not authorised — falling back to default action.")
        print(defaultAction)
        return 0
    }

    // Build a category whose actions the notification can reference.
    let category = "MEETINK_NOTIFY_\(UUID().uuidString)"
    let unActions = actions.map {
        UNNotificationAction(identifier: $0, title: $0, options: [.foreground])
    }
    // customDismissAction: an explicit dismiss (the ✕) reaches the
    // delegate as UNNotificationDismissActionIdentifier. Without it we
    // can't tell "user said no" apart from "banner slid away on its
    // own" — and the linger loop below must NOT re-post after a real ✕.
    let cat = UNNotificationCategory(
        identifier: category,
        actions: unActions,
        intentIdentifiers: [],
        options: [.customDismissAction]
    )
    center.setNotificationCategories([cat])

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.categoryIdentifier = category
    content.sound = .default
    // Time-sensitive so meeting warnings break through Focus modes —
    // "your meeting starts in 1 minute" is useless after the meeting
    // started. Needs the matching entitlement in the signature; macOS
    // silently downgrades to the default level without it.
    if #available(macOS 12.0, *) {
        content.interruptionLevel = .timeSensitive
    }

    // With ALERTS style (user-set in System Settings → Notifications)
    // the banner persists until engaged — the linger re-posting below
    // would only cause visible churn, so it is skipped entirely. The
    // re-post dance is a banner-style workaround, not the good path.
    var styleIsAlert = false
    let styleSem = DispatchSemaphore(value: 0)
    center.getNotificationSettings { settings in
        styleIsAlert = settings.alertStyle == .alert
        styleSem.signal()
    }
    styleSem.wait()

    let identifier = UUID().uuidString
    let request = UNNotificationRequest(
        identifier: identifier,
        content: content,
        trigger: nil  // deliver immediately
    )

    let waitSem = DispatchSemaphore(value: 0)
    let delegate = NotifyDelegate(
        identifier: identifier,
        actions: actions,
        defaultAction: defaultAction,
        semaphore: waitSem
    )
    center.delegate = delegate

    let addSem = DispatchSemaphore(value: 0)
    var addError: Error? = nil
    center.add(request) { err in
        addError = err
        addSem.signal()
    }
    addSem.wait()
    if let err = addError {
        eprint("notification add failed: \(err.localizedDescription)")
        print(defaultAction)
        return 0
    }

    // Wait for click or timeout. Drive the runloop on the main thread
    // so the delegate callbacks fire — UNUserNotificationCenter requires
    // main-thread delivery.
    //
    // --linger: macOS banners auto-slide away after ~5 s and no public
    // API extends that (Alerts style is a per-app USER setting). So for
    // the linger window we silently re-post the banner each time it
    // slides away: remove the delivered copy, add a fresh request with
    // no sound. Explicit ✕ or a button click sets delegate.clicked and
    // ends the loop; auto-slide fires nothing, so only auto-slide gets
    // re-posted. After the window the last copy sits in Notification
    // Center, buttons still live until --timeout.
    let deadline = Date().addingTimeInterval(timeoutSecs)
    let lingerEnd = Date().addingTimeInterval(lingerSecs)
    var currentId = identifier
    var reposts = 0
    var nextRepost = Date().addingTimeInterval(18.0)
    while delegate.clicked == nil && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        // Banner-style linger: a GENTLE re-post (every ~20 s, capped) —
        // the old 6 s remove-then-add cycle strobed ("popping up,
        // dismissing, popping up again"). New banner posts BEFORE the
        // old one is removed so there is never a visible gap.
        if !styleIsAlert, lingerSecs > 0, reposts < 4,
           delegate.clicked == nil,
           Date() >= nextRepost, Date() < lingerEnd {
            let previousId = currentId
            let repost = UNMutableNotificationContent()
            repost.title = title
            repost.body = body
            repost.categoryIdentifier = category
            repost.sound = nil  // one ding was enough
            if #available(macOS 12.0, *) {
                repost.interruptionLevel = .timeSensitive
            }
            currentId = UUID().uuidString
            center.add(UNNotificationRequest(
                identifier: currentId, content: repost, trigger: nil
            )) { _ in
                center.removeDeliveredNotifications(withIdentifiers: [previousId])
            }
            reposts += 1
            nextRepost = Date().addingTimeInterval(18.0 + Double.random(in: 0...4))
        }
    }

    // Best-effort cleanup so dismissed notifications don't linger.
    center.removeDeliveredNotifications(withIdentifiers: [currentId])
    center.removePendingNotificationRequests(withIdentifiers: [currentId])

    print(delegate.clicked ?? defaultAction)
    return 0
}

// MARK: - meeting-active mode

import AVFoundation
import CoreAudio

// Process-name patterns that indicate an active video-call client.
// Patterns must be specific enough to avoid matching always-running
// background processes — e.g. Slack runs 24/7, so its main process
// can't be a signal. We pick patterns that are more strongly
// associated with an *active call*, even if not perfect.
let kConferencingProcesses: [(label: String, patterns: [String])] = [
    // Zoom: CptHost is spawned ONLY during a call — the one hard "in
    // call" signal. The main zoom.us process must NOT be a pattern: it
    // idles in the dock all day, and matching it started phantom
    // recordings whenever Zoom launched ahead of a meeting (field case:
    // 'a recording just started out of the blue', 6 min before the
    // event, meeting-active already false again by inspection).
    ("zoom",  ["CptHost"]),
    // Teams: MSTeams is the main process; we'd ideally distinguish
    // call-active from "Teams open in tray", but Teams doesn't make
    // that easy without private APIs. Accept the false-positive risk
    // here since most users only run Teams when working.
    ("teams", ["Microsoft Teams (workOrSchool)", "MSTeams"]),
    ("webex", ["Webex", "WebexHelper"]),
    // Standalone Meet PWA: the process is app_mode_loader inside
    // ".../Google Meet.app/..." — pgrep -lf matches the PATH, and the
    // real name has a space ("GoogleMeet" alone never matched; field
    // case: native-app call produced zero presence → no auto-start,
    // no auto-stop).
    ("meet",  ["GoogleMeet", "Google Meet"]),
]

/// Every conferencing group's state from ONE pgrep scan — the debug
/// view needs the negatives ("Zoom call process: not running") as much
/// as the verdict needs the first positive.
func conferencingProcessStates() -> [(label: String, matched: String?)] {
    // `pgrep -lf` matches against the full command line; -i ignores case.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-lf", "."]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do { try proc.run() } catch {
        return kConferencingProcesses.map { ($0.label, nil) }
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard let s = String(data: data, encoding: .utf8) else {
        return kConferencingProcesses.map { ($0.label, nil) }
    }
    let lower = s.lowercased()
    return kConferencingProcesses.map { (label, patterns) in
        (label, patterns.first { lower.contains($0.lowercased()) })
    }
}

func runningConferencingApp() -> String? {
    conferencingProcessStates().first { $0.matched != nil }?.label
}

// Camera-in-use check via AVCaptureDevice. Returns true if *any* video
// device is being used by another process — the strongest signal we
// have for "video call active". Falls cleanly when the user has video
// off the whole call, which is why we combine with process detection.
@available(macOS 14.0, *)
func cameraInUseElsewhere() -> Bool {
    // Only the built-in wide-angle camera. .external is deprecated and
    // .continuityCamera needs an Info.plist entry that doesn't help us
    // detect anything we don't already get via processes (Continuity
    // Camera implies the iPhone is acting as a camera for an app we're
    // already detecting).
    // .external too: a Mac Studio/mini has NO built-in camera — the
    // camera signal was permanently dead on desktop Macs (field case),
    // and external webcams are exactly what those machines use.
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    if #available(macOS 14.0, *) {
        types.append(.external)
    }
    let session = AVCaptureDevice.DiscoverySession(
        deviceTypes: types,
        mediaType: .video,
        position: .unspecified
    )
    for d in session.devices {
        if d.isInUseByAnotherApplication { return true }
    }
    return false
}

// Mic-in-use via CoreAudio: is the default input device running for
// ANYONE? The definitive "in a call" corroborator — but it cannot be
// attributed per-process, and meetink's own capture holds the mic for
// the whole recording, so the signal is only meaningful when we are
// NOT recording (suppressed via the capture pid file, same convention
// the launcher uses).
func meetinkCaptureRunning() -> Bool {
    if let pidStr = try? String(contentsOfFile: "/tmp/meetink-capture.pid",
                                encoding: .utf8),
       let p = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return kill(p, 0) == 0
    }
    return false
}

func micDeviceRunning() -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &deviceID) == noErr,
          deviceID != 0 else { return false }
    addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    var running: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size,
                                     &running) == noErr else { return false }
    return running != 0
}

// Browser tab URL scan via AppleScript. Catches Google Meet, Whereby,
// Around, Jitsi etc. in Chrome / Safari / Arc / Brave / Edge. Tolerant:
// returns nil if no browser is running or Automation permission was denied.
//
// Patterns are evaluated as regexes (case-insensitive after the lower-cased
// input). Anchoring the meeting-room URL — rather than matching the bare
// host — is how we flip "active = false" the moment the user presses End:
// Meet, Zoom, Teams, etc. redirect away from the room URL into a landing
// page within ~1 s of leaving, so a tight regex catches the transition
// the very next poll without waiting on `meet.google.com` matching a
// stale landing-page tab.
let kBrowserMeetingPatterns: [(label: String, patterns: [String])] = [
    // Meet room codes are 3-4-3 lowercase letters (e.g. abc-defg-hij).
    // Lookup URLs (meet.google.com/lookup/...) also indicate an active
    // join in progress. The /_meet/ prefix shows up after Workspace
    // cohort redirects — same room code, just routed through a
    // privacy-namespace path. Bare meet.google.com (landing) is excluded.
    ("meet",   ["meet\\.google\\.com/[a-z]{3,4}-[a-z]{3,5}-[a-z]{3,4}",
                "meet\\.google\\.com/_meet/[a-z]{3,4}-[a-z]{3,5}-[a-z]{3,4}",
                "meet\\.google\\.com/lookup/"]),
    ("zoom",   ["zoom\\.us/j/[0-9]", "zoom\\.us/wc/[0-9]"]),
    // Teams meeting URLs go through /l/meetup-join/ or /_#/conv/.
    ("teams",  ["teams\\.microsoft\\.com/l/meetup-join/",
                "teams\\.microsoft\\.com/_#/conv/",
                "teams\\.live\\.com/meet/"]),
    // Webex's join URL uses /meet/ for personal rooms, /j.php?MTID= for
    // scheduled meetings, /wbxmjs/ for the web app session.
    ("webex",  ["webex\\.com/meet/",
                "webex\\.com/j\\.php\\?",
                "webex\\.com/wbxmjs/"]),
    // Whereby rooms always have a path after the host.
    ("whereby",["whereby\\.com/[a-z0-9]"]),
    ("jitsi",  ["meet\\.jit\\.si/[a-z0-9]"]),
    ("around", ["around\\.co/r/", "around\\.co/meet/"]),
]

func browserMeetingActive() -> String? {
    let script = """
    set out to ""
    repeat with appName in {"Google Chrome", "Safari", "Arc", "Brave Browser", "Microsoft Edge"}
      try
        tell application appName
          if it is running then
            repeat with w in (every window)
              try
                set tabList to (every tab of w)
                repeat with t in tabList
                  set u to URL of t
                  set out to out & u & "\\n"
                end repeat
              on error
                -- Safari uses `current tab` not `tabs`. Try that.
                try
                  set u to URL of (current tab of w)
                  set out to out & u & "\\n"
                end try
              end try
            end repeat
          end if
        end tell
      end try
    end repeat
    return out
    """
    var error: NSDictionary?
    guard let scriptObj = NSAppleScript(source: script) else { return nil }
    let result = scriptObj.executeAndReturnError(&error)
    if error != nil { return nil }
    guard let s = result.stringValue?.lowercased() else { return nil }
    for (label, patterns) in kBrowserMeetingPatterns {
        for p in patterns {
            if s.range(of: p, options: .regularExpression) != nil {
                return label
            }
        }
    }
    return nil
}

func cmdMeetingActive(args: [String]) -> Int32 {
    var sources: [String] = []
    var primary: String? = nil
    // Debug transparency: every observation this function makes lands
    // in `checks` AS IT IS MADE — the Activity page renders this array
    // verbatim and knows nothing about individual signals, so a signal
    // added here shows up there automatically. Never compute a check
    // from separate logic: the row must be the same boolean the verdict
    // used, or the debug view lies (the anti-regression contract).
    var checks: [[String: Any]] = []

    let recording = meetinkCaptureRunning()
    let micRaw = micDeviceRunning()
    let mic = micRaw && !recording   // self-held while we record
    let camera: Bool = {
        if #available(macOS 14.0, *) { return cameraInUseElsewhere() }
        return false
    }()

    checks.append(["label": "mic in use",
                   "state": mic,
                   "detail": recording
                       ? (micRaw ? "held by meetink capture — unknowable"
                                 : "idle")
                       : (micRaw ? "hot (some app is listening)" : "idle")])
    checks.append(["label": "camera in use",
                   "state": camera,
                   "detail": camera ? "in use (built-in or external)"
                                    : "idle"])

    // Per-app call-process descriptions: which pattern class each group
    // watches, so "Zoom open but no call" reads correctly (we watch
    // Zoom's call-only CptHost, not the idling main app).
    let procDesc: [String: String] = [
        "zoom":  "Zoom in-call process (CptHost)",
        "teams": "Teams app process",
        "webex": "Webex process",
        "meet":  "Google Meet app process",
    ]
    var firstProc: String? = nil
    var procCounted = false
    for (label, matched) in conferencingProcessStates() {
        let isMatch = matched != nil
        // Idle-capable apps (their process runs OUTSIDE calls too: the
        // Meet PWA on its landing page, Teams in the tray) need mic or
        // camera corroboration — an open-but-idle app must not read as
        // a meeting. Call-only processes (Zoom's CptHost, Webex helper)
        // stand alone. While a recording runs the mic is self-held and
        // unknowable, so process presence suffices — never drop a
        // camera-off call mid-recording for lack of corroboration.
        let idleCapable = (label == "meet" || label == "teams")
        let counted = isMatch && (!idleCapable || mic || camera || recording)
        var detail = isMatch ? "running (\(matched!))" : "not running"
        if isMatch && !counted {
            detail += " — open but no mic/camera, NOT counted as a meeting"
        }
        checks.append(["label": procDesc[label] ?? label,
                       "state": counted,
                       "detail": detail])
        if counted && firstProc == nil {
            firstProc = label
            procCounted = true
        }
    }
    if procCounted, let p = firstProc {
        sources.append("process:\(p)")
        primary = primary ?? p
    }

    if camera {
        sources.append("camera")
        primary = primary ?? "video"
    }

    let tab = browserMeetingActive()
    checks.append(["label": "browser meeting tab",
                   "state": tab != nil,
                   "detail": tab.map { "room URL open (\($0))" }
                       ?? "no meeting-room tab"])
    if let b = tab {
        sources.append("browser:\(b)")
        primary = primary ?? b
    }

    // Mic is a CORROBORATOR, never standalone evidence — dictation and
    // voice memos hold the mic too. Reported only alongside a matched
    // source so the watcher can see what confirmed it.
    if mic && !sources.isEmpty {
        sources.append("mic")
    }

    let active = !sources.isEmpty
    checks.append(["label": "VERDICT: in a meeting",
                   "state": active,
                   "detail": active
                       ? "source: \(primary ?? "?")  signals: \(sources.joined(separator: ", "))"
                       : "no qualifying signals"])
    let out: [String: Any] = [
        "active":  active,
        "source":  primary ?? NSNull(),
        "signals": sources,
        "checks":  checks,
    ]
    print(jsonString(out))
    return 0
}

// MARK: - dispatch

let allArgs = CommandLine.arguments
if allArgs.count < 2 {
    eprint("usage: meetink-agent <events|notify|meeting-active> [...args]")
    exit(2)
}

let mode = allArgs[1]
let rest = Array(allArgs.dropFirst(2))

switch mode {
case "calendars":
    // All event calendars, grouped by account — the Settings page's
    // show/hide list. Same permission dance as events.
    let store = EKEventStore()
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    if #available(macOS 14.0, *) {
        store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
    } else {
        store.requestAccess(to: .event) { ok, _ in granted = ok; sem.signal() }
    }
    sem.wait()
    if !granted {
        eprint("Calendar access denied.")
        exit(3)
    }
    let cals: [[String: String]] = store.calendars(for: .event).map {
        ["id": $0.calendarIdentifier,
         "title": $0.title,
         "account": $0.source?.title ?? "Other"]
    }
    if let data = try? JSONSerialization.data(withJSONObject: cals),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
    exit(0)

case "events":
    exit(cmdEvents(args: rest))
case "notify":
    exit(cmdNotify(args: rest))
case "meeting-active":
    exit(cmdMeetingActive(args: rest))
default:
    eprint("unknown mode: \(mode)")
    eprint("usage: meetink-agent <events|notify|meeting-active> [...args]")
    exit(2)
}
