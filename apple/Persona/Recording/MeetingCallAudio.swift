#if os(iOS)
import AVFoundation
import Foundation
import os

// A meeting call's audio on the recorder's capture (#3862 phase 4, docs/assistant/meeting-minutes.md「One capture」): the
// recording keeps the microphone for the whole meeting and the call never claims it. The recorder's one input tap, already
// at 16 kHz, feeds the segment writer and, through `MeetingTalkTap`, the call's uplink, which sends only inside Talk
// spans (`VoiceUplink.talk`). The call's voice plays through the player on the recorder's own engine
// (`RecordingCapture.callPlayer`), so the system's echo cancellation, when the recording asked for it, takes it out of
// what the microphone records.

/// The recorder's audio as Talk hears it (#3862 phase 4): every buffer of the tap (16 kHz mono float) goes to the meeting
/// call's uplink as PCM16, when there is a call, and its loudness is kept for the talk window's silence. Called on the
/// audio thread; the main actor connects and reads it.
nonisolated final class MeetingTalkTap: @unchecked Sendable {
    private let lock = NSLock()
    private var uplink: VoiceUplink?
    private var db: Float = MeetingTalkTap.quiet

    /// The level of no sound at all.
    static let quiet: Float = -160

    /// The call's uplink, or nil when the call goes (its audio then goes nowhere).
    func connect(_ uplink: VoiceUplink?) {
        lock.withLock { self.uplink = uplink }
    }

    /// The newest buffer's level, dBFS.
    var level: Float { lock.withLock { db } }

    /// One buffer of the recording's audio, as the tap converted it.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        let level = Self.level(samples)
        let uplink = lock.withLock { () -> VoiceUplink? in
            db = level
            return self.uplink
        }
        // Converted only for a span (the uplink checks again under its own lock, and resamples it to the call's rate).
        guard let uplink, uplink.isTalking else { return }
        uplink.push(Self.pcm16(samples), rate: Int(buffer.format.sampleRate))
    }

    /// Float samples in [-1, 1] as little-endian PCM16, clipped.
    static func pcm16(_ samples: UnsafeBufferPointer<Float>) -> Data {
        var out = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            out[i] = Int16(max(-32768, min(32767, (samples[i] * 32767).rounded())))
        }
        return VoicePCM.data(out)
    }

    /// Root mean square in dBFS (`quiet` for silence).
    static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return quiet }
        var sum: Float = 0
        for x in samples { sum += x * x }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 0 ? max(quiet, 20 * log10(rms)) : quiet
    }
}

/// `VoiceAudio` on the recorder (#3862 phase 4). Starting it connects the call's uplink to the tap; the voice goes to the
/// recorder's player through the same jitter buffer as a phone call's (`VoicePlayout`); stopping it lets go of both and
/// leaves the recording as it was. A made-up recording (`-showMeetingSample`) has no player: the voice then "plays" for
/// as long as its PCM lasts, as `VoiceSample.SilentAudio` does, so the call and the echo spans follow it.
@MainActor final class MeetingCallAudio: VoiceAudio {
    nonisolated static let log = Logger(subsystem: "persona", category: "meeting-call")

    private let capture: RecordingCapture
    private let tap: MeetingTalkTap
    /// The voice began (true) or stopped (false) playing: the stretch the microphone may hear it in (`MeetingCall`).
    private let onPlaying: @MainActor (Bool) -> Void
    private var events: (@MainActor (VoiceAudioEvent) -> Void)?
    private var format = VoiceAudioFormat.provisional
    private var playout = VoicePlayout<Piece>(rate: VoiceFrame.defaultOutputRate)
    private var holdTimer: Task<Void, Never>?
    /// The loudness of each piece still queued, the first one playing.
    private var queued: [Float] = []
    /// Bumped by `clear` and `stop`: completions of what was scheduled before are ignored.
    private var generation = 0
    /// Without a player: when what was given would be played out, and the wait that ends it (nil: quiet).
    private var silentUntil = Date.distantPast
    private var silentEnd: Task<Void, Never>?

    init(capture: RecordingCapture, tap: MeetingTalkTap, onPlaying: @escaping @MainActor (Bool) -> Void) {
        self.capture = capture
        self.tap = tap
        self.onPlaying = onPlaying
    }

    /// The recording's own: asked for as the meeting started, never switched while it records.
    var cancelsEcho: Bool { capture.cancelsEcho }

    func start(_ format: VoiceAudioFormat, uplink: VoiceUplink, events: @escaping @MainActor (VoiceAudioEvent) -> Void) throws {
        guard capture.state == .recording || capture.state == .paused else { throw VoiceAudioError.engine }
        self.format = format
        self.events = events
        playout = VoicePlayout(rate: format.outputRate)
        tap.connect(uplink)
    }

    func reconfigure(_ format: VoiceAudioFormat) throws {
        guard format != self.format else { return }
        dropQueued()
        self.format = format
        playout = VoicePlayout(rate: format.outputRate)
    }

    func play(_ pcm: Data) { schedule(pcm, voice: true) }

    func cue(_ pcm: Data) { schedule(pcm, voice: false) }

    func clear() {
        let was = !queued.isEmpty || silentEnd != nil
        dropQueued()
        if let player = capture.callPlayer {
            player.stop()
            if capture.engineRunning { player.play() }
        }
        if was { stopped() }
    }

    func stop() {
        tap.connect(nil)
        let was = !queued.isEmpty || silentEnd != nil
        dropQueued()
        capture.callPlayer?.stop()
        if was { onPlaying(false) }
        events = nil
    }

    // MARK: Playing

    private struct Piece {
        let buffer: AVAudioPCMBuffer
        let level: Float
    }

    private func schedule(_ pcm: Data, voice: Bool) {
        guard !pcm.isEmpty else { return }
        guard let player = capture.callPlayer else { return voice ? playSilently(pcm) : () }
        guard capture.engineRunning else { return } // paused with the recording: the voice is gone, not saved for later
        // The player runs at the recorder's call rate: the voice at another rate is resampled on its way in.
        let rate = Int(RecordingCapture.callFormat.sampleRate)
        let samples = VoicePCM.floats(format.outputRate == rate ? pcm : VoicePCM.resample(pcm, from: format.outputRate, to: rate))
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: RecordingCapture.callFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        guard voice else { return enqueue(buffer, level: nil, on: player) }
        let ready = playout.add(Piece(buffer: buffer, level: VoicePCM.rms(samples)), frames: samples.count, playing: !queued.isEmpty)
        if playout.isHolding {
            waitForLead()
        } else {
            holdTimer?.cancel()
            holdTimer = nil
        }
        for piece in ready { enqueue(piece.buffer, level: piece.level, on: player) }
    }

    /// Plays what is held once the first of it has waited `VoicePlayout.wait`, lead or not.
    private func waitForLead() {
        guard holdTimer == nil else { return }
        let generation = generation
        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(VoicePlayout<Piece>.wait))
            guard !Task.isCancelled, let self else { return }
            holdTimer = nil
            guard generation == self.generation, let player = capture.callPlayer, capture.engineRunning else { return playout.clear() }
            for piece in playout.release() { enqueue(piece.buffer, level: piece.level, on: player) }
        }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, level: Float?, on player: AVAudioPlayerNode) {
        let generation = generation
        let voice = level != nil
        if let level {
            if queued.isEmpty { began(level) }
            queued.append(level)
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.played(generation, voice: voice) }
        }
        if !player.isPlaying { player.play() }
    }

    private func played(_ generation: Int, voice: Bool) {
        guard voice, generation == self.generation, !queued.isEmpty else { return }
        queued.removeFirst()
        if let next = queued.first {
            events?(.outputLevel(next))
        } else {
            stopped()
        }
    }

    /// No player (a made-up recording): the voice takes as long as its PCM lasts.
    private func playSilently(_ pcm: Data) {
        let now = Date.now
        if silentEnd == nil { began(0.5) }
        silentUntil = max(silentUntil, now).addingTimeInterval(Double(pcm.count / 2) / Double(max(format.outputRate, 1)))
        silentEnd?.cancel()
        // As long as the jitter buffer would wait for the next piece: a voice streamed in 20 ms pieces is one stretch.
        let left = silentUntil.timeIntervalSince(now) + VoicePlayout<Piece>.wait
        silentEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled, let self else { return }
            self.silentUntil = .distantPast
            self.silentEnd = nil
            self.stopped()
        }
    }

    private func began(_ level: Float) {
        events?(.playing(true))
        events?(.outputLevel(level))
        onPlaying(true)
    }

    private func stopped() {
        events?(.outputLevel(0))
        events?(.playing(false))
        onPlaying(false)
    }

    private func dropQueued() {
        generation += 1
        holdTimer?.cancel()
        holdTimer = nil
        playout.clear()
        queued = []
        silentEnd?.cancel()
        silentEnd = nil
        silentUntil = .distantPast
    }
}
#endif
