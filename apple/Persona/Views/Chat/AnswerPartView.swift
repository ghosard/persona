import MarkdownUI
import PersonaKit
import SwiftUI

/// A long finished answer's parts (#4970, `AnswerParts`), worked out once per text: the chat's lines ask on every
/// rebuild, and the rows' memos are prewarmed with them off the main thread (`RowMemo.prewarm`).
nonisolated enum AnswerPartMemo {
    private static let memo = TextMemo<[AnswerParts.Part]>(limit: 64)

    /// Below this many bytes an answer is never cut (`AnswerParts.minimumBytes` and `minimumLines` decide above it);
    /// it saves hashing every answer's text.
    static let floor = 2_000

    /// DEBUG `-showAnswerPartLines <n>`: parts of about n lines (and n × 125 bytes), to compare sizes in one build.
    private static let target: (lines: Int, bytes: Int) = {
        #if DEBUG
        let n = UserDefaults.standard.integer(forKey: "showAnswerPartLines")
        if n > 0 { return (n, n * 125) }
        #endif
        return (AnswerParts.targetLines, AnswerParts.targetBytes)
    }()

    /// DEBUG `-showAnswerWhole YES`: every answer one row, as before parts, to measure against in the same build.
    private static let whole: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "showAnswerWhole")
        #else
        false
        #endif
    }()

    static func parts(_ text: String) -> [AnswerParts.Part] {
        guard !whole, text.utf8.count >= floor else { return [] }
        return memo(text) { AnswerParts.split($0, lines: target.lines, bytes: target.bytes) }
    }

    /// The row memo key of part `index` of the message whose key is `message` (`RowMemo.key`).
    static func key(_ message: String, _ index: Int) -> String { message + "\u{1}part\(index)" }
}

extension ChatLines {
    /// The chat's long finished answers as their parts (`AnswerParts`), each a line of its own; everything else as it is.
    static func splitAnswers(_ lines: [ChatLine]) -> [ChatLine] {
        var out: [ChatLine]?
        for (n, line) in lines.enumerated() {
            guard case .row(.assistant(let item)) = line.content else {
                out?.append(line)
                continue
            }
            let parts = AnswerPartMemo.parts(item.text ?? "")
            guard parts.count > 1 else {
                out?.append(line)
                continue
            }
            if out == nil { out = Array(lines[..<n]) }
            for (index, part) in parts.enumerated() {
                out?.append(.answerPart(item: item, part: part, index: index, count: parts.count))
            }
        }
        return out ?? lines
    }
}

/// A part of a long finished answer (#4970), a row of the chat list: drawn as `AssistantText` draws a whole answer,
/// one part at a time, `AnswerParts.Part.gap` under the part before it, as MarkdownUI would space those two blocks.
/// A long press on any part lifts the whole answer (`AnswerPartsLift`), placed where the pressed part is, with the
/// whole answer's actions: Copy, Select Text, Quote and Forward take all of it (#5221). The files and ports the answer
/// names sit under its last part.
struct AssistantTextPart: View, Equatable {
    var item: Item
    var part: AnswerParts.Part
    var index: Int
    var count: Int

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.item == b.item && a.part == b.part && a.index == b.index && a.count == b.count
    }

    @Environment(\.openFile) private var openFile
    @Environment(\.rowMemoScope) private var memoScope

    private var last: Bool { index == count - 1 }

    var body: some View {
        #if DEBUG || PERF_SIGNPOST
        let _ = PerfTrace.body("AssistantTextPart")
        #endif
        let message = RowMemo.key(memoScope, item.id)
        let key = AnswerPartMemo.key(message, index)
        let text = RowMemo.assistant(key) { _ in AssistantRowText(part.text) } // prewarmed with the message
        let whole = last ? RowMemo.assistant(message) { _ in AssistantRowText(item.text ?? "") } : nil
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            AnswerPartWords(text: text, key: key, message: message)
                .contentShape(.rect)
                .messageLongPress(id: item.id, card: true, part: index) {
                    AnswerPartsLift(item: item, message: message, pressed: index)
                }
            if let whole {
                if let openFile {
                    // Documents as cards with their first page (#1543), the rest as chips (`AssistantText`).
                    FileChips(paths: whole.chips, open: openFile)
                    DocumentCards(paths: whole.files.filter(DocumentCards.isDocument), open: openFile)
                }
                PortChips(text: item.text ?? "")
            }
        }
        .markdownSoftBreakMode(.lineBreak)
        .lookUpFiles(whole.map { PathRefs.unique(text.asked + $0.chips, limit: 40) } ?? text.asked)
        .task(id: item.id) { if last { await AssistantText.preloadLinks(item) } }
        .messageActionBar(id: item.id, text: item.text ?? "", isUser: false, date: item.ts)
        // The list puts its own spacing between rows; the part sits where the answer's next block would.
        .padding(.top, index == 0 ? 0 : part.gap - Theme.Space.l)
    }
}

/// A part's words as the chat draws them (`AssistantTextPart`), and in the whole answer's lifted copy (`AnswerPartsLift`).
private struct AnswerPartWords: View {
    var text: AssistantRowText
    var key: String
    var message: String

    var body: some View {
        LinkedMarkdown(plain: text.markdown, paths: text.paths, key: key)
            .markdownTheme(.persona)
            .environment(\.replyKey, message) // its quotes' folds, the lifted copy's too (as `AssistantText`)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
/// `LiftTrace`: when a lifted part gets its height, and which.
private struct LiftTracePart: ViewModifier {
    let n: Int

    func body(content: Content) -> some View {
        if LiftTrace.on {
            content.onGeometryChange(for: Int.self) { Int($0.size.height) } action: { LiftTrace.note("part \(n) height \($0)") }
        } else {
            content
        }
    }
}
#endif

/// The lifted copy of a long answer drawn in parts (#5221): all of its parts again, each `Part.gap` under the one
/// before, as the chat stacks them (so it looks as the answer did whole, `AnswerPartsLookTests`), the pressed part
/// marked for the lift to put it where it was (`MessageLift.part`). Lifted, it is a lazy stack: only the parts near the
/// screen are laid out, the others as the copy scrolls to them (laying out all of a long report at once is the cost
/// #4970 took out of the chat). Its first frame lays out the pressed part and what shows under it, as lifting one part
/// did (#5291): the parts above it hold their place until the frame after, since a lazy stack opened at a part lays out
/// its first parts and walks through those above it to reach it. To select its words it lays out all of them
/// (`MessageMenu.liftWhole`), one a frame, what shows first (`LiftFrames`): the text view over them, laid out from
/// the whole answer's text, follows every line.
struct AnswerPartsLift: View {
    var item: Item
    /// The answer's row memo key (`RowMemo.key`).
    var message: String
    var pressed: Int
    @Environment(\.liftWhole) private var whole
    @Environment(\.liftPartRoom) private var room
    /// The first frame is drawn: the parts above the pressed one are themselves.
    @State private var grown = false
    /// Selecting: how many parts are themselves past the first ones (`LiftParts.first`).
    @State private var admitted = 0
    @State private var laid = LiftParts()
    @State private var frames = LiftFrames()

    var body: some View {
        let parts = AnswerPartMemo.parts(item.text ?? "")
        #if DEBUG
        let _ = LiftTrace.note("parts body pressed=\(pressed)/\(parts.count) whole=\(whole) grown=\(grown) admitted=\(admitted)")
        #endif
        if parts.isEmpty { // not in parts after all: the answer as one
            AnswerPartWords(text: RowMemo.assistant(message) { _ in AssistantRowText(item.text ?? "") }, key: message, message: message)
                .liftPressedPart(true, whole: true)
                .markdownSoftBreakMode(.lineBreak)
                .selectableInLift(item.text ?? "", as: .reply(quiet: false))
        } else if whole {
            let rank = laid.ranks(parts.count, pressed: pressed)
            let shown = laid.first + admitted
            VStack(alignment: .leading, spacing: 0) {
                ForEach(parts.indices, id: \.self) { n in
                    if rank[n] < shown { words(parts, n, whole: shown >= parts.count) } else { held(parts, n) }
                }
            }
            .markdownSoftBreakMode(.lineBreak)
            .selectableInLift(item.text ?? "", as: .reply(quiet: false))
            .onAppear {
                guard laid.first < parts.count else { return }
                frames.run {
                    admitted += 1
                    #if DEBUG
                    LiftTrace.note("admit \(laid.first + admitted)/\(parts.count)")
                    #endif
                    return laid.first + admitted < parts.count
                }
            }
        } else {
            let waits = !grown && pressed > 0 && tallerThanTheScreen(parts)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(parts.indices, id: \.self) { n in
                    if waits && n < pressed {
                        held(parts, n)
                    } else {
                        words(parts, n, whole: false)
                            .onAppear { laid.near.insert(n) }
                            .onDisappear { laid.near.remove(n) }
                    }
                }
            }
            .scrollTargetLayout()
            .markdownSoftBreakMode(.lineBreak)
            .onAppear {
                if waits { frames.run { grown = true; return false } }
            }
        }
    }

    @ViewBuilder private func words(_ parts: [AnswerParts.Part], _ n: Int, whole: Bool) -> some View {
        let key = AnswerPartMemo.key(message, n)
        let text = RowMemo.assistant(key) { _ in AssistantRowText(parts[n].text) }
        #if DEBUG
        let _ = LiftTrace.note("part \(n) built whole=\(whole) chars=\(parts[n].text.count)")
        #endif
        AnswerPartWords(text: text, key: key, message: message)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { laid.heights[n] = $0 }
            .liftPressedPart(n == pressed, whole: whole)
            .padding(.top, n == 0 ? 0 : parts[n].gap)
            #if DEBUG
            .modifier(LiftTracePart(n: n))
            #endif
    }

    /// A part not laid out yet, holding its place: as tall as it was when it last was, else as tall as the pressed part
    /// was in the chat for its length.
    private func held(_ parts: [AnswerParts.Part], _ n: Int) -> some View {
        Color.clear
            .frame(height: laid.heights[n] ?? CGFloat(parts[n].text.utf8.count) * height(perByteOf: parts))
            .padding(.top, n == 0 ? 0 : parts[n].gap)
    }

    private func height(perByteOf parts: [AnswerParts.Part]) -> CGFloat {
        guard let room, room.part > 0 else { return 0.7 } // about a line of the body's for each of its ~30 bytes
        return room.part / CGFloat(max(parts[pressed].text.utf8.count, 1))
    }

    /// Surely taller than the screen: the card shows from the pressed part on, wherever the parts above it end. One that
    /// may fit shows whole, as tall as it is, its parts all themselves from the first frame.
    private func tallerThanTheScreen(_ parts: [AnswerParts.Part]) -> Bool {
        guard let room else { return false }
        return CGFloat(parts.reduce(0) { $0 + $1.text.utf8.count }) * height(perByteOf: parts) > room.screen * 2
    }
}

/// What of a lifted copy's parts is laid out (not observed: nothing is drawn again for it): each one's height once it
/// was, and those its lazy stack has on hand now; to select its words, the order its parts are laid out in.
final class LiftParts {
    var heights: [Int: CGFloat] = [:]
    var near: Set<Int> = []
    /// Each part's place in that order, and how many come in its first frame.
    private(set) var rank: [Int] = []
    private(set) var first = 0

    /// What the lazy stack has on hand and the pressed part first (they show), then the others, nearest to the pressed
    /// one first, those under it before those above (which move it, `LiftedMessage.measured`).
    func ranks(_ count: Int, pressed: Int) -> [Int] {
        if rank.count == count { return rank }
        let start = near.union([pressed]).filter { $0 < count }.sorted()
        let rest = (0..<count).filter { !start.contains($0) }.sorted {
            let a = abs($0 - pressed), b = abs($1 - pressed)
            return a != b ? a < b : $0 > $1
        }
        var out = [Int](repeating: 0, count: count)
        for (i, n) in (start + rest).enumerated() { out[n] = i }
        rank = out
        first = start.count
        return out
    }
}
