import Testing
@testable import Persona

/// Which taps in the one sidebar's column slide it away (#4852, #6061): upright on the open Duo the column lies over the
/// page and a pick that changes the page sends it away; filters, groupings and what opens over the window leave it.
/// Beside the page (the Duo on its side, the iPad) nothing sends it away. `OneSidebarTests` keeps one end-to-end check.
struct OneSidebarPickTests {
    private static let changesPage: [OneSidebarPick] = [.mainChat, .place, .pinned, .allChatsConversation, .searchResult, .newChat, .messages, .agent]
    private static let staysOnPage: [OneSidebarPick] = [.more, .filter, .grouping, .listMenu, .allChatsList, .search, .settings]

    @Test func everyPickIsSorted() {
        #expect(Set(Self.changesPage + Self.staysOnPage) == Set(OneSidebarPick.allCases))
        #expect(Self.changesPage.count + Self.staysOnPage.count == OneSidebarPick.allCases.count)
    }

    @Test(arguments: changesPage)
    func aPickThatChangesThePageSlidesAnOverlaidColumnAway(pick: OneSidebarPick) {
        #expect(pick.changesPage)
        #expect(pick.slidesAway(overlays: true, listShown: true))
    }

    @Test(arguments: staysOnPage)
    func filtersGroupingsAndCoversLeaveIt(pick: OneSidebarPick) {
        #expect(!pick.changesPage)
        #expect(!pick.slidesAway(overlays: true, listShown: true))
    }

    /// Beside the page, before the posture is read, or with the column already away: nothing to slide.
    @Test(arguments: OneSidebarPick.allCases)
    func besideThePageOrAwayItNeverSlides(pick: OneSidebarPick) {
        #expect(!pick.slidesAway(overlays: false, listShown: true))
        #expect(!pick.slidesAway(overlays: nil, listShown: true))
        #expect(!pick.slidesAway(overlays: true, listShown: false))
    }
}
