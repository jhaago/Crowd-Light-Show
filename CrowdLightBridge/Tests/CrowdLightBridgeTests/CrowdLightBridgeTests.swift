import XCTest
@testable import CrowdLightBridge

final class CrowdLightBridgeTests: XCTestCase {
    func testDefaultCueMapHasUniqueNotes() {
        let notes = CueMapping.defaults.map(\.note)
        XCTAssertEqual(notes.count, Set(notes).count)
        XCTAssertEqual(notes, [24, 25, 26, 27, 28, 29, 30])
    }

    func testDefaultCueActionsMatchExpectedOrder() {
        XCTAssertEqual(
            CueMapping.defaults.map(\.action),
            [.blackout, .allOn, .syncFlash, .unison, .twinkle, .sparkle, .constellation]
        )
    }

    func testEffectProtocolNamesMatchAudienceWebApp() {
        XCTAssertEqual(CrowdAction.unison.effectName, "unison")
        XCTAssertEqual(CrowdAction.twinkle.effectName, "twinkle")
        XCTAssertEqual(CrowdAction.sparkle.effectName, "sparkle")
        XCTAssertEqual(CrowdAction.constellation.effectName, "constellation")
        XCTAssertNil(CrowdAction.blackout.effectName)
        XCTAssertNil(CrowdAction.syncFlash.effectName)
    }

    func testMidiNoteNaming() {
        XCTAssertEqual(CueMapping.noteName(24), "C1")
        XCTAssertEqual(CueMapping.noteName(25), "C#1")
        XCTAssertEqual(CueMapping.noteName(30), "F#1")
    }
}
