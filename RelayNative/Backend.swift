import Foundation
import SwiftUI
import AppKit
import UserNotifications
import AVFoundation
import Translation

/// Records a voice note to a temp .m4a file.
@MainActor final class VoiceRecorder: ObservableObject {
    @Published var recording = false
    @Published var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var timer: Timer?

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { if granted { self.begin() } }
        }
    }
    private func begin() {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let r = try? AVAudioRecorder(url: u, settings: settings) else { return }
        r.record(); recorder = r; url = u; recording = true; elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
    }
    /// Stop and return the file (nil if too short / failed).
    func stop() -> URL? {
        recorder?.stop(); timer?.invalidate(); timer = nil; recording = false
        let u = url; recorder = nil; url = nil
        if let u, (try? u.checkResourceIsReachable()) == true, elapsed >= 0.5 { return u }
        if let u { try? FileManager.default.removeItem(at: u) }
        return nil
    }
    func cancel() {
        recorder?.stop(); timer?.invalidate(); timer = nil; recording = false
        if let u = url { try? FileManager.default.removeItem(at: u) }
        recorder = nil; url = nil
    }
}

// MARK: - Models

struct Contact: Identifiable, Codable {
    let id: String
    var name: String
    var firstName: String
    var avatar: String
    var display: String { name.isEmpty ? firstName : name }
}

struct ChatThread: Identifiable, Codable {
    let id: String
    var contactID: String   // raw fbid for contact/avatar lookup (id may be namespaced "e:…")
    var name: String
    var snippet: String
    var picture: String
    var lastActivity: Double
    var unread: Bool
    // Inbox state (default-filled so older cached threads still decode — see the
    // custom decoder below; Swift's synthesized one would throw on the missing keys).
    var folder: String = "inbox"   // inbox | requests | spam | archived
    var muted: Bool = false        // synced from the server
    var pinned: Bool = false       // local: pin a thread to the top
    var readUpTo: Double = 0       // our read watermark (ms) — drives the unread count
}

extension ChatThread {
    // Decode tolerantly: a cache.json written before these fields existed has no
    // folder/muted/pinned keys, so fall back to defaults instead of throwing
    // (which would fail the whole cache load and risk losing built history).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        contactID = try c.decode(String.self, forKey: .contactID)
        name = try c.decode(String.self, forKey: .name)
        snippet = try c.decode(String.self, forKey: .snippet)
        picture = try c.decode(String.self, forKey: .picture)
        lastActivity = try c.decode(Double.self, forKey: .lastActivity)
        unread = try c.decode(Bool.self, forKey: .unread)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? "inbox"
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        readUpTo = try c.decodeIfPresent(Double.self, forKey: .readUpTo) ?? 0
    }
}

struct Message: Identifiable, Equatable, Codable {
    let id: String
    let thread: String
    let sender: String
    let text: String
    let ts: Double
    let system: Bool
    // Media (optional so older cached messages still decode — never break the cache).
    var kind: String? = nil       // nil/"text" | "image" | "sticker"
    var mediaPath: String? = nil  // local decrypted file (encrypted chats)
    var mediaURL: String? = nil   // CDN url (regular chats)
    var replyToId: String? = nil    // message this one replies to
    var replyToText: String? = nil  // quoted text to show above this message
    var replyToSender: String? = nil
    var hasMedia: Bool { ["image", "sticker", "video", "audio", "file"].contains(kind ?? "") }
    var isInlineImage: Bool { kind == "image" || kind == "sticker" }
    static func == (a: Message, b: Message) -> Bool {
        a.id == b.id && a.mediaPath == b.mediaPath && a.mediaURL == b.mediaURL
    }
}

/// A message composed now but delivered at `fireAt` (ms epoch). Fires while Relay runs;
/// any that came due while it was closed are sent at the next launch.
struct ScheduledMessage: Identifiable, Codable {
    let id: String
    let thread: String
    let text: String
    let fireAt: Double
}

/// A person's online / last-seen status (from the encrypted presence channel).
struct PresenceInfo {
    var online: Bool
    var lastSeen: Double?   // ms since epoch, if known
}

// MARK: - Store

/// Single source of truth for the UI, fed by the helper's event stream.
@MainActor
final class RelayStore: ObservableObject {
    // One shared session for the whole process, so App Intents (Siri/Shortcuts) drive the
    // same live connection the UI uses instead of spinning up a second helper.
    static let shared = RelayStore()

    // The single spring used for a message's send/insert and the scroll that follows it, so
    // the bubble and the scroll move as one coherent motion (no competing timings).
    static let sendSpring = Animation.spring(response: 0.4, dampingFraction: 0.82)

    // An App Intent asked to open a conversation; ContentView observes this and selects it.
    @Published var pendingOpen: String?

    @Published var threads: [ChatThread] = []
    @Published var contacts: [String: Contact] = [:]
    // The loaded message window per thread. Bumping `messagesRevision` on every change gives
    // views a cheap O(1) signal to rebuild their row model only when messages actually change
    // (not on every unrelated re-render like hover/typing/presence — that was the long-chat
    // stutter). The window is kept short and slides as you scroll (see windowSize/maxLoaded).
    @Published var messagesByThread: [String: [Message]] = [:] { didSet { messagesRevision &+= 1 } }
    @Published private(set) var messagesRevision = 0
    // Set true immediately before an INVISIBLE in-place message swap (optimistic "local-…" id
    // → the server's real id). The transcript consumes it to rebuild its rows WITHOUT replaying
    // the entrance animation — otherwise the bubble glides in a second time when the send is
    // acked, which reads as "I sent two messages".
    var silentSwap = false
    @Published var atLiveEdge: Set<String> = []   // window currently includes the newest message
    private let windowSize = 30                    // messages loaded when opening / at the bottom
    private let maxLoaded = 90                      // hard cap on a thread's in-memory window
    @Published var participantsByThread: [String: Set<String>] = [:]
    @Published var adminsByThread: [String: Set<String>] = [:]      // thread → admin contact ids
    @Published var selfID: String = ""
    @Published var connected = false
    @Published var needsLogin = false                              // show the in-app login
    @Published var status = "Starting…"
    @Published var presenceByContact: [String: PresenceInfo] = [:]   // fbid → status
    @Published var typingByThread: [String: Bool] = [:]              // thread id → someone typing
    @Published var readWatermark: [String: Double] = [:]            // thread → read-up-to ts
    @Published var deliveredWatermark: [String: Double] = [:]       // thread → delivered-up-to ts
    @Published var reactions: [String: [String: String]] = [:]     // messageID → (actorID → emoji)
    @Published var scrollTarget: String? = nil                     // message to jump to (from search)
    @Published var hoverMessage: String? = nil                     // the one message showing its action pill
    @Published var draftsByThread: [String: String] = [:]          // unsent composer text per thread
    @Published var editedMessages: Set<String> = []                // messages that show an "edited" marker
    // Per-chat accent color (threadID → hex). Purely local cosmetics — Messenger's own
    // theme API isn't reachable over Lightspeed, so we tint replies + badges client-side.
    @Published var chatColors: [String: String] = [:] {
        didSet { UserDefaults.standard.set(chatColors, forKey: "chatColors") }
    }

    /// The accent for a thread: its custom color if set, else the app's default violet.
    func accent(for threadID: String) -> Color {
        if let hex = chatColors[threadID], let c = Color(hex: hex) { return c }
        return .accentColor
    }
    /// Set (or clear, with nil) a thread's custom color.
    func setChatColor(_ threadID: String, hex: String?) {
        if let hex { chatColors[threadID] = hex } else { chatColors.removeValue(forKey: threadID) }
    }

    // Per-conversation, per-person nicknames (threadID → contactID → nickname). Local only —
    // Messenger's nickname API isn't reachable over Lightspeed, so these are cosmetic overrides
    // that win over the real contact name everywhere that conversation is shown.
    @Published var nicknames: [String: [String: String]] = [:] {
        didSet { persistNicknames() }
    }
    /// This person's nickname in this thread, if one is set (non-empty).
    func nickname(for contactID: String, in thread: String) -> String? {
        guard let n = nicknames[thread]?[contactID], !n.isEmpty else { return nil }
        return n
    }
    /// Set or clear (nil/empty) a person's nickname in a thread.
    func setNickname(_ name: String?, for contactID: String, in thread: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            nicknames[thread, default: [:]][contactID] = trimmed
        } else {
            nicknames[thread]?[contactID] = nil
            if nicknames[thread]?.isEmpty == true { nicknames[thread] = nil }
        }
    }
    /// Display name for a person *inside a given thread*: their nickname if set, else their
    /// real name. Use this everywhere a conversation shows a person (bubbles, members, title).
    func displayName(_ id: String, in thread: String) -> String {
        if id == selfID { return nickname(for: id, in: thread) ?? "You" }
        return nickname(for: id, in: thread) ?? name(for: id)
    }
    private func persistNicknames() {
        UserDefaults.standard.set(try? JSONEncoder().encode(nicknames), forKey: "nicknames")
    }

    // Per-conversation wallpaper (threadID → identifier). A built-in id ("aurora", "graphite", …)
    // or "file:<path>" for a user-chosen image. Local only; purely cosmetic.
    @Published var wallpapers: [String: String] = [:] {
        didSet { UserDefaults.standard.set(wallpapers, forKey: "wallpapers") }
    }
    func wallpaper(for thread: String) -> String? { wallpapers[thread] }
    func setWallpaper(_ id: String?, for thread: String) {
        if let id { wallpapers[thread] = id } else { wallpapers.removeValue(forKey: thread) }
    }

    // MARK: conversation export

    /// Build a plain-text transcript of a thread between two dates (inclusive). Media shows as a
    /// "[Photo]/[Video]/…" placeholder — text only, by design. Newest message last.
    func transcript(for thread: ChatThread, from: Date?, to: Date?) -> String {
        let lo = (from?.timeIntervalSince1970 ?? 0) * 1000
        let hi = (to?.timeIntervalSince1970 ?? Date.distantFuture.timeIntervalSince1970) * 1000
        let msgs = db.allForThread(thread.id)
            .filter { $0.ts >= lo && $0.ts <= hi && !$0.id.hasPrefix("local-") }
            .sorted { $0.ts < $1.ts }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "Conversation with \(threadTitle(thread))\n"
        out += "Exported from Relay on \(df.string(from: Date()))\n"
        out += String(repeating: "—", count: 32) + "\n\n"
        for m in msgs {
            let when = df.string(from: Date(timeIntervalSince1970: m.ts / 1000))
            if m.system {
                out += "[\(when)] · \(m.text)\n"
                continue
            }
            let who = displayName(m.sender, in: thread.id)
            var line = m.text
            if m.hasMedia {
                let label = Self.mediaPlaceholder(m.kind ?? "file")
                line = m.text.isEmpty || m.text == label ? "[\(label)]" : "[\(label)] \(m.text)"
            }
            out += "[\(when)] \(who): \(line)\n"
        }
        if msgs.isEmpty { out += "(No messages in this range.)\n" }
        return out
    }

    // Scheduled sends (compose now, deliver later) + per-thread snooze (hide until a time).
    @Published var scheduled: [ScheduledMessage] = []
    @Published var snoozedUntil: [String: Double] = [:]   // threadID → ms epoch
    private var scheduleTimer: Timer?
    private var snoozeTimer: Timer?

    // On-device translation. translations: messageID → translated text; autoTranslate: threads
    // that translate every message (incl. future ones). translationConfig drives a hidden
    // .translationTask host that performs the work.
    @Published var translations: [String: String] = [:]
    @Published var autoTranslate: Set<String> = []
    // Holds a `TranslationSession.Configuration` on macOS 15+ (typed as Any? so the property
    // itself carries no 15-only type — Relay's deployment floor is Ventura/13, where the
    // Translation framework doesn't exist and this stays nil).
    @Published var translationConfigBox: Any?
    private var translateQueue: [(id: String, text: String)] = []

    // Saved/starred messages (local bookmarks across all chats).
    @Published var starred: Set<String> = []
    func isStarred(_ id: String) -> Bool { starred.contains(id) }
    func toggleStar(_ id: String) {
        if starred.contains(id) { starred.remove(id) } else { starred.insert(id) }
        UserDefaults.standard.set(Array(starred), forKey: "starredMessages")
    }
    /// All saved messages across every conversation, newest first. Pulled from the DB by id so
    /// it works even for starred messages outside the loaded window.
    var savedMessages: [Message] {
        db.byIDs(Array(starred)).sorted { $0.ts > $1.ts }
    }

    func isTranslated(_ id: String) -> Bool { translations[id] != nil }

    func requestTranslation(_ id: String, _ text: String) {
        guard #available(macOS 15.0, *) else { return }   // Translation framework is 15+
        let t = text.trimmingCharacters(in: .whitespaces)
        guard translations[id] == nil, !t.isEmpty,
              !translateQueue.contains(where: { $0.id == id }) else { return }
        translateQueue.append((id, t))
        if var cfg = translationConfigBox as? TranslationSession.Configuration {
            cfg.invalidate()
            translationConfigBox = cfg
        } else {
            translationConfigBox = TranslationSession.Configuration()
        }
    }
    func removeTranslation(_ id: String) { translations[id] = nil }

    /// Toggle "translate this whole conversation" — translates everything now and (via the
    /// message handler) every message that arrives afterward.
    func toggleAutoTranslate(_ thread: String) {
        if autoTranslate.contains(thread) {
            autoTranslate.remove(thread)
            for m in messagesByThread[thread] ?? [] { translations[m.id] = nil }
        } else {
            autoTranslate.insert(thread)
            for m in messagesByThread[thread] ?? [] where !m.system && !m.hasMedia {
                requestTranslation(m.id, m.text)
            }
        }
        UserDefaults.standard.set(Array(autoTranslate), forKey: "autoTranslate")
    }

    /// Performed inside the hidden .translationTask host whenever the config (in)validates.
    @available(macOS 15.0, *)
    func runTranslations(_ session: TranslationSession) async {
        let batch = translateQueue; translateQueue = []
        guard !batch.isEmpty else { return }
        let requests = batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
        if let responses = try? await session.translations(from: requests) {
            for r in responses { if let id = r.clientIdentifier { translations[id] = r.targetText } }
        }
    }

    private let helper = HelperClient()
    private let db = MessageStore()               // durable message store + full-text search
    private var saveWork: DispatchWorkItem?
    private var typingClear: [String: DispatchWorkItem] = [:]   // per-thread typing auto-clear
    private var pendingMedia: [String: [String: Any]] = [:]     // media that arrived before its message

    private let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }()

    // Durable cache for media (incoming decrypted attachments + a copy of what we send), so
    // attachments survive the OS purging the temp dir.
    private let mediaDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay/media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Copy an about-to-be-sent attachment out of the throwaway temp dir into our durable
    /// media cache and return the durable URL (falls back to the original on any failure, so
    /// a send never breaks just because the copy didn't).
    private func persistOutgoingMedia(_ src: URL) -> URL {
        // Already living in our media cache (e.g. re-send) — nothing to copy.
        if src.path.hasPrefix(mediaDir.path) { return src }
        let dest = mediaDir.appendingPathComponent("out-\(UUID().uuidString)-\(src.lastPathComponent)")
        do { try FileManager.default.copyItem(at: src, to: dest); return dest }
        catch { return src }
    }
    // Lightweight metadata cache. Messages used to live here too; they now live in
    // SQLite (`messages` is kept only to migrate the old file, then dropped).
    private struct Cache: Codable {
        var threads: [ChatThread]; var contacts: [String: Contact]
        var messages: [String: [Message]]?; var selfID: String
        var drafts: [String: String]?
        var edited: [String]?
    }

    private var started = false
    func start() {
        guard !started else { return }   // only once, even if the window reopens
        started = true
        if let saved = UserDefaults.standard.dictionary(forKey: "chatColors") as? [String: String] {
            chatColors = saved
        }
        if let wp = UserDefaults.standard.dictionary(forKey: "wallpapers") as? [String: String] {
            wallpapers = wp
        }
        if let data = UserDefaults.standard.data(forKey: "nicknames"),
           let nn = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            nicknames = nn
        }
        loadCache()   // restore conversations so they survive restarts
        loadDeferredState()   // scheduled sends + snoozes
        housekeeping()   // clean up after ourselves so nothing piles up on disk
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared
        // A "Reply" text field right on the banner — answer without opening the app.
        let reply = UNTextInputNotificationAction(identifier: "REPLY", title: "Reply",
                                                  options: [], textInputButtonTitle: "Send",
                                                  textInputPlaceholder: "Message")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "RELAY_MESSAGE", actions: [reply],
                                   intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        helper.onEvent = { [weak self] evt in self?.handle(evt) }
        helper.onStatus = { [weak self] s in self?.status = s }
        if let cookies = CookieVault.resolve() {
            helper.start(cookies: cookies)
        } else {
            needsLogin = true
            status = "Sign in to continue"
        }
    }

    /// Start the session if it isn't already (safe to call repeatedly — `start()` self-guards).
    /// Used by App Intents that may fire before the UI has appeared.
    func ensureStarted() { start() }

    /// Wait until the helper reports connected, up to `timeout` seconds. Returns true if
    /// connected, false if it timed out or we need a login. Polls cheaply on the main actor.
    func waitUntilConnected(timeout: TimeInterval) async -> Bool {
        if connected { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if connected { return true }
            if needsLogin { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)   // 0.2s
        }
        return connected
    }

    /// Called by the in-app login once a Facebook session is captured: persist it to
    /// the Keychain and (re)connect. The user never needs the cookie file again.
    func completeLogin(_ cookies: String) {
        CookieVault.save(cookies)
        needsLogin = false
        connected = false
        status = "Connecting…"
        helper.start(cookies: cookies)   // start() stops any existing helper first
    }

    /// Manually drop to the sign-in screen (e.g. a stale session that still has a
    /// c_user cookie so the server-side rejection didn't surface as needLogin).
    func requestRelogin() {
        helper.stop()
        connected = false
        needsLogin = true
        status = "Sign in to continue"
    }

    /// Sign out: forget the session and drop to the login screen.
    func signOut() {
        CookieVault.clear()
        helper.stop()
        connected = false
        selfID = ""
        needsLogin = true
        status = "Signed out"
    }

    /// Post a system notification with the message content (the whole point of Relay).
    private func notify(threadID: String, sender: String, body: String) {
        guard UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }
        let title = threads.first(where: { $0.id == threadID }).map(threadTitle) ?? name(for: sender)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if UserDefaults.standard.object(forKey: "notificationSound") as? Bool ?? true { content.sound = .default }
        content.categoryIdentifier = "RELAY_MESSAGE"      // enables the inline Reply field
        content.threadIdentifier = threadID               // group a chat's notifications
        content.userInfo = ["threadID": threadID]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Tidy up after ourselves on launch so nothing accumulates on disk over time. Every step
    /// is best-effort and runs off the main thread. Note: Sparkle already deletes its own
    /// update download right after installing (verified: its caches sit empty between runs) —
    /// the sweep below is just belt-and-braces for a download an interrupted install left behind.
    private func housekeeping() {
        rescueTempMedia()   // save any sent attachments still stranded in the temp dir
        let inUse = db.referencedMediaPaths()   // never delete a file history still points at
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let now = Date()

            // 0) Security: never let the session sit in cleartext. Once it's in the Keychain,
            //    remove any leftover plaintext cookie files (older builds didn't clean these).
            CookieVault.purgePlaintextBackups()
            func age(_ u: URL) -> TimeInterval {
                let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                return d.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            }

            // 1) Throwaway scratch files we create when sending (voice notes / pasted images /
            //    GIFs). Once sent they're copied into the durable media cache, so the temp copy
            //    is disposable — drop any that are no longer referenced and older than an hour
            //    (well past any in-flight upload).
            if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                       includingPropertiesForKeys: [.contentModificationDateKey]) {
                for u in items where u.lastPathComponent.hasPrefix("relay-") {
                    if !inUse.contains(u.path), age(u) > 3600 { try? fm.removeItem(at: u) }
                }
            }

            // 2) The one-time pre-migration cache backup. Once the SQLite DB holds the history
            //    it's done its job — remove it after a week so it doesn't sit forever.
            let bak = self.cacheURL.deletingPathExtension().appendingPathExtension("premigration.bak")
            if fm.fileExists(atPath: bak.path), age(bak) > 7 * 24 * 3600 { try? fm.removeItem(at: bak) }

            // 3) Belt-and-braces: sweep any stale leftovers from Sparkle's update caches (an
            //    interrupted install can strand an archive). Only touch files older than a day,
            //    so a download in progress is never disturbed.
            let bundleID = Bundle.main.bundleIdentifier ?? "com.hatim.relay"
            let sparkle = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(bundleID)/org.sparkle-project.Sparkle", isDirectory: true)
            for sub in ["PersistentDownloads", "Installation", "Launcher"] {
                let d = sparkle.appendingPathComponent(sub, isDirectory: true)
                if let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    for u in items where age(u) > 24 * 3600 { try? fm.removeItem(at: u) }
                }
            }

            // 4) Orphaned media: durable attachments no longer referenced by any message (e.g.
            //    an unsent message), older than a day. Keeps the media cache from growing without
            //    bound while never touching anything still shown in a chat.
            if let items = try? fm.contentsOfDirectory(at: self.mediaDir,
                                                       includingPropertiesForKeys: [.contentModificationDateKey]) {
                for u in items where !inUse.contains(u.path) && age(u) > 24 * 3600 {
                    try? fm.removeItem(at: u)
                }
            }
        }
    }

    /// One-time rescue: earlier versions stored a SENT attachment's path as its temp-dir file,
    /// which macOS purges — so those images would silently disappear from history. Copy any
    /// still-present temp file into the durable media cache and repoint the message to it.
    /// Idempotent: once repointed, the temp path is no longer referenced, so this no-ops.
    private func rescueTempMedia() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.path
        let stranded = db.referencedMediaPaths().filter { $0.hasPrefix(tmp) && fm.fileExists(atPath: $0) }
        guard !stranded.isEmpty else { return }
        var remap: [String: String] = [:]
        for old in stranded {
            let src = URL(fileURLWithPath: old)
            let dest = mediaDir.appendingPathComponent("rescued-\(src.lastPathComponent)")
            if !fm.fileExists(atPath: dest.path) {
                do { try fm.copyItem(at: src, to: dest) } catch { continue }
            }
            remap[old] = dest.path
        }
        guard !remap.isEmpty else { return }
        db.remapMediaPaths(remap)
        // Update any already-loaded windows so the live view uses the durable copy too.
        for (thread, msgs) in messagesByThread {
            var arr = msgs, changed = false
            for i in arr.indices where arr[i].mediaPath != nil {
                if let np = remap[arr[i].mediaPath!] { arr[i].mediaPath = np; changed = true }
            }
            if changed { messagesByThread[thread] = arr }
        }
    }

    /// Dock badge = number of conversations with unread messages (muted ones excluded).
    private func updateBadge() {
        let n = threads.filter { $0.unread && !$0.muted }.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func loadCache() {
        if let data = try? Data(contentsOf: cacheURL),
           let c = try? JSONDecoder().decode(Cache.self, from: data) {
            threads = c.threads; contacts = c.contacts; selfID = c.selfID
            draftsByThread = c.drafts ?? [:]
            editedMessages = Set(c.edited ?? [])
            // One-time migration: if the old cache still holds messages and the DB is
            // empty, import them. Back up the old file first — the history must never be lost.
            if db.count == 0, let legacy = c.messages, !legacy.isEmpty {
                try? FileManager.default.copyItem(at: cacheURL,
                    to: cacheURL.deletingPathExtension().appendingPathExtension("premigration.bak"))
                db.bulkInsert(legacy)
            }
        }
        // Messages always come from the database now — but only the most recent slice of each
        // thread, so a huge history never floods memory or the CPU. Older messages page in on
        // demand when the user scrolls up (see loadEarlier).
        messagesByThread = db.recentByThread(perThread: windowSize)
        atLiveEdge = Set(messagesByThread.keys)   // every freshly loaded window holds the latest
    }

    /// Reset a thread back to just its recent window (after scrolling up paged older messages in,
    /// or in-chat search loaded older context). Brings the view back to the live edge.
    func reloadWindow(_ thread: String) {
        messagesByThread[thread] = db.recentMessages(thread: thread, limit: windowSize)
        atLiveEdge.insert(thread)
    }

    /// A thread's complete history straight from the DB (used by export — never windowed).
    func fullHistory(_ thread: String) -> [Message] { db.allForThread(thread) }

    /// Search all history (full-text), newest first.
    func search(_ query: String) -> [Message] { db.search(query) }

    /// Ask the backend to (re)fetch the profile for every 1:1 thread's contact, so
    /// names + fresh avatar URLs fill in on launch — including encrypted chats whose
    /// contact never arrives through the normal sync.
    private func refreshThreadContacts() {
        for t in threads where !isGroup(t) {
            let needsName = (contacts[t.contactID]?.display.isEmpty ?? true)
            let needsAvatar = (contacts[t.contactID]?.avatar.isEmpty ?? true) && t.picture.isEmpty
            if needsName || needsAvatar {
                helper.send(["cmd": "fetchContact", "id": t.contactID])
            }
            // Watch online / last-seen for encrypted 1:1 chats.
            if t.id.hasPrefix("e:") {
                helper.send(["cmd": "subscribePresence", "id": t.contactID])
            }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveCache() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func saveCache() {
        // Only thread/contact metadata lives here now — messages are written to SQLite
        // incrementally (durable + searchable). Atomic write so a crash can't corrupt it.
        let c = Cache(threads: threads, contacts: contacts, messages: nil, selfID: selfID,
                      drafts: draftsByThread.isEmpty ? nil : draftsByThread,
                      edited: editedMessages.isEmpty ? nil : Array(editedMessages))
        if let data = try? JSONEncoder().encode(c) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    func send(thread: String, text: String, replyTo: Message? = nil, mentions: [[String: Any]] = []) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var cmd: [String: Any] = ["cmd": "send", "thread": thread, "text": t]
        if let r = replyTo { cmd["replyId"] = r.id; cmd["replySender"] = r.sender }
        if !mentions.isEmpty { cmd["mentions"] = mentions }

        // Show our own bubble IMMEDIATELY for every send (both protocols), so the entrance
        // animation is tied to the tap instead of waiting on the server round-trip. E2EE has
        // no echo (the "sent" ack swaps in the real id); non-E2EE echoes back and is
        // reconciled against this optimistic copy by the message handler.
        let localID = "local-\(UUID().uuidString)"
        cmd["clientTag"] = localID   // E2EE uses it for the sent-ack; harmless otherwise
        helper.send(cmd)
        let now = Date().timeIntervalSince1970 * 1000
        var msg = Message(id: localID, thread: thread,
                          sender: selfID, text: t, ts: now, system: false)
        if let r = replyTo { msg.replyToId = r.id; msg.replyToText = r.text; msg.replyToSender = r.sender }
        // Sending snaps the view to the bottom, so make sure the window is at the live edge
        // first (it might be slid up from scrolling) — otherwise the bubble lands in a gap.
        if !atLiveEdge.contains(thread) { reloadWindow(thread) }
        atLiveEdge.insert(thread)
        withAnimation(Self.sendSpring) {
            messagesByThread[thread, default: []].append(msg)
        }
        db.upsert(msg)
        if let idx = threads.firstIndex(where: { $0.id == thread }) {
            threads[idx].snippet = t
            threads[idx].lastActivity = now
            threads[idx].readUpTo = max(threads[idx].readUpTo, now)   // sending = I've read it
            threads[idx].unread = false
            sortThreads()
        }
        scheduleSave()
    }

    /// Backfill older messages before the oldest one we currently hold for a thread. Pulls from
    /// the local DB first (instant, no CPU/network), and only asks the server once the local
    /// history is exhausted.
    func loadEarlier(_ threadID: String) {
        guard let oldest = messagesByThread[threadID]?.min(by: { $0.ts < $1.ts }) else {
            // Nothing yet — can't anchor a history request without a reference message.
            return
        }
        let older = db.earlier(thread: threadID, beforeTs: oldest.ts, limit: windowSize)
        if !older.isEmpty {
            var arr = messagesByThread[threadID] ?? []
            let have = Set(arr.map(\.id))
            arr.insert(contentsOf: older.filter { !have.contains($0.id) }, at: 0)
            arr.sort { $0.ts < $1.ts }
            // Keep the window short: once it exceeds the cap, drop the newest messages so the
            // window slides UP. The view is no longer at the live edge — scrolling back to the
            // bottom reloads the recent window (see ThreadView's bottom sentinel).
            if arr.count > maxLoaded {
                arr.removeLast(arr.count - maxLoaded)
                atLiveEdge.remove(threadID)
            }
            messagesByThread[threadID] = arr
            return
        }
        helper.send([
            "cmd": "loadEarlier", "thread": threadID,
            "oldestId": oldest.id, "oldestTs": oldest.ts, "fromMe": oldest.sender == selfID,
        ])
    }

    // MARK: in-chat search

    @Published var searchHighlight: String?   // a message id to briefly highlight after jumping

    /// Full-text search within one conversation, newest first.
    func searchInThread(_ thread: String, _ query: String) -> [Message] {
        db.searchInThread(thread, query)
    }

    /// Bring a message on screen: load a window around it (if it's outside the current one),
    /// scroll to it, and flash a highlight. Used to jump to an in-chat search hit.
    func focusMessage(_ m: Message) {
        let loaded = messagesByThread[m.thread]?.contains { $0.id == m.id } ?? false
        if !loaded {
            // Replace the window with a bounded context around the hit (keeps memory small);
            // it's no longer at the live edge, so returning to the bottom reloads the latest.
            let ctx = db.contextAround(thread: m.thread, ts: m.ts)
            if !ctx.isEmpty {
                messagesByThread[m.thread] = ctx
                atLiveEdge.remove(m.thread)
            }
        }
        scrollTarget = m.id
        withAnimation(.easeInOut(duration: 0.2)) { searchHighlight = m.id }
        let id = m.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if self.searchHighlight == id { withAnimation { self.searchHighlight = nil } }
        }
    }

    var activeThread: String?              // the conversation currently open
    @Published var stagedImages: [URL] = [] // pictures attached but not sent yet (caption + multi-send)

    /// If the clipboard holds an image, stage it on the composer (so the user can add a
    /// caption before sending). Returns true if it consumed an image (so a Cmd+V key
    /// event can be swallowed); false otherwise (so normal text paste still works).
    func pasteImageIfAvailable() -> Bool {
        guard activeThread != nil else { return false }
        let pb = NSPasteboard.general
        // A copied image file (e.g. from Finder) arrives as a file URL.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], let url = urls.first,
           ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains(url.pathExtension.lowercased()) {
            stageImage(url)
            return true
        }
        // A screenshot / copied bitmap arrives as raw image data.
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-paste-\(UUID().uuidString).png")
            if (try? png.write(to: url)) != nil {
                stageImage(url)
                return true
            }
        }
        return false
    }

    func stageImage(_ url: URL) { stageImages([url]) }

    /// Stage one or more images on the composer (so the user can add a caption and/or send
    /// several at once). Appends to any already staged.
    func stageImages(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { stagedImages.append(contentsOf: urls) }
    }

    /// Send every staged image (the first carries the caption, the rest go bare), then clear.
    func sendStaged(thread: String, caption: String) {
        let imgs = stagedImages
        guard !imgs.isEmpty else { return }
        for (i, url) in imgs.enumerated() {
            sendMedia(thread: thread, fileURL: url, caption: i == 0 ? caption : "")
        }
        stagedImages = []
    }

    /// Send a picture (optionally with a caption). Shown immediately, since encrypted
    /// sends aren't echoed back by the server.
    func sendMedia(thread: String, fileURL: URL, caption: String = "") {
        // Keep a durable copy in our media cache. Pasted images / GIFs / voice notes are
        // written to the temp dir, which macOS purges — so a sent attachment would otherwise
        // go missing from history. Persisting also lets the housekeeper safely delete the
        // temp scratch file (it's no longer referenced once we point at the durable copy).
        let path = persistOutgoingMedia(fileURL).path
        let cap = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        var cmd: [String: Any] = ["cmd": "sendMedia", "thread": thread, "path": path]
        if !cap.isEmpty { cmd["caption"] = cap }
        helper.send(cmd)

        let kind = Self.mediaKind(for: fileURL)
        let placeholder = Self.mediaPlaceholder(kind)
        let now = Date().timeIntervalSince1970 * 1000
        var msg = Message(id: "local-\(UUID().uuidString)", thread: thread,
                          sender: selfID, text: cap.isEmpty ? placeholder : cap, ts: now, system: false)
        msg.kind = kind
        msg.mediaPath = path
        if !atLiveEdge.contains(thread) { reloadWindow(thread) }   // snap to bottom before adding
        atLiveEdge.insert(thread)
        withAnimation(Self.sendSpring) {
            messagesByThread[thread, default: []].append(msg)
        }
        db.upsert(msg)
        if let idx = threads.firstIndex(where: { $0.id == thread }) {
            threads[idx].snippet = cap.isEmpty ? placeholder : cap
            threads[idx].lastActivity = now
            threads[idx].readUpTo = max(threads[idx].readUpTo, now)   // sending = I've read it
            threads[idx].unread = false
            sortThreads()
        }
        scheduleSave()
    }

    /// Send a GIF. Encrypted chats download the mp4 and send it as media (uploads it);
    /// regular chats send the GIF as an external-media link (no upload needed).
    func sendGif(thread: String, mp4URL: String, gifURL: String) {
        if thread.hasPrefix("e:") {
            guard let url = URL(string: mp4URL) else { return }
            URLSession.shared.downloadTask(with: url) { tmp, _, _ in
                guard let tmp else { return }
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("relay-gif-\(UUID().uuidString).mp4")
                try? FileManager.default.moveItem(at: tmp, to: dest)
                DispatchQueue.main.async { self.sendMedia(thread: thread, fileURL: dest) }
            }.resume()
        } else {
            helper.send(["cmd": "sendGif", "thread": thread, "url": gifURL])
        }
    }

    static func mediaKind(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp": return "image"
        case "mp4", "mov", "m4v", "webm", "avi": return "video"
        case "m4a", "mp3", "ogg", "wav", "aac", "opus", "caf": return "audio"
        default: return "file"
        }
    }
    static func mediaPlaceholder(_ kind: String) -> String {
        switch kind {
        case "image": return "📷 Photo"
        case "video": return "🎬 Video"
        case "audio": return "🎤 Voice message"
        default: return "📎 File"
        }
    }

    /// Pull the latest messages for a thread from the server (catches anything sent
    /// while the app was closed). Called when a conversation is opened.
    func refreshThread(_ id: String) {
        helper.send(["cmd": "refreshThread", "thread": id])
    }

    /// Clear a thread's unread indicator when the user opens it, and tell the server we
    /// read it (so the other side sees "Seen").
    func markRead(_ id: String) {
        // Send a read receipt for the latest message we received in this thread.
        if let last = messagesByThread[id]?.last(where: { $0.sender != selfID && !$0.system }) {
            helper.send(["cmd": "markReadServer", "thread": id, "id": last.id,
                         "sender": last.sender, "ts": last.ts])
        }
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        // Always advance the read watermark (even if already marked read) so a server
        // "thread" event that arrives late can't resurrect the unread count.
        threads[idx].unread = false
        threads[idx].readUpTo = max(threads[idx].readUpTo, Date().timeIntervalSince1970 * 1000)
        updateBadge()
        scheduleSave()
    }

    /// Conversations with unread messages (muted excluded) — dock badge + menu-bar count.
    var unreadConversationCount: Int { threads.filter { $0.unread && !$0.muted }.count }

    /// Number of unread incoming messages in a thread (drives the sidebar count badge).
    func unreadCount(_ t: ChatThread) -> Int {
        guard t.unread, !t.muted else { return 0 }
        return (messagesByThread[t.id] ?? []).filter {
            $0.ts > t.readUpTo && $0.sender != selfID && !$0.system
        }.count
    }

    // MARK: inbox management (M1)

    /// Pinned threads first, then most-recent activity.
    func sortThreads() {
        threads.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.lastActivity > b.lastActivity
        }
    }

    /// Threads in a given folder. "inbox" hides snoozed conversations; "snoozed" is a
    /// virtual folder gathering them until their timer expires.
    func threads(in folder: String) -> [ChatThread] {
        if folder == "snoozed" { return threads.filter { isSnoozed($0.id) } }
        return threads.filter { $0.folder == folder && !isSnoozed($0.id) }
    }

    /// Every visible conversation, in the exact order the sidebar lays them out — so ⌘↑/↓
    /// keyboard navigation reaches threads in Requests/Archived too, not just the inbox.
    var navigationOrder: [ChatThread] {
        ["inbox", "snoozed", "requests", "spam", "archived"].flatMap { threads(in: $0) }
    }

    // MARK: scheduled send

    /// Pending scheduled messages for a thread (soonest first) — drives the composer banner.
    func scheduledFor(_ threadID: String) -> [ScheduledMessage] {
        scheduled.filter { $0.thread == threadID }.sorted { $0.fireAt < $1.fireAt }
    }

    func scheduleSend(thread: String, text: String, at date: Date) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        scheduled.append(ScheduledMessage(id: UUID().uuidString, thread: thread, text: t,
                                          fireAt: date.timeIntervalSince1970 * 1000))
        persistScheduled()
        processScheduled()
    }

    func cancelScheduled(_ id: String) {
        scheduled.removeAll { $0.id == id }
        persistScheduled()
        armScheduleTimer()
    }

    /// Send everything that's due, then arm a timer for the next one.
    private func processScheduled() {
        let now = Date().timeIntervalSince1970 * 1000
        let due = scheduled.filter { $0.fireAt <= now }
        if !due.isEmpty {
            scheduled.removeAll { m in due.contains { $0.id == m.id } }
            persistScheduled()
            for m in due { send(thread: m.thread, text: m.text) }
        }
        armScheduleTimer()
    }

    private func armScheduleTimer() {
        scheduleTimer?.invalidate(); scheduleTimer = nil
        guard let next = scheduled.map(\.fireAt).min() else { return }
        let delay = max(0.2, (next - Date().timeIntervalSince1970 * 1000) / 1000 + 0.1)
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.processScheduled() }
        }
    }

    private func persistScheduled() {
        UserDefaults.standard.set(try? JSONEncoder().encode(scheduled), forKey: "scheduledMessages")
    }

    // MARK: snooze

    func isSnoozed(_ threadID: String) -> Bool {
        (snoozedUntil[threadID] ?? 0) > Date().timeIntervalSince1970 * 1000
    }
    func snoozeUntilLabel(_ threadID: String) -> String? {
        guard let ms = snoozedUntil[threadID], isSnoozed(threadID) else { return nil }
        return RelayFmt.snoozeLabel(ms)
    }
    func snooze(_ threadID: String, until date: Date) {
        snoozedUntil[threadID] = date.timeIntervalSince1970 * 1000
        persistSnoozed(); armSnoozeTimer()
    }
    func unsnooze(_ threadID: String) {
        snoozedUntil[threadID] = nil
        persistSnoozed(); armSnoozeTimer()
    }

    /// Drop expired snoozes (republishes → they slide back into the inbox) and re-arm for the next.
    private func armSnoozeTimer() {
        snoozeTimer?.invalidate(); snoozeTimer = nil
        let now = Date().timeIntervalSince1970 * 1000
        let expired = snoozedUntil.filter { $0.value <= now }.map(\.key)
        if !expired.isEmpty {
            for k in expired { snoozedUntil[k] = nil }
            persistSnoozed()
        }
        guard let next = snoozedUntil.values.min() else { return }
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: max(1, (next - now) / 1000 + 0.5), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.armSnoozeTimer() }
        }
    }

    private func persistSnoozed() {
        UserDefaults.standard.set(snoozedUntil, forKey: "snoozedThreads")
    }

    func loadDeferredState() {
        if let data = UserDefaults.standard.data(forKey: "scheduledMessages"),
           let s = try? JSONDecoder().decode([ScheduledMessage].self, from: data) { scheduled = s }
        if let snz = UserDefaults.standard.dictionary(forKey: "snoozedThreads") as? [String: Double] { snoozedUntil = snz }
        if let auto = UserDefaults.standard.array(forKey: "autoTranslate") as? [String] { autoTranslate = Set(auto) }
        if let st = UserDefaults.standard.array(forKey: "starredMessages") as? [String] { starred = Set(st) }
        processScheduled()   // fire anything that came due while closed
        armSnoozeTimer()
    }

    /// Mute / unmute a conversation (syncs to the server).
    func mute(_ id: String, _ muted: Bool) {
        helper.send(["cmd": "mute", "thread": id, "muted": muted])
        if let idx = threads.firstIndex(where: { $0.id == id }) {
            threads[idx].muted = muted
            updateBadge()
            scheduleSave()
        }
    }

    /// Pin / unpin a conversation to the top (local to Relay).
    func togglePin(_ id: String) {
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].pinned.toggle()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { sortThreads() }
        scheduleSave()
    }

    /// Mark a conversation unread (local — Messenger has no unread task).
    func markUnread(_ id: String) {
        guard let idx = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[idx].unread = true
        updateBadge()
        scheduleSave()
    }

    /// Delete a whole conversation (syncs to the server) and drop its local history.
    func deleteConversation(_ id: String) {
        helper.send(["cmd": "deleteThread", "thread": id])
        withAnimation(.easeInOut(duration: 0.2)) {
            threads.removeAll { $0.id == id }
            messagesByThread[id] = nil
        }
        db.deleteThread(id)
        updateBadge()
        scheduleSave()
    }

    /// Persist a thread's unsent draft text (kept across switches and restarts).
    func updateDraft(_ text: String, for thread: String) {
        let t = text.isEmpty ? nil : text
        if draftsByThread[thread] != t {
            draftsByThread[thread] = t
            scheduleSave()
        }
    }

    /// Edit the text of one of my already-sent messages.
    func editMessage(_ m: Message, newText: String) {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != m.text else { return }
        helper.send(["cmd": "edit", "thread": m.thread, "id": m.id, "text": t])
        applyEdit(id: m.id, text: t, thread: m.thread)   // optimistic
    }

    /// Apply an edit to a message wherever it lives, marking it "edited".
    private func applyEdit(id: String, text: String, thread: String?) {
        let keys = (thread.flatMap { messagesByThread[$0] != nil ? [$0] : nil }) ?? Array(messagesByThread.keys)
        for key in keys {
            guard var arr = messagesByThread[key], let idx = arr.firstIndex(where: { $0.id == id }) else { continue }
            let old = arr[idx]
            guard old.text != text || !editedMessages.contains(id) else { return }
            var m = Message(id: old.id, thread: old.thread, sender: old.sender,
                            text: text, ts: old.ts, system: old.system)
            m.kind = old.kind; m.mediaPath = old.mediaPath; m.mediaURL = old.mediaURL
            m.replyToId = old.replyToId; m.replyToText = old.replyToText; m.replyToSender = old.replyToSender
            arr[idx] = m
            withAnimation(.easeInOut(duration: 0.2)) { messagesByThread[key] = arr }
            db.upsert(m)
            editedMessages.insert(id)
            scheduleSave()
            return
        }
        editedMessages.insert(id)   // message not loaded yet — at least remember it was edited
    }

    /// Unsend (delete for everyone) one of my messages.
    func unsend(_ m: Message) {
        helper.send(["cmd": "unsend", "thread": m.thread, "id": m.id])
        if var arr = messagesByThread[m.thread], let idx = arr.firstIndex(where: { $0.id == m.id }) {
            _ = withAnimation(.easeInOut(duration: 0.2)) { arr.remove(at: idx) }
            messagesByThread[m.thread] = arr
            db.delete(id: m.id)
            scheduleSave()
        }
    }

    /// Forward a message's content to another conversation.
    func forward(_ m: Message, to thread: String) {
        if m.hasMedia, let p = m.mediaPath {
            sendMedia(thread: thread, fileURL: URL(fileURLWithPath: p), caption: m.hasMedia ? "" : m.text)
        } else if !m.text.isEmpty {
            send(thread: thread, text: m.text)
        }
    }

    /// Copy a message's text to the clipboard.
    func copyText(_ m: Message) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(m.text, forType: .string)
    }

    /// Meta often delivers a reaction as a bare scalar (e.g. ❤ U+2764) with no emoji
    /// variation selector, which renders as a thin monochrome/outline glyph. Append U+FE0F
    /// to a single emoji scalar that lacks emoji presentation so it shows as the full
    /// colour emoji (❤️, ☺️, etc.).
    static func normalizeEmoji(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count == 1, let sc = scalars.first,
              sc.properties.isEmoji, !sc.properties.isEmojiPresentation else { return s }
        return s + "\u{FE0F}"
    }

    /// Add or toggle a reaction on a message.
    func react(messageID: String, thread: String, emoji: String, fromMe: Bool) {
        let mine = reactions[messageID]?[selfID]
        let newEmoji = (mine == emoji) ? "" : emoji   // tapping the same one again removes it
        helper.send(["cmd": "react", "thread": thread, "id": messageID, "emoji": newEmoji, "fromMe": fromMe])
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if newEmoji.isEmpty { reactions[messageID]?[selfID] = nil; if reactions[messageID]?.isEmpty == true { reactions[messageID] = nil } }
            else { reactions[messageID, default: [:]][selfID] = newEmoji }
        }
    }

    /// Per-message delivery status, from the thread's read/delivered watermarks.
    func receiptStatus(for m: Message, in thread: String) -> String {
        if let r = readWatermark[thread], m.ts <= r { return "Seen" }
        if let d = deliveredWatermark[thread], m.ts <= d { return "Delivered" }
        return "Sent"
    }

    /// For the sidebar: the delivery status of MY last message in a thread (Sent/Delivered/
    /// Seen), or nil when the last message isn't mine — so a row can show a Messenger-style
    /// seen indicator only when there's an outgoing message to report on.
    func lastOutgoingStatus(_ t: ChatThread) -> String? {
        guard let last = messagesByThread[t.id]?.last, last.sender == selfID, !last.system else { return nil }
        return receiptStatus(for: last, in: t.id)
    }

    func name(for id: String) -> String {
        if id == selfID { return "You" }
        return contacts[id]?.display ?? "—"
    }

    /// The other person in a 1:1 thread (used to name/illustrate it).
    private func otherParticipantID(_ thread: String) -> String? {
        participantsByThread[thread]?.first { $0 != selfID }
    }

    func threadTitle(_ t: ChatThread) -> String {
        // A 1:1 nickname overrides everything (it's the user's chosen name for this person).
        if !isGroup(t), let nn = nickname(for: t.contactID, in: t.id) { return nn }
        // Prefer the real contact name over a thread name (which for E2EE can be
        // a junk PushName placeholder).
        if let c = contacts[t.contactID], !c.display.isEmpty { return c.display }
        if !t.name.isEmpty { return t.name }
        if let o = otherParticipantID(t.id), let c = contacts[o], !c.display.isEmpty { return c.display }
        return "Conversation"
    }

    /// Title for a thread id (used by search results, which only carry the id).
    func threadTitle(forID id: String) -> String {
        if let t = threads.first(where: { $0.id == id }) { return threadTitle(t) }
        return "Conversation"
    }

    /// Whether the 1:1 partner is currently shown as online (drives the green dot).
    func isOnline(_ t: ChatThread) -> Bool {
        guard !isGroup(t) else { return false }
        return presenceByContact[t.contactID]?.online ?? false
    }

    /// Messenger-style status line: "typing…", "Active now", "Active 5m ago", or nil.
    func statusLine(_ t: ChatThread) -> String? {
        if typingByThread[t.id] == true { return "typing…" }
        guard !isGroup(t), let p = presenceByContact[t.contactID] else { return nil }
        if p.online { return "Active now" }
        guard let ms = p.lastSeen else { return nil }
        let secs = Date().timeIntervalSince1970 - ms / 1000
        if secs < 60 { return "Active now" }
        let mins = Int(secs / 60)
        if mins < 60 { return "Active \(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "Active \(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "Active yesterday" }
        if days < 7 { return "Active \(days)d ago" }
        return nil
    }

    func threadAvatar(_ t: ChatThread) -> URL? {
        if !t.picture.isEmpty { return URL(string: t.picture) }
        if let c = contacts[t.contactID], !c.avatar.isEmpty { return URL(string: c.avatar) }
        if let o = otherParticipantID(t.id), let c = contacts[o], !c.avatar.isEmpty { return URL(string: c.avatar) }
        return nil
    }

    func avatarURL(forContact id: String) -> URL? {
        guard let s = contacts[id]?.avatar, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    func isGroup(_ t: ChatThread) -> Bool {
        if let p = participantsByThread[t.id] { return p.count > 2 }
        return !t.name.isEmpty
    }

    // MARK: group management (M4)

    func isAdmin(_ thread: String, _ contact: String) -> Bool {
        adminsByThread[thread]?.contains(contact) ?? false
    }

    /// Rename a group conversation.
    func renameGroup(_ thread: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        helper.send(["cmd": "renameThread", "thread": thread, "name": n])
        if let idx = threads.firstIndex(where: { $0.id == thread }) { threads[idx].name = n; scheduleSave() }
    }

    /// Add people (contact ids) to a group.
    func addMembers(_ thread: String, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        helper.send(["cmd": "addMembers", "thread": thread, "ids": ids])
        for id in ids { participantsByThread[thread, default: []].insert(id) }
    }

    /// Remove someone from a group.
    func removeMember(_ thread: String, _ contact: String) {
        helper.send(["cmd": "removeMember", "thread": thread, "id": contact])
        withAnimation(.easeInOut(duration: 0.2)) {
            participantsByThread[thread]?.remove(contact)
            adminsByThread[thread]?.remove(contact)
        }
    }

    /// Promote/demote a group admin.
    func setAdmin(_ thread: String, _ contact: String, _ admin: Bool) {
        helper.send(["cmd": "setAdmin", "thread": thread, "id": contact, "admin": admin])
        withAnimation(.easeInOut(duration: 0.2)) {
            if admin { adminsByThread[thread, default: []].insert(contact) }
            else { adminsByThread[thread]?.remove(contact) }
        }
    }

    /// Leave a group.
    func leaveGroup(_ thread: String) {
        helper.send(["cmd": "leaveThread", "thread": thread])
    }

    /// Set a group's photo (uploads the image, then applies it).
    func setGroupPhoto(_ thread: String, _ fileURL: URL) {
        helper.send(["cmd": "setGroupPhoto", "thread": thread, "path": fileURL.path])
    }

    /// Create a new group with the given contact ids (and optional name).
    func createGroup(name: String, ids: [String]) {
        guard !ids.isEmpty else { return }
        helper.send(["cmd": "createGroup", "name": name, "ids": ids])
    }

    /// Members of a thread, self last, each with a resolved display name.
    func members(of t: ChatThread) -> [String] {
        let ids = participantsByThread[t.id] ?? []
        return ids.sorted { a, b in
            if a == selfID { return false }
            if b == selfID { return true }
            return name(for: a).localizedCaseInsensitiveCompare(name(for: b)) == .orderedAscending
        }
    }

    /// Open a video / voice note / file in the default app (until inline players land).
    func openMediaFile(_ m: Message) {
        // Local files (decrypted E2EE media) get a Quick Look preview; remote CDN media opens
        // in the browser/default app.
        if let p = m.mediaPath {
            let url = URL(fileURLWithPath: p)
            if !QuickLook.shared.show(url) { NSWorkspace.shared.open(url) }
        } else if let s = m.mediaURL, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open a person's Facebook profile in the default browser.
    func openFacebookProfile(_ id: String) {
        guard id != selfID, !id.isEmpty,
              let url = URL(string: "https://www.facebook.com/\(id)") else { return }
        helper.send(["cmd": "fetchContact", "id": id])   // also resolve their name/pic if we lack it
        NSWorkspace.shared.open(url)
    }

    // MARK: event handling

    private func handle(_ e: [String: Any]) {
        guard let type = e["type"] as? String else { return }
        switch type {
        case "self":
            selfID = e["id"] as? String ?? ""
            status = "Loading…"
        case "ready":
            connected = true
            status = "Connected"
            refreshThreadContacts()   // fill in names/avatars for cached threads
        case "needLogin":
            // The stored session is invalid/expired — drop to the in-app login.
            needsLogin = true
            connected = false
            status = "Session expired — please sign in again"
            helper.stop()
            return
        case "error":
            status = "Error: \(e["msg"] as? String ?? "")"
        case "contact":
            guard let id = e["id"] as? String else { return }
            contacts[id] = Contact(id: id,
                                   name: e["name"] as? String ?? "",
                                   firstName: e["firstName"] as? String ?? "",
                                   avatar: e["avatar"] as? String ?? "")
        case "participant":
            guard let threadID = e["thread"] as? String, let contactID = e["contact"] as? String else { return }
            participantsByThread[threadID, default: []].insert(contactID)
            if e["admin"] as? Bool == true { adminsByThread[threadID, default: []].insert(contactID) }
        case "admin":
            guard let threadID = e["thread"] as? String, let contactID = e["contact"] as? String else { return }
            if e["admin"] as? Bool == true { adminsByThread[threadID, default: []].insert(contactID) }
            else { adminsByThread[threadID]?.remove(contactID) }
            return
        case "presence":
            guard let id = e["id"] as? String else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                presenceByContact[id] = PresenceInfo(online: e["online"] as? Bool ?? false,
                                                     lastSeen: e["lastSeen"] as? Double)
            }
            return   // no cache write needed for ephemeral status
        case "media":
            guard let thread = e["thread"] as? String, let id = e["id"] as? String else { return }
            if !applyMedia(thread: thread, id: id, info: e) {
                pendingMedia[id] = e   // message not here yet — apply when it arrives
            }
            return
        case "delete":
            // A message was unsent/deleted (by the other person or from another device).
            guard let thread = e["thread"] as? String, let id = e["id"] as? String else { return }
            if var arr = messagesByThread[thread], let idx = arr.firstIndex(where: { $0.id == id }) {
                _ = withAnimation(.easeInOut(duration: 0.2)) { arr.remove(at: idx) }
                messagesByThread[thread] = arr
                db.delete(id: id)
                scheduleSave()
            }
            return
        case "receipt":
            guard let thread = e["thread"] as? String, let ts = e["ts"] as? Double else { return }
            let status = e["status"] as? String ?? "read"
            if status == "read" {
                readWatermark[thread] = max(readWatermark[thread] ?? 0, ts)
            } else {
                deliveredWatermark[thread] = max(deliveredWatermark[thread] ?? 0, ts)
            }
            return
        case "edit":
            guard let id = e["id"] as? String, let text = e["text"] as? String, !id.isEmpty else { return }
            applyEdit(id: id, text: text, thread: e["thread"] as? String)
            return
        case "reaction":
            guard let id = e["id"] as? String, let actor = e["actor"] as? String else { return }
            let emoji = Self.normalizeEmoji(e["emoji"] as? String ?? "")
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if emoji.isEmpty { reactions[id]?[actor] = nil; if reactions[id]?.isEmpty == true { reactions[id] = nil } }
                else { reactions[id, default: [:]][actor] = emoji }
            }
            return
        case "typing":
            guard let thread = e["thread"] as? String, let id = e["id"] as? String, id != selfID else { return }
            let composing = e["composing"] as? Bool ?? false
            typingClear[thread]?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { typingByThread[thread] = composing }
            if composing {
                // Auto-clear if no "stopped typing" arrives, so it can't stick forever.
                let work = DispatchWorkItem { [weak self] in
                    withAnimation(.easeInOut(duration: 0.2)) { self?.typingByThread[thread] = false }
                }
                typingClear[thread] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
            }
            return
        case "thread":
            guard let id = e["id"] as? String, !id.isEmpty else { return }
            let contactID = (e["contact"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let name = e["name"] as? String ?? ""
            var th = ChatThread(id: id, contactID: contactID, name: name,
                                snippet: e["snippet"] as? String ?? "",
                                picture: e["picture"] as? String ?? "",
                                lastActivity: e["lastActivity"] as? Double ?? 0,
                                unread: e["unread"] as? Bool ?? false)
            th.folder = e["folder"] as? String ?? "inbox"
            th.muted = e["muted"] as? Bool ?? false
            th.readUpTo = e["readUpTo"] as? Double ?? 0
            let serverUnread = e["unread"] as? Bool ?? false
            if let idx = threads.firstIndex(where: { $0.id == id }) {
                // Don't let a later empty-name update wipe a good name; keep the local pin.
                if th.name.isEmpty { th.name = threads[idx].name }
                th.pinned = threads[idx].pinned
                // Never move our read position backwards (e.g. after a local mark-read).
                th.readUpTo = max(th.readUpTo, threads[idx].readUpTo)
            }
            // Resolve unread from OUR watermark, not the (possibly stale) server flag — else a
            // late "thread" event resurrects the count after we've read. If we're actively
            // viewing the thread, it's read and the watermark advances past the new activity.
            if activeThread == id && NSApp.isActive {
                th.readUpTo = max(th.readUpTo, th.lastActivity)
                th.unread = false
            } else {
                th.unread = serverUnread && th.lastActivity > th.readUpTo
            }
            if let idx = threads.firstIndex(where: { $0.id == id }) { threads[idx] = th }
            else { threads.append(th) }
            sortThreads()
        case "sent":
            // Helper handed back the real message id for an optimistic E2EE send: swap our
            // temporary "local-…" id for it so reactions/edits (which target the real id) match.
            guard let thread = e["thread"] as? String,
                  let tag = e["clientTag"] as? String,
                  let realID = e["id"] as? String, !realID.isEmpty, realID != tag else { return }
            if var arr = messagesByThread[thread], let idx = arr.firstIndex(where: { $0.id == tag }) {
                let old = arr[idx]
                arr[idx] = Message(id: realID, thread: old.thread, sender: old.sender, text: old.text,
                                   ts: old.ts, system: old.system, kind: old.kind, mediaPath: old.mediaPath,
                                   mediaURL: old.mediaURL, replyToId: old.replyToId,
                                   replyToText: old.replyToText, replyToSender: old.replyToSender)
                // Swap silently: the bubble is already on screen, so don't let the id change
                // re-trigger its insert/remove transition (that would flash the message).
                silentSwap = true                       // rebuild rows without re-animating
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { messagesByThread[thread] = arr }
                db.delete(id: tag); db.upsert(arr[idx])
            }
            return
        case "message":
            guard let thread = e["thread"] as? String, !thread.isEmpty else { return }
            let id = (e["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            var msg = Message(id: id,
                              thread: thread,
                              sender: e["sender"] as? String ?? "",
                              text: e["text"] as? String ?? "",
                              ts: e["ts"] as? Double ?? 0,
                              system: e["system"] as? Bool ?? false)
            // Received reply: carry the quote. The E2EE path sends only the id+author,
            // so fall back to our local copy of the quoted message for its text.
            if let rid = e["replyToId"] as? String, !rid.isEmpty {
                msg.replyToId = rid
                msg.replyToSender = e["replyToSender"] as? String
                if let rt = e["replyToText"] as? String, !rt.isEmpty {
                    msg.replyToText = rt
                } else if let ref = messagesByThread[thread]?.first(where: { $0.id == rid }) {
                    msg.replyToText = ref.text
                }
            }
            // A non-E2EE send echoes back with a real id. Replace the optimistic "local-…"
            // copy in place — matching media by kind, or text by content — so it doesn't
            // duplicate or flash. (E2EE has no echo; its id is swapped via the "sent" ack.)
            if msg.sender == selfID, !id.hasPrefix("local-"),
               var cur = messagesByThread[thread],
               let li = cur.firstIndex(where: { o in
                   o.id.hasPrefix("local-") && o.sender == selfID && !o.system &&
                   (msg.hasMedia ? o.hasMedia : (!o.hasMedia && o.text == msg.text)) }) {
                let localID = cur[li].id
                var merged = msg
                if merged.mediaPath == nil { merged.mediaPath = cur[li].mediaPath }
                cur[li] = merged
                silentSwap = true                       // rebuild rows without re-animating
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { messagesByThread[thread] = cur }
                db.delete(id: localID); db.upsert(merged)
                return
            }
            var arr = messagesByThread[thread] ?? []
            // "New" means we've never stored this message — NOT merely that it's outside the
            // short in-memory window (which only holds ~30 messages). Without the DB check, an
            // old message the server replays on reconnect looks new on every launch and
            // re-fires its notification — the stale "ghost" notification.
            let isNew = !arr.contains(msg) && !db.exists(id: id)
            if isNew {
                db.upsert(msg)   // always persist
                // Only grow the in-memory window if it's showing the latest messages. If the
                // user has scrolled up (window slid away from the live edge), skip the append
                // so we don't create a gap — the DB has it, and returning to the bottom reloads.
                let live = atLiveEdge.contains(thread) || messagesByThread[thread] == nil
                if live {
                    arr.append(msg)
                    arr.sort { $0.ts < $1.ts }
                    withAnimation(Self.sendSpring) {
                        messagesByThread[thread] = arr
                    }
                    atLiveEdge.insert(thread)
                    // Keep an auto-translated conversation translated as new messages land.
                    if autoTranslate.contains(thread), !msg.system, !msg.hasMedia {
                        requestTranslation(msg.id, msg.text)
                    }
                }
            }
            // Keep the SIDEBAR in sync with the message we just took in: bump the thread's
            // activity/snippet/unread and re-sort so it floats to the top — and CREATE the row
            // if we don't have this conversation yet. Without this, a message (especially from
            // a new contact) would fire a notification but never appear in the list, because
            // thread ordering otherwise relies on a separate "thread" event that may not arrive.
            if isNew, !msg.system {
                let looking = (activeThread == thread) && NSApp.isActive
                let mine = msg.sender == selfID
                let snippet = msg.hasMedia ? Self.mediaPlaceholder(msg.kind ?? "file") : msg.text
                if let idx = threads.firstIndex(where: { $0.id == thread }) {
                    threads[idx].lastActivity = max(threads[idx].lastActivity, msg.ts)
                    if !snippet.isEmpty { threads[idx].snippet = snippet }
                    if mine || looking {
                        threads[idx].readUpTo = max(threads[idx].readUpTo, msg.ts)
                        threads[idx].unread = false
                    } else if msg.ts > threads[idx].readUpTo {
                        // Only past our read watermark — so backfill of an already-read
                        // message can't resurrect the unread dot.
                        threads[idx].unread = true
                    }
                    sortThreads()
                } else if !mine {
                    // A conversation we have no row for yet (a brand-new chat). Add a minimal
                    // row so it surfaces immediately, then ask the helper for its real
                    // name / avatar / folder.
                    let th = ChatThread(id: thread, contactID: msg.sender, name: "",
                                        snippet: snippet, picture: "",
                                        lastActivity: msg.ts, unread: !looking)
                    threads.append(th)
                    sortThreads()
                    refreshThread(thread)
                    refreshThreadContacts()
                }
            }
            // A genuinely new incoming message: if we're looking at this thread, auto-mark it
            // read (so it never accrues an unread count + the sender sees "Seen"); otherwise
            // notify (unless muted).
            if isNew, msg.sender != selfID, !msg.system, (e["live"] as? Bool ?? false) {
                // They just sent — drop the typing bubble immediately (no animation) so it
                // doesn't sit under the arriving message and stutter the insertion.
                typingClear[thread]?.cancel()
                if typingByThread[thread] == true { typingByThread[thread] = false }
                let looking = (activeThread == thread) && NSApp.isActive
                let muted = threads.first(where: { $0.id == thread })?.muted ?? false
                if looking { markRead(thread) }
                else if !muted { notify(threadID: thread, sender: msg.sender, body: msg.text) }
            }
            // Apply any media that arrived before this message did.
            if let info = pendingMedia.removeValue(forKey: id) {
                _ = applyMedia(thread: thread, id: id, info: info)
            }
        default:
            break
        }
        updateBadge()
        scheduleSave()
    }

    /// Attach downloaded/url media to an existing message. Returns false if the
    /// message isn't present yet (so the caller can stash it for later).
    @discardableResult
    private func applyMedia(thread: String, id: String, info: [String: Any]) -> Bool {
        guard var arr = messagesByThread[thread],
              let idx = arr.firstIndex(where: { $0.id == id }) else { return false }
        var m = arr[idx]
        m.kind = info["kind"] as? String
        if let p = info["path"] as? String { m.mediaPath = p }
        if let u = info["url"] as? String { m.mediaURL = u }
        arr[idx] = m
        withAnimation(.easeInOut(duration: 0.25)) { messagesByThread[thread] = arr }
        db.upsert(m)
        scheduleSave()
        return true
    }
}

// MARK: - Helper process

/// Spawns the Go `relay-helper` daemon and speaks line-delimited JSON to it.
final class HelperClient {
    var onEvent: (([String: Any]) -> Void)?
    var onStatus: ((String) -> Void)?

    private var proc: Process?
    private var stdinPipe = Pipe()
    private var stdoutPipe = Pipe()
    private var buffer = Data()

    /// Launch the helper and log in with the given session cookies. Any running
    /// helper is stopped first, so this doubles as "reconnect with a new session".
    func start(cookies: String) {
        stop()
        guard let binary = Self.helperURL() else {
            DispatchQueue.main.async { self.onStatus?("relay-helper binary not found") }
            return
        }
        let p = Process()
        stdinPipe = Pipe(); stdoutPipe = Pipe(); buffer = Data()
        p.executableURL = binary
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        // Helper logs → a file we can inspect (stderr is invisible when launched from Finder).
        let logURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay", isDirectory: true)
            .appendingPathComponent("helper.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            p.standardError = logHandle
        } else {
            p.standardError = FileHandle.standardError
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }

        do {
            try p.run()
        } catch {
            DispatchQueue.main.async { self.onStatus?("failed to launch helper: \(error.localizedDescription)") }
            return
        }
        proc = p
        send(["cmd": "login", "cookies": cookies])
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        proc?.terminate()
        proc = nil
    }

    func send(_ obj: [String: Any]) {
        guard proc != nil, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var line = data
        line.append(0x0A)
        stdinPipe.fileHandleForWriting.write(line)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            DispatchQueue.main.async { self.onEvent?(obj) }
        }
    }

    // Release: the helper is bundled in Resources. Dev: set RELAY_HELPER to a freshly
    // built ./relay-helper/relay-helper to run the app without re-bundling each time.
    private static func helperURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "relay-helper", withExtension: nil) {
            return bundled
        }
        if let p = ProcessInfo.processInfo.environment["RELAY_HELPER"],
           FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }
}

// MARK: - Notification handling (inline reply + tap-to-open)

/// Handles the macOS notification banner: typing in the inline "Reply" field sends straight
/// through the live session; tapping the banner opens that conversation.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    // Still show banners while Relay is frontmost (for a chat you're not currently viewing).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard let threadID = info["threadID"] as? String else { completionHandler(); return }
        if let reply = response as? UNTextInputNotificationResponse {
            let text = reply.userText
            Task { @MainActor in
                RelayStore.shared.ensureStarted()
                _ = await RelayStore.shared.waitUntilConnected(timeout: 8)
                RelayStore.shared.send(thread: threadID, text: text)
            }
        } else {
            Task { @MainActor in
                RelayStore.shared.ensureStarted()
                RelayStore.shared.pendingOpen = threadID
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }
}

// MARK: - Color <-> hex (for persisting per-chat accent colors)

extension Color {
    /// Parse "#RRGGBB" / "RRGGBB" (alpha ignored). Returns nil on a malformed string.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red:   Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue:  Double(v & 0xFF) / 255)
    }

    /// "#RRGGBB" for storage. Resolves through NSColor so any Color (incl. dynamic) works.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
