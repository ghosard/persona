import XCTest

/// Waiting on a condition instead of a fixed `sleep()` (#6061): the sidebar tests run with `-showStillUI YES`, where a
/// slide or a fold lands at once, so most waits end on their first check; under real animations they wait as long as
/// the motion takes, never a guessed second more.
enum Waits {
    /// Checks `ok` every 0.1 s until it holds or `timeout` passes.
    @MainActor static func until(_ timeout: TimeInterval = 5, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if ok() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < end
        return ok()
    }
}

extension XCUIElement {
    /// Waits until it can be tapped where it is (on screen, nothing over it).
    func waitForHittable(timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isHittable == true"), object: self)],
                       timeout: timeout) == .completed
    }

    /// Waits until it is gone or out of reach (slid off screen).
    func waitForNotHittable(timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR isHittable == false"), object: self)],
                       timeout: timeout) == .completed
    }

    /// Waits for VoiceOver's selected trait (the row the detail column shows).
    func waitForSelected(timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: self)],
                       timeout: timeout) == .completed
    }

    /// Waits until its frame stops moving: the same in two reads 0.15 s apart (a slide, a keyboard or a menu settled).
    /// False if it is gone or still moving at `timeout`.
    @MainActor func waitForSteadyFrame(timeout: TimeInterval = 5) -> Bool {
        var last: CGRect?
        return Waits.until(timeout) {
            guard exists else { last = nil; return false }
            let now = frame
            defer { last = now }
            guard let last, last == now else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                return false
            }
            return true
        }
    }
}
