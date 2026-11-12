#if os(iOS)
import Foundation
import Observation
import OSLog

/// Realtime voice in the meeting (#3862 phase 4, docs/assistant/meeting-minutes.md「Phase 4: realtime voice in the
/// meeting」; the phone's side docs/apple/recording.md「Realtime voice (phase 4)」): the meeting call and Talk.
///
/// **The call.** While this phone records a room meeting Persona takes part in, whose room is `ready`, and the hub's voice
/// extension lists `meeting` (`MeetingCallRule.wanted`), a protocol 2 call runs in meeting mode, bound to the room
/// (`VoiceConversation` with `VoiceMeeting`), on the recorder's capture (`MeetingCallAudio`): it never claims the
/// microphone, keeps no screen on, never ends after idle minutes, and pauses with the recording (its socket stays). It
/// reconnects as protocol 2 does, then every 30 seconds while the meeting records; a call that ended by itself starts
/// again 30 seconds later unless the end says it never can (`MeetingCallRule.retries`). It ends with Stop or another role.
///
/// **Talk.** Held on the page, or a window the Lock Screen opens (`MeetingTalkWindow`). With the call live a span is a
/// `talk on` … `talk off` pair, and between them the recorder's audio goes up (`VoiceUplink.talk`); otherwise (a listener,
/// no `meeting`, the call down) the segment is cut at the span's start and end, transcribed on the phone, and asked with
/// `…/ask` (`spoken: true`), answered as any ask (aloud for a participant, `MeetingSpeaker`).
///
/// **Echo.** Every stretch the call's voice plays in, half a second wider each side, is Persona's
/// (`RecordingAttendance.spoken`): a sentence at least half inside one leaves the transcript and the live log.
@MainActor @Observable final class MeetingCall {
    static let shared = MeetingCall()

    /// The meeting call of the recording being made, live, connecting or reconnecting; nil without one.
    private(set) var call: VoiceConversation?
    /// The recording the call belongs to.
    private(set) var callRecording: UUID?
    /// The Talk span being held or a talk window, nil when none is open.
    private(set) var talk: Talk?
    /// A word under Talk after a span, for a moment.
    private(set) var note: Note?
    /// The owner has held Talk while it sent to the voice service once: the first-use note about it stops
    /// (`MeetingTalkPrivacy`). Read from the defaults once, at the start.
    private(set) var privacySeen = false

    nonisolated struct Talk: Equatable, Sendable {
        var id = UUID()
        var recording: UUID
        /// A talk window (the Lock Screen's tap), not a hold.
        var window: Bool
        /// It goes to the meeting call (else it is asked without one).
        var viaCall: Bool
        /// Where it began on the recording's clock.
        var start: Double
        var opened: Date
    }

    nonisolated enum Note: Equatable, Sendable {
        /// Asked without the call, and the transcript holds no words for the span.
        case nothingHeard
        /// Let go almost at once: Talk is held while speaking.
        case holdLonger
    }

    /// A span shorter than this was a tap, not a hold.
    static let shortestHold: TimeInterval = 0.5
    /// How often a talk window looks at the microphone's level.
    static let windowTick: Duration = .milliseconds(100)
    /// How long a note stays under Talk.
    static let noteShown: Duration = .seconds(4)
    /// The longest one stretch of the call's voice counts for (as `MeetingSpeaker.longestAnswer`).
    static let longestVoice: Double = 150

    @ObservationIgnored private let tap = MeetingTalkTap()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var window: MeetingTalkWindow?
    @ObservationIgnored private var windowTask: Task<Void, Never>?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    /// A call that ended by itself: the next may start then (`VoiceMeeting.retryEvery` later), or never for this recording.
    @ObservationIgnored private var retry: (recording: UUID, at: Date?)?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// When the hub's voice extension was last asked whether it takes meeting calls, per group.
    @ObservationIgnored private var probed: [String: Date] = [:]
    /// Where the call's voice began playing on the recording's clock, while it plays.
    @ObservationIgnored private var voiceStart: (recording: UUID, at: Double)?
    private let log = Logger(subsystem: "persona", category: "meeting-call")

    private var capture: RecordingCapture { .shared }
    private var library: RecordingLibrary { .shared }

    #if DEBUG
    /// The made-up room meetings (`-showMeetingSample room-…`): the first-use note shows again, for the screenshots.
    func forgetPrivacyNote() {
        privacySeen = false
        UserDefaults.standard.removeObject(forKey: MeetingTalkPrivacy.seenKey)
    }
    #endif

    /// From `MeetingRecorder.start()` at launch.
    func start() {
        guard !started else { return }
        started = true
        privacySeen = MeetingTalkPrivacy.isSeen
        observe()
    }

    private func observe() {
        withObservationTracking { sync() } onChange: {
            Task { @MainActor in MeetingCall.shared.observe() }
        }
    }

    // MARK: What the page and the Live Activity ask

    /// Talk is offered for `entry` now: a room meeting Persona can be asked in, recording (not paused) on this phone.
    func canTalk(_ entry: RecordingEntry) -> Bool {
        capture.recordingID == entry.id && capture.state == .recording
            && MeetingCallRule.talkOffered(entry, roomMissing: RecordingSync.shared.roomMissing.contains(entry.id))
    }

    /// The recording's meeting call is up: Talk and typed questions go to it.
    func isLive(_ recording: UUID) -> Bool { callRecording == recording && call?.connected == true }

    /// The recording's call, live or on its way up, for the page's line.
    func call(for recording: UUID) -> VoiceConversation? { callRecording == recording ? call : nil }

    /// The privacy texts' rule (`MeetingCallRule.talkSendsAudio`) for the group's hub now.
    func voiceExtension(group: String) -> String? {
        VoiceSupport.shared.probes[group].flatMap { MeetingCallRule.extensionID(extensions: $0.extensions, info: $0.info) }
    }

    /// A typed question while the call is live: a `text` frame (the fast layer hands it to the room and says the
    /// answer). False when the call isn't live: the caller asks through `…/ask`.
    @discardableResult func say(_ text: String, recording: UUID) -> Bool {
        guard isLive(recording), let call, MeetingAsk.hasWords(text) else { return false }
        call.say(String(String.UnicodeScalarView(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(MeetingAsk.maxQuestion))))
        return true
    }

    /// Stops what the call's voice says (never the room's work).
    func interruptVoice(_ recording: UUID) {
        guard callRecording == recording else { return }
        call?.interruptSpeech()
    }

    /// The stretch the call's voice is playing in now, half a second wider: a sentence transcribed meanwhile is checked
    /// against it (`MeetingLive`, the upload).
    func openSpan(for recording: UUID) -> RecordingSpan? {
        guard let voiceStart, voiceStart.recording == recording else { return nil }
        let end = min(max(capture.timeline, voiceStart.at), voiceStart.at + Self.longestVoice)
        return RecordingSpan(start: voiceStart.at, end: end).widened()
    }

    // MARK: Talk

    /// Opens a Talk span (`window`: the Lock Screen's tap, else a hold on the page): to the call when it is live, else
    /// for a question asked without it. False when Talk isn't offered now, or a span is already open.
    @discardableResult func beginTalk(_ recording: UUID, window: Bool) -> Bool {
        guard talk == nil, let entry = library.entry(recording), canTalk(entry) else { return false }
        let at = capture.timeline
        // What Persona is saying gives way: the owner speaks now.
        if isLive(recording), call?.speaking == true { call?.interruptSpeech() }
        MeetingSpeaker.shared.stop()
        let viaCall = isLive(recording) && call?.talk(true) == true
        // Without the call, the span's words are a segment of their own, transcribed as soon as it ends.
        if !viaCall { capture.flushSegment() }
        talk = Talk(recording: recording, window: window, viaCall: viaCall, start: at, opened: .now)
        showNote(nil)
        if viaCall, !privacySeen {
            privacySeen = true
            MeetingTalkPrivacy.seen()
        }
        if window { openWindow() }
        log.info("talk: \(window ? "window" : "hold", privacy: .public) opened, \(viaCall ? "to the call" : "asked without it", privacy: .public)")
        return true
    }

    /// Closes the open span (the hold let go, the window's end). `ask: false` drops one asked without the call (the
    /// recording stopped or paused under it).
    func endTalk(ask: Bool = true) {
        guard let talk else { return }
        self.talk = nil
        windowTask?.cancel()
        windowTask = nil
        window = nil
        let end = capture.timeline
        let short = !talk.window && Date.now.timeIntervalSince(talk.opened) < Self.shortestHold
        if talk.viaCall {
            // The call may have dropped meanwhile: its span went with the socket then.
            if callRecording == talk.recording { call?.talk(false) }
        } else {
            capture.flushSegment()
            if ask, !short { Task { await askWithout(talk, end: end) } }
        }
        if short { showNote(.holdLonger) }
    }

    /// The Lock Screen's and the island's Talk (`TalkInMeetingIntent`): a tap opens a talk window, another ends it.
    func toggleWindow(_ recording: UUID) {
        if let talk, talk.recording == recording {
            if talk.window { endTalk() }
            return
        }
        beginTalk(recording, window: true)
    }

    private func openWindow() {
        window = MeetingTalkWindow(opened: .now)
        windowTask?.cancel()
        windowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.windowTick)
                guard let self, !Task.isCancelled, var window = self.window else { return }
                let end = window.heard(self.tap.level, at: .now)
                self.window = window
                if let end {
                    self.log.info("talk: window ended (\(String(describing: end), privacy: .public))")
                    self.endTalk()
                    return
                }
            }
        }
    }

    /// A span asked without the call: once its segment has its text, the words said in it go as a spoken question.
    private func askWithout(_ talk: Talk, end: Double) async {
        let span = RecordingSpan(start: talk.start, end: max(end, talk.start))
        #if DEBUG
        RecordingSamples.transcribeTalkSample(talk.recording, span: span)
        #endif
        for _ in 0..<60 {
            guard let entry = library.entry(talk.recording) else { return }
            if MeetingTalkWords.transcribed(entry.segments, span: span) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let entry = library.entry(talk.recording) else { return }
        guard let words = MeetingTalkWords.question(entry.segments, span: span) else {
            showNote(.nothingHeard)
            return
        }
        MeetingAsk.shared.ask(entry, text: words, spoken: true)
    }

    private func showNote(_ next: Note?) {
        noteTask?.cancel()
        noteTask = nil
        if note != next { note = next }
        guard next != nil else { return }
        noteTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.noteShown)) != nil, let self else { return }
            self.note = nil
        }
    }

    /// The recording is stopping (`RecordingCapture.onStopping`): the span closes unasked, the voice's stretch is kept, the
    /// call ends and the tap goes.
    func ended(_ recording: UUID) {
        if talk?.recording == recording { endTalk(ask: false) }
        played(false, recording: recording)
        if callRecording == recording { endCall() }
        if retry?.recording == recording { retry = nil; retryTask?.cancel(); retryTask = nil }
        if listening {
            capture.listen(nil)
            listening = false
        }
    }

    // MARK: Following the meeting

    /// Brings the call and the tap in step with the recording, its role and room, and the hub's voice extension.
    private func sync() {
        let state = capture.state
        let recording = state == .recording || state == .paused
        let id = recording ? capture.recordingID : nil
        let entry = id.flatMap { library.entry($0) }
        // The tap listens while a room meeting records (the call's spans, the window's silence).
        let listens = entry?.roomMeeting == true && entry?.active == true
        if listens != listening {
            listening = listens
            let tap = tap
            capture.listen(listens ? { @Sendable buffer in tap.feed(buffer) } : nil)
        }
        if let talk, talk.recording != id || state != .recording || entry.map(canTalk) != true {
            // Paused, stopped, the role off: what was said up to here is still asked (never after a stop: `ended`).
            endTalk(ask: talk.recording == id)
        }
        guard let id, let entry else { return endCall() }
        let roomMissing = RecordingSync.shared.roomMissing.contains(id)
        let room = MeetingConversation.shared.meeting(id).room
        let key = MeetingConversation.shared.roomKey(id)
        let voice = key.flatMap { voiceExtension(group: $0.group) }
        let candidate = MeetingCallRule.wanted(entry, roomMissing: roomMissing, room: room) && key != nil
        if candidate, voice == nil, let key { probe(key.group) }
        let wanted = candidate && voice != nil
        if retry.map({ $0.recording != id }) == true { retry = nil }
        if let call {
            if !wanted || call.key != key || callRecording != id {
                endCall()
            } else if case .ended(let why) = call.phase {
                log.notice("meeting call ended: \(String(describing: why), privacy: .public)")
                self.call = nil
                callRecording = nil
                played(false, recording: id)
                retry = (id, MeetingCallRule.retries(after: why) ? Date.now.addingTimeInterval(Self.seconds(VoiceMeeting.retryEvery)) : nil)
            } else {
                return
            }
        }
        guard wanted, let key, let voice, call == nil else { return }
        if let retry, retry.recording == id {
            guard let at = retry.at else { return }
            guard at <= .now else { return wake(at: at) }
        }
        begin(key: key, extensionID: voice, recording: id)
    }

    private func begin(key: SessionKey, extensionID: String, recording: UUID) {
        retry = nil
        retryTask?.cancel()
        retryTask = nil
        let audio = MeetingCallAudio(capture: capture, tap: tap) { [weak self] on in self?.played(on, recording: recording) }
        var deps = VoiceDeps.live(group: key.group)
        deps.audio = { audio }
        let call = VoiceConversation(key: key, extensionID: extensionID, surface: .phone, meeting: VoiceMeeting(recordingID: recording),
                                     deps: deps)
        self.call = call
        callRecording = recording
        log.info("meeting call: starting (echo cancellation \(self.capture.cancelsEcho, privacy: .public))")
        Task { await call.begin() }
    }

    private func endCall() {
        guard let call else { return }
        if let talk, talk.viaCall { endTalk() }
        if let id = callRecording { played(false, recording: id) }
        self.call = nil
        callRecording = nil
        call.end(.left)
    }

    /// Looks again once a call may start after the wait.
    private func wake(at date: Date) {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            self.sync()
        }
    }

    /// Asks the group's hub whether its voice extension takes meeting calls, at most once a minute.
    private func probe(_ group: String) {
        if let at = probed[group], Date.now.timeIntervalSince(at) < VoiceSupport.ttl { return }
        probed[group] = .now
        guard let api = AppModel.shared.api(group) else { return }
        Task { await VoiceSupport.shared.refresh(group: group, api: api) }
    }

    // MARK: Echo

    /// The call's voice began (`true`) or stopped playing: the stretch it took, half a second wider each side, is
    /// Persona's on the recording.
    private func played(_ on: Bool, recording: UUID) {
        if on {
            if voiceStart == nil { voiceStart = (recording, capture.timeline) }
            return
        }
        guard let span = openSpan(for: recording) else { return }
        voiceStart = nil
        library.change(recording) { $0.attendance?.spoken.append(span) }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Whether the owner has been told what Talk sends (#3862 phase 4, the contract's「Wording」): the first-use note under
/// Talk shows until the first span that went to the voice service. Written once.
nonisolated enum MeetingTalkPrivacy {
    static let seenKey = "recording.meeting.talkPrivacySeen"

    static var isSeen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    static func seen() {
        guard !isSeen else { return }
        UserDefaults.standard.set(true, forKey: seenKey)
    }
}
#endif
