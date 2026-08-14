import XCTest
@testable import Managerie

final class EventSpoolTests: XCTestCase {

    // MARK: - Event file filtering

    func testEventFileAccepted() {
        XCTAssertTrue(EventSpool.isEventFile("0001760000000000-123-abc123.json"))
    }

    func testTmpFilesRejected() {
        // In-progress writes are dotfiles with a .tmp suffix — never ingested.
        XCTAssertFalse(EventSpool.isEventFile(".0001760000000000-123-abc123.json.tmp"))
        XCTAssertFalse(EventSpool.isEventFile("0001760000000000-123-abc123.json.tmp"))
    }

    func testHiddenAndForeignFilesRejected() {
        XCTAssertFalse(EventSpool.isEventFile(".DS_Store"))
        XCTAssertFalse(EventSpool.isEventFile("notes.txt"))
        XCTAssertFalse(EventSpool.isEventFile("event.json.bak"))
    }

    // MARK: - Ordering

    func testSortedEventNamesChronological() {
        let names = [
            "0001760000000300-9-zz.json",
            ".0001760000000100-1-aa.json.tmp",   // in-progress — excluded
            "0001760000000100-500-bb.json",
            ".DS_Store",
            "0001760000000200-42-cc.json",
        ]
        XCTAssertEqual(EventSpool.sortedEventNames(names), [
            "0001760000000100-500-bb.json",
            "0001760000000200-42-cc.json",
            "0001760000000300-9-zz.json",
        ])
    }

    func testMakeEventFileNameSortsAcrossMagnitudes() {
        // Zero-padded timestamps: a later event never sorts before an earlier
        // one even when the raw numbers have different digit counts.
        let early = EventSpool.makeEventFileName(timestampMs: 999, pid: 1, entropy: "aa")
        let late = EventSpool.makeEventFileName(timestampMs: 1_000_000_000_000, pid: 1, entropy: "bb")
        XCTAssertLessThan(early, late)
        XCTAssertTrue(EventSpool.isEventFile(early))
        XCTAssertTrue(EventSpool.isEventFile(late))
    }

    func testMakeEventFileNameFormat() {
        let name = EventSpool.makeEventFileName(timestampMs: 1_760_000_000_123, pid: 4242, entropy: "f00bar")
        XCTAssertEqual(name, "1760000000123-4242-f00bar.json")
    }
}

// MARK: - Idle chime transition logic

final class IdleTransitionTests: XCTestCase {

    func testWorkingToDoneChimes() {
        XCTAssertTrue(AgentStatusStore.isIdleTransition(from: "running", to: "done"))
        XCTAssertTrue(AgentStatusStore.isIdleTransition(from: "thinking", to: "done"))
        XCTAssertTrue(AgentStatusStore.isIdleTransition(from: "editing", to: "waiting"))
        XCTAssertTrue(AgentStatusStore.isIdleTransition(from: "starting", to: "idle"))
    }

    func testIdleToIdleIsSilent() {
        // Repeated done/waiting updates must not re-ding.
        XCTAssertFalse(AgentStatusStore.isIdleTransition(from: "done", to: "done"))
        XCTAssertFalse(AgentStatusStore.isIdleTransition(from: "waiting", to: "done"))
        XCTAssertFalse(AgentStatusStore.isIdleTransition(from: "done", to: "waiting"))
    }

    func testActiveStatesAreSilent() {
        // Going busy or staying busy never chimes.
        XCTAssertFalse(AgentStatusStore.isIdleTransition(from: "done", to: "running"))
        XCTAssertFalse(AgentStatusStore.isIdleTransition(from: "reading", to: "editing"))
        XCTAssertFalse(AgentStatusStore.isIdleTransition(from: nil, to: "running"))
    }

    func testMidTurnToolErrorIsSilent() {
        // "error" fires mid-turn (tool failure) — the agent keeps going.
        XCTAssertFalse(AgentStatusStore.isIdleTransition(from: "running", to: "error"))
    }

    func testUnknownPreviousStateIsSilent() {
        // App launched mid-session: first observed status is not a transition.
        XCTAssertFalse(AgentStatusStore.isIdleTransition(from: nil, to: "done"))
        XCTAssertFalse(AgentStatusStore.isIdleTransition(from: nil, to: "waiting"))
    }
}
