import SwiftUI
import Testing
import UIKit
@testable import Persona

/// The one sidebar's column as drawn (#4206, #6061): the real Agents page with Persona's rows atop its list (`ChatsView`
/// under `oneSidebar`), hosted in a `UIWindow` of each posture's size (a `List` needs a real window; `ImageRenderer`
/// draws none), light and dark. Pixels and frames, not reference images: CI's Xcode draws a little differently from a
/// newer one. On any simulator: `splitIdiom` lays the column out for the iPad or the open Duo.
///
/// - the open Duo's column is 320 pt wide (`Theme.Size.sidebarPhone`, ChatGPT's there), the iPad's at least that;
/// - one color top to bottom (`Theme.Shell.drawer`, #4855), the strip over the header and the foot included;
/// - one button for the column at the top leading corner, the header's fold (not the system's beside it);
/// - nothing cut: every element of the column inside it, its foot inside the window.
///
/// `TEST_RUNNER_PERSONA_LOOK_SHOTS=<dir>` keeps the rendered images (`one-sidebar-<posture>-<look>.png`) for a person to look at.
@MainActor @Suite(.serialized) struct OneSidebarLookTests {
    enum Posture: String, CaseIterable, CustomTestStringConvertible {
        case iPad, duoUpright, duoOnItsSide

        /// The window in points: iPad Pro 13-inch (M5) upright; the open iPhone Duo's inner display upright and on its side.
        var size: CGSize {
            switch self {
            case .iPad: CGSize(width: 1032, height: 1376)
            case .duoUpright: CGSize(width: 669, height: 951)
            case .duoOnItsSide: CGSize(width: 951, height: 669)
            }
        }

        var idiom: UIUserInterfaceIdiom { self == .iPad ? .pad : .phone }
        /// The system's bars down the side (the open Duo on its side, `oneSidebarSideBars`).
        var sideBars: Bool { self == .duoOnItsSide }
        var testDescription: String { rawValue }
    }

    enum Look: String, CaseIterable, CustomTestStringConvertible {
        case light, dark
        var style: UIUserInterfaceStyle { self == .light ? .light : .dark }
        /// `Theme.Shell.drawer`: F9F9F9 / 171717.
        var column: (r: Int, g: Int, b: Int) { self == .light ? (249, 249, 249) : (23, 23, 23) }
        var testDescription: String { rawValue }
    }

    @Test(arguments: Posture.allCases, Look.allCases)
    func theColumn(posture: Posture, look: Look) async throws {
        let shown = try await Shown(posture: posture, look: look)
        defer { shown.close() }
        let column = shown.columnFrame
        let window = shown.page.bounds
        #expect(window.size == posture.size, "the page is \(window.size), not \(posture.size)")

        // Its width.
        if posture == .iPad {
            #expect(column.width >= Theme.Size.sidebarPhone, "the iPad's column is narrower than the Duo's: \(column)")
        } else {
            #expect(abs(column.width - Theme.Size.sidebarPhone) <= 1, "the open Duo's column is not \(Theme.Size.sidebarPhone) pt: \(column)")
        }
        #expect(column.minX <= 1, "the column is not at the window's leading edge: \(column)")

        // One color down its leading margin, from the window's top (over the header) to its foot.
        let px = try shown.pixels()
        let x = column.minX + 3
        var off: [String] = []
        for y in stride(from: CGFloat(1), to: window.height - 1, by: 4) {
            let c = px.color(x: x, y: y)
            if !c.near(look.column) { off.append("y \(Int(y)): \(c)") }
        }
        #expect(off.isEmpty, "\(posture) \(look): the column is not \(look.column) top to bottom at x \(Int(x)): \(off.prefix(8)) (\(off.count) points)")
        // And across its top, the strip over the header (#4855: the system's strip there was another color). Not across
        // its foot: the list's rows scroll on under the foot's floating buttons.
        let top = stride(from: column.minX + 3, to: column.maxX - 12, by: 8).map { px.color(x: $0, y: 2) }.filter { !$0.near(look.column) }
        #expect(top.isEmpty, "\(posture) \(look): the column's top is not one color: \(top.prefix(5)) (\(top.count) points)")

        // One button for the column at the top leading corner: the header's fold, no system Show / Hide Sidebar beside it.
        let corner = shown.buttons.filter { $0.frame.midX < window.midX && $0.frame.midY < 200 && Self.columnButton($0) }
        #expect(corner.count == 1, "\(posture) \(look): not one button for the column at the corner: \(corner)")
        #expect(corner.first?.id == "assistant-sidebar-collapse", "the corner's button is not the header's fold: \(corner)")

        // Nothing cut: what the column holds is inside it, the foot inside the window.
        let inColumn = shown.columnElements.filter { $0.frame.width > 0 }
        #expect(inColumn.count > 10, "\(posture) \(look): the column has \(inColumn.count) elements")
        let cut = inColumn.filter { $0.frame.minX < column.minX - 1 || $0.frame.maxX > column.maxX + 1 || $0.frame.minY < -1 }
        #expect(cut.isEmpty, "\(posture) \(look): cut at the column's edge: \(cut)")
        for id in ["assistant-sidebar-collapse", "sidebar-main", "sidebar-new", "sidebar-search", "sidebar-settings"] {
            let e = shown.elements.first { $0.id == id }
            #expect(e != nil, "\(posture) \(look): no \(id) in the column")
            if let e { #expect(window.insetBy(dx: -1, dy: -1).contains(e.frame), "\(posture) \(look): \(id) is outside the window: \(e.frame)") }
        }
        let foot = shown.elements.first { $0.id == "sidebar-new" }?.frame ?? .zero
        #expect(foot.maxY > window.height - 140, "\(posture) \(look): the foot is not at the column's foot: \(foot)")
    }

    private static func columnButton(_ e: AXElement) -> Bool {
        ["assistant-sidebar-button", "assistant-sidebar-collapse", "feishu-sidebar-button"].contains(e.id)
            || ["Show Sidebar", "Hide Sidebar", "显示边栏", "隐藏边栏"].contains(e.label) // i18n-ignore
    }
}

/// An accessibility element as a UI test would see it: identifier, label, frame in the window.
private struct AXElement: CustomStringConvertible {
    var id: String
    var label: String
    var frame: CGRect
    var button: Bool
    var description: String { "\(id) “\(label)” \(frame.integral)" }
}

/// The column drawn: the Agents page under the one sidebar in a window of the posture's size and look.
@MainActor private final class Shown {
    let window: UIWindow
    /// The page in the posture's size, at the window's top leading corner: the scene sizes a window that is shown to
    /// its screen (one wider than tall came back upright on the Duo's simulator), so the window is larger and the page
    /// a child of that size.
    let page: UIView
    let posture: OneSidebarLookTests.Posture
    let look: OneSidebarLookTests.Look
    private let kept: [String: Any?]
    private static let keys = ["agents.list.closed", "agents.list.width"]

    init(posture: OneSidebarLookTests.Posture, look: OneSidebarLookTests.Look) async throws {
        self.posture = posture
        self.look = look
        // The column out at its default width, whatever a UI test left in this app's defaults.
        kept = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        UserDefaults.standard.set(false, forKey: "agents.list.closed")
        UserDefaults.standard.set(0, forKey: "agents.list.width")
        // As XCUITest does: without an assistive technology SwiftUI builds no accessibility elements to read.
        RuntimeCLI.enableAccessibilityTree()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 1600, height: 1600))
        window.overrideUserInterfaceStyle = look.style
        let root = ChatsView()
            .environment(AppModel())
            .environment(\.oneSidebar, true)
            .environment(\.oneSidebarSideBars, posture.sideBars)
            .environment(\.splitIdiom, posture.idiom)
        let host = UIHostingController(rootView: root)
        host.traitOverrides.horizontalSizeClass = .regular
        host.traitOverrides.verticalSizeClass = .regular
        let container = UIViewController()
        window.rootViewController = container
        container.addChild(host)
        host.view.frame = CGRect(origin: .zero, size: posture.size)
        host.view.autoresizingMask = []
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        page = host.view
        window.isHidden = false
        await settle()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        for (k, v) in kept {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    /// Until the column's frame and the elements stop changing (a few frames), at most two seconds.
    private func settle() async {
        var last = ""
        var same = 0
        for _ in 0..<60 {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(33))
            let now = "\(columnFrame) \(page.frame)"
            same = now == last ? same + 1 : 0
            last = now
            if same >= 4 && columnFrame.width > 0 { return }
        }
    }

    /// The split's list column in window points.
    var columnFrame: CGRect {
        guard let list = columnView else { return .zero }
        return list.convert(list.bounds, to: window)
    }

    private var columnView: UIView? {
        guard let split = Self.split(in: window.rootViewController),
              let list = split.viewController(for: .primary)?.view, list.window != nil else { return nil }
        return list
    }

    private static func split(in vc: UIViewController?) -> UISplitViewController? {
        guard let vc else { return nil }
        if let s = vc as? UISplitViewController { return s }
        for child in vc.children { if let s = split(in: child) { return s } }
        return nil
    }

    /// Every accessibility element on the page, as a UI test queries them.
    var elements: [AXElement] { Self.elements(under: page, in: window) }

    /// The list column's own elements (not the page's under it, upright).
    var columnElements: [AXElement] { columnView.map { Self.elements(under: $0, in: window) } ?? [] }

    /// The walk `RuntimeCLI.allElements` takes (the one XCUITest's tree matches), from one view down.
    private static func elements(under root: UIView, in window: UIWindow) -> [AXElement] {
        var out: [AXElement] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ o: NSObject, depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(o)).inserted else { return }
            if let v = o as? UIView, v.isHidden || v.alpha < 0.01 { return }
            if o.isAccessibilityElement {
                let id = (o as? UIAccessibilityIdentification)?.accessibilityIdentifier
                    ?? (o.responds(to: Selector(("accessibilityIdentifier"))) ? o.value(forKey: "accessibilityIdentifier") as? String : nil)
                out.append(AXElement(id: id ?? "", label: o.accessibilityLabel ?? "", frame: window.convert(o.accessibilityFrame, from: nil),
                                     button: o.accessibilityTraits.contains(.button)))
            }
            if let children = o.accessibilityElements as? [NSObject] {
                for c in children { visit(c, depth: depth + 1) }
            } else {
                let n = o.accessibilityElementCount()
                if n > 0, n != NSNotFound {
                    for i in 0..<n { if let c = o.accessibilityElement(at: i) as? NSObject { visit(c, depth: depth + 1) } }
                }
            }
            if let v = o as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    var buttons: [AXElement] { elements.filter(\.button) }

    /// The window drawn, kept as a PNG where `PERSONA_LOOK_SHOTS` says.
    func pixels() throws -> WindowPixels {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: page.bounds, format: format).image { _ in
            page.drawHierarchy(in: page.bounds, afterScreenUpdates: true)
        }
        if let dir = ProcessInfo.processInfo.environment["PERSONA_LOOK_SHOTS"], let png = image.pngData() {
            let name = "one-sidebar-\(posture.rawValue)-\(look.rawValue)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: name + ".png"))
            // What the checks read: the column's frame and every element, as a UI test would list them.
            let text = (["column \(columnFrame.integral)"] + elements.map { "\($0.button ? "button " : "")\($0)" }).joined(separator: "\n")
            try? text.write(to: URL(fileURLWithPath: dir).appending(path: name + ".txt"), atomically: true, encoding: .utf8)
        }
        return try WindowPixels(try #require(image.cgImage), scale: format.scale)
    }
}

/// A drawn window's sRGB pixels, read in points.
private struct WindowPixels {
    struct RGB: CustomStringConvertible {
        var r: Int, g: Int, b: Int
        func near(_ c: (r: Int, g: Int, b: Int), by d: Int = 2) -> Bool { abs(r - c.r) <= d && abs(g - c.g) <= d && abs(b - c.b) <= d }
        var description: String { "(\(r),\(g),\(b))" }
    }

    let width: Int, height: Int, scale: CGFloat
    private let data: [UInt8]

    init(_ image: CGImage, scale: CGFloat) throws {
        width = image.width; height = image.height; self.scale = scale
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = buf
    }

    func color(x: CGFloat, y: CGFloat) -> RGB {
        let px = min(max(Int(x * scale), 0), width - 1), py = min(max(Int(y * scale), 0), height - 1)
        let i = (py * width + px) * 4
        return RGB(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]))
    }
}
