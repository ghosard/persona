import XCTest

/// iPad (docs/apple/ios.md「iPad」): the app runs natively (not the phone-sized window), the lists sit in a sidebar wide
/// enough for their cards, in portrait and landscape. Against scripts/mock/mock_hub.py (PERSONA_MOCK_HUB), on an iPad
/// simulator; skipped on iPhone. TEST_RUNNER_PERSONA_SHOTS=<dir> keeps a screenshot of each.
final class IPadLayoutTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad only") }
        guard let hub = ProcessInfo.processInfo.environment["PERSONA_MOCK_HUB"] else {
            throw XCTSkip("needs scripts/mock/mock_hub.py (PERSONA_MOCK_HUB)")
        }
        app = XCUIApplication()
        let pair = "persona://pair?url=" + hub.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&token=mock"
        app.launchArguments = ["-pairURL", pair, "-tab", "dev", "-dev.openChat", "", "-openAgentsFresh", "YES"]
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    @MainActor private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["PERSONA_SHOTS"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ipad-\(name).png"))
    }

    /// The column's agent row, scrolled to: under the one sidebar's Persona rows (#4206) it may be below the first screen,
    /// and the lazy list builds it only when near.
    @MainActor private func agentRow() -> XCUIElement {
        let row = app.buttons.matching(identifier: "agents.row").firstMatch
        let column = app.collectionViews.firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { column.swipeUp() }
        return row
    }

    @MainActor func testFillsTheScreenWithASidebar() {
        for (name, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            app.launchPinned()
            // The one sidebar (#4206): Persona's rows and the Agents list in one column, Persona's page beside it.
            let main = app.buttons["sidebar-main"].firstMatch, page = app.buttons["assistant-new"].firstMatch
            XCTAssertTrue(main.waitForExistence(timeout: 20), "no column in \(name):\n\(app.debugDescription)")
            XCTAssertTrue(page.waitForExistence(timeout: 10), "\(name): no page beside the column:\n\(app.debugDescription)")
            let window = app.windows.firstMatch.frame
            // Native: the window is the screen, not a phone-sized box in the middle.
            XCTAssertGreaterThan(window.width, 700, "\(name): window \(window)")
            // The column is wider than the system's narrow sidebar, and the page keeps most of the rest.
            XCTAssertGreaterThanOrEqual(main.frame.maxX, 330, "\(name): sidebar too narrow (\(main.frame))")
            let edge = main.frame.maxX // the column's edge, read before the column scrolls Main Chat away
            XCTAssertGreaterThan(page.frame.minX, edge, "\(name): the page is beside the column")
            shot("agents-\(name)")
            // A chat opens beside the column, which stays.
            let row = agentRow()
            XCTAssertTrue(row.exists, "\(name): no agent in the column:\n\(app.debugDescription)")
            row.tap()
            let title = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["chat.title", "chat.compactTitle"])).firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 10), "\(name): the chat did not open in the detail column")
            XCTAssertGreaterThan(title.frame.minX, edge - 1, "\(name): the chat is not beside the column")
            XCTAssertTrue(app.buttons["sidebar-new"].firstMatch.isHittable, "\(name): the column went away when the chat opened")
            shot("chat-\(name)")
            // TEST_RUNNER_PERSONA_HOLD=<seconds>: stay on each page so `simctl io screenshot` can take it (XCUITest's own
            // screenshot comes out turned in landscape).
            if let hold = ProcessInfo.processInfo.environment["PERSONA_HOLD"].flatMap(UInt32.init) { sleep(hold) }
            app.terminate()
        }
    }

    /// Machines, under the one sidebar's More (#4206), opens beside the column, its cards side by side; a card opens the
    /// machine there too, the column staying (docs/server/machines.md「App」).
    @MainActor func testMachinesInTheDetailColumn() {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchPinned()
        let more = app.buttons["sidebar-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
        more.tap()
        let item = app.buttons["sidebar-machines"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.tap()
        // The cards, not the machine names on the Agents rows in the column.
        func card(_ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + "、")).firstMatch }
        let nas = card("NAS"), server = card("服务器"), column = app.buttons["sidebar-new"].firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(column.isHittable, "the column stays beside Machines")
        XCTAssertGreaterThan(nas.frame.minX, column.frame.maxX, "the cards are beside the column")
        XCTAssertEqual(nas.frame.minY, server.frame.minY, accuracy: 2, "the first two cards side by side")
        XCTAssertLessThan(nas.frame.minX, server.frame.minX, "the offline NAS first")
        shot("machines")
        server.tap()
        XCTAssertTrue(app.descendants(matching: .any)["metric-range"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(column.isHittable, "still beside the column")
        sleep(1)
        shot("machine")
    }

    /// The list column reaches the top of the screen (the strip under the status bar has its color), and when the
    /// column is closed the strip is the detail's again (2026-10-31: the list looked cut off at the top).
    @MainActor func testSidebarReachesTheTop() throws {
        XCUIDevice.shared.orientation = .portrait
        let base = app.launchArguments
        for (name, tint) in [("glass", "style"), ("glass", "coral")] {
            let style = "\(name)-\(tint)"
            app.launchArguments = base + ["-ui.style", name, "-ui.color", tint]
            app.launchPersona() // this test names its styles itself
            XCTAssertTrue(app.buttons["sidebar-main"].firstMatch.waitForExistence(timeout: 20), "\(style): no column:\n\(app.debugDescription)")
            sleep(1)
            var image = app.screenshot().image
            shot("top-\(style)")
            let scale = image.scale
            func color(_ x: CGFloat, _ y: CGFloat) -> [Int] {
                guard let cg = image.cgImage?.cropping(to: CGRect(x: x * scale, y: y * scale, width: 1, height: 1)),
                      let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return [] }
                return [Int(p[0]), Int(p[1]), Int(p[2])]
            }
            // The same to the eye: the system's glass edge over the list's top tints it a few levels.
            func near(_ a: [Int], _ b: [Int]) -> Bool { a.count == 3 && b.count == 3 && zip(a, b).allSatisfy { abs($0 - $1) <= 8 } }
            // Above the list column (in the status bar), the same color as the column under it; the detail column's
            // strip stays the detail's.
            XCTAssertTrue(near(color(8, 2), color(8, 34)), "\(style): the strip above the list (\(color(8, 2))) is not the list's color (\(color(8, 34)))")
            // Under the page's top bar, above the conversation: lower down a message bubble can be there (the main chat's
            // chart answer since 2026-11-12), not the page.
            let right = app.windows.firstMatch.frame.width - 40
            XCTAssertTrue(near(color(right, 2), color(right, 120)), "\(style): the strip above the detail changed (\(color(right, 2)) vs \(color(right, 120)))")
            // Close the column from its header's button: what is at the top there is the detail's color again, as below it.
            let toggle = app.buttons["assistant-sidebar-collapse"].firstMatch
            XCTAssertTrue(toggle.exists, "no sidebar button:\n\(app.debugDescription)")
            toggle.tap()
            sleep(1)
            image = app.screenshot().image
            XCTAssertTrue(near(color(8, 2), color(8, 120)), "\(style): the list's color stayed at the top after closing it (\(color(8, 2)))")
            app.terminate()
        }
    }
}
