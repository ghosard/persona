#if os(iOS)
import Foundation

// The pure rules of Talk and the meeting call (#3862 phase 4, docs/assistant/meeting-minutes.md「Phase 4: realtime voice in
// the meeting」; the phone's side docs/apple/recording.md「Realtime voice (phase 4)」): who has a call, when Talk is
// offered, when a call that ended starts again, the Lock Screen's talk window, the words of a span asked without a call,
// and Persona's voice kept out of the transcript. `MeetingCall` acts on them; the tests read them directly.

/// Who has a meeting call, and where Talk is.
nonisolated enum MeetingCallRule {
    /// The hub's voice extension that takes meeting calls (`meeting` in its `/info` features, protocol 2, set up), from
    /// what `VoiceSupport` last heard; nil without one (none, an older extension, one that needs setup, not asked yet).
    static func extensionID(extensions: [HubExtension]?, info: VoiceInfoState?) -> String? {
        guard let extensions, let voice = VoiceAvailability.pick(extensions), case .info(let i)? = info,
              i.protocolVersion >= 2, i.setup.isEmpty, i.features.contains(VoiceMeeting.feature) else { return nil }
        return voice.id
    }

    /// The hub said for sure that it takes no meeting calls: it lists no voice extension, or the one it runs answered
    /// `/info` without `meeting` (from before phase 4, an older protocol, not set up), or `404` / `403`. An ask that
    /// failed, or a voice extension that isn't running at that moment (restarting, an upgrade), says nothing either way:
    /// a running call stays then (its own `ready` and close decide), and the phone asks again later (`probeAgain`).
    static func declines(extensions: [HubExtension]?, info: VoiceInfoState?) -> Bool {
        guard let extensions else { return false }
        guard extensions.contains(where: { $0.kind == "voice" }) else { return true }
        switch info {
        case .info?: return extensionID(extensions: extensions, info: info) == nil
        case .missing?, .forbidden?: return true
        case .failed?, nil: return false
        }
    }

    /// How long after the `tries`-th ask (from 1) whether the hub takes meeting calls the phone asks again, while a meeting
    /// that wants a call has none (P9: never once a minute for hours with the screen locked): not again once the hub
    /// answered either way (`extensionID`, `declines`), else after 30 seconds, 2 minutes and 5 minutes, then no more for
    /// this recording. Whatever else asks meanwhile (a spoken answer's route, a chat's voice button) is heard too.
    static func probeAgain(extensions: [HubExtension]?, info: VoiceInfoState?, tries: Int) -> TimeInterval? {
        guard extensionID(extensions: extensions, info: info) == nil, !declines(extensions: extensions, info: info),
              tries >= 1, tries <= probeRetries.count else { return nil }
        return probeRetries[tries - 1]
    }

    static let probeRetries: [TimeInterval] = [30, 120, 300]

    /// Whether a Talk span goes to the live meeting call (else it is asked without one, through `…/ask`). One the Lock
    /// Screen or the island opened goes only once the owner has been told what Talk sends (`MeetingTalkPrivacy`): those
    /// surfaces don't show the Wording, the meeting page does (under Talk, and in its spoken hint).
    static func toCall(live: Bool, source: MeetingTalkSource, privacySeen: Bool) -> Bool {
        live && (source != .activity || privacySeen)
    }

    /// What a tap on the Live Activity's Talk or Done does: the action the button showed (`open`), checked against what is
    /// open now. Talk opens a window only when no span is open, Done ends whatever span is (a window, or a hold the page
    /// lost); a tap that no longer matches (a Done tapped just after the window closed itself on silence, before the Lock
    /// Screen drew Talk again) does nothing, so it can never open a window that streams the room. `open` nil (an activity
    /// drawn before the button said which): a toggle, as it was.
    static func activityTap(open: Bool?, spanOpen: Bool) -> MeetingActivityTap {
        switch open {
        case true?: spanOpen ? .ignore : .open
        case false?: spanOpen ? .close : .ignore
        case nil: spanOpen ? .close : .open
        }
    }

    /// Talk is offered on the meeting page and on the Lock Screen: a room meeting this phone records that Persona can be
    /// asked in (`MeetingAsk.canAsk`: it attends, as listener or participant, and the hub took the room). With a call it
    /// goes to the call, otherwise it is asked through `…/ask`, transcribed on the phone.
    static func talkOffered(_ entry: RecordingEntry, roomMissing: Bool) -> Bool {
        entry.active && entry.roomMeeting && MeetingAsk.canAsk(entry, roomMissing: roomMissing)
    }

    /// The meeting being recorded wants a call: a room meeting Persona takes part in (`participant`, from the start or a
    /// later change), the hub took the room, and it is `ready` with its ids. It has one when the voice extension takes
    /// meeting calls too (`extensionID`). A listener, a room not up yet or gone, an older manager or no such extension:
    /// Talk without a call.
    static func wanted(_ entry: RecordingEntry, roomMissing: Bool, room: MeetingRoom?) -> Bool {
        guard talkOffered(entry, roomMissing: roomMissing), entry.attendance?.sentRole == .participant,
              let room, room.known == .ready, room.key(group: "") != nil else { return false }
        return true
    }

    /// Where Talk sends audio to the voice service, the privacy texts say so (the contract's「Wording」): a participant room
    /// meeting on a hub whose voice extension takes meeting calls. Elsewhere the audio stays on the phone.
    static func talkSendsAudio(conversation: Bool, role: MeetingAttendance, voice: String?) -> Bool {
        conversation && role == .participant && voice != nil
    }

    /// A meeting call that ended by itself starts again `VoiceMeeting.retryEvery` later while the meeting wants one, unless
    /// the end says it never can (the hub refused this device, the extension can't take meeting calls, the model can't be
    /// used, no hub): those wait for the next meeting.
    static func retries(after end: VoiceEnd) -> Bool {
        switch end {
        case .rejected(let status): status != 401 && status != 403
        case .incompatible, .modelUnavailable, .noHub: false
        case .user, .left, .replaced: false
        default: true
        }
    }
}

/// Where a Talk span was opened (#3862 phase 4).
nonisolated enum MeetingTalkSource: Equatable, Sendable {
    /// Held on the meeting page.
    case hold
    /// VoiceOver's double tap on the page's Talk (it can't hold): a talk window, its hint saying where the words go.
    case pageWindow
    /// The Live Activity's Talk, on the Lock Screen or in the island: a talk window.
    case activity
}

/// What a tap on the Live Activity's Talk / Done does (`MeetingCallRule.activityTap`).
nonisolated enum MeetingActivityTap: Equatable, Sendable { case open, close, ignore }

/// The Lock Screen's and the island's talk window (#3862 phase 4): their buttons can't be held, so a tap opens it, and it
/// ends on another tap, 2 seconds of silence after speech, 20 seconds without speech, or 60 seconds in all. Pure: the
/// caller hands in the microphone's level and the time.
nonisolated struct MeetingTalkWindow: Equatable, Sendable {
    nonisolated enum End: Equatable, Sendable {
        /// Another tap.
        case tapped
        /// 2 seconds of silence after speech.
        case silence
        /// 20 seconds without speech.
        case noSpeech
        /// 60 seconds.
        case limit
    }

    static let silenceAfterSpeech: TimeInterval = 2
    static let noSpeechLimit: TimeInterval = 20
    static let limit: TimeInterval = 60
    /// A buffer at or above this level (dBFS of the 16 kHz audio) is speech; a quiet room is well below it.
    static let speechLevel: Float = -40

    let opened: Date
    /// When speech was last heard; nil before any.
    private(set) var lastSpeech: Date?
    private(set) var ended: End?

    init(opened: Date) {
        self.opened = opened
    }

    var heardSpeech: Bool { lastSpeech != nil }

    /// The microphone's level `db` at `now`, then whether the window closes (and why). Nothing once it ended.
    mutating func heard(_ db: Float, at now: Date) -> End? {
        guard ended == nil else { return nil }
        if db >= Self.speechLevel { lastSpeech = now }
        return tick(now)
    }

    /// Whether the window closes by `now`, by time alone.
    mutating func tick(_ now: Date) -> End? {
        guard ended == nil else { return nil }
        let end: End? = if now.timeIntervalSince(opened) >= Self.limit {
            .limit
        } else if let lastSpeech {
            now.timeIntervalSince(lastSpeech) >= Self.silenceAfterSpeech ? .silence : nil
        } else {
            now.timeIntervalSince(opened) >= Self.noSpeechLimit ? .noSpeech : nil
        }
        ended = end
        return end
    }

    /// Another tap: it ends now.
    mutating func tap() -> End? {
        guard ended == nil else { return nil }
        ended = .tapped
        return .tapped
    }
}

/// Talk without a call (#3862 phase 4): the phone cuts its segment at the span's start and end, transcribes it on
/// device, and asks with those words (`…/ask`, `spoken: true`).
nonisolated enum MeetingTalkWords {
    /// What was said in the span: the transcript's sentences at least half inside it, in order, joined with a space;
    /// nil when it holds none with words.
    static func question(_ segments: [RecordingSegment], span: RecordingSpan) -> String? {
        let lines = segments.sorted { $0.index < $1.index }.flatMap { $0.sentences ?? [] }
            .filter { span.holds($0) }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let words = lines.joined(separator: " ")
        return String(String.UnicodeScalarView(words.unicodeScalars.prefix(MeetingAsk.maxQuestion)))
    }

    /// Every segment of the span has its text (or the recording has nothing more to transcribe).
    static func transcribed(_ segments: [RecordingSegment], span: RecordingSpan) -> Bool {
        !segments.contains { $0.sentences == nil && $0.start < span.end && $0.start + $0.duration > span.start }
    }
}

nonisolated extension RecordingSpan {
    /// How much wider than its audio a stretch Persona spoke in counts (the contract's「plus half a second」): the
    /// microphone hears the room's echo of the voice a moment after it ends, and the sentence a transcription cuts out of it
    /// can begin a moment before.
    static let echoMargin: Double = 0.5

    /// The stretch `margin` wider on each side (never before 0).
    func widened(by margin: Double = RecordingSpan.echoMargin) -> RecordingSpan {
        RecordingSpan(start: max(0, start - margin), end: end + margin)
    }
}
#endif
