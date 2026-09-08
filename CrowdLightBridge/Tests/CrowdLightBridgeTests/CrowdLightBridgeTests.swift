import XCTest
import CoreMIDI
@testable import CrowdLightBridge

final class CrowdLightBridgeTests: XCTestCase {
    func testDefaultCueMapHasUniqueNotes() {
        let notes = CueMapping.defaults.map(\.note)
        XCTAssertEqual(notes.count, Set(notes).count)
        XCTAssertEqual(notes, Array(24...36))
    }

    func testDefaultCueActionsMatchExpectedOrder() {
        XCTAssertEqual(
            CueMapping.defaults.map(\.action),
            [
                .blackout, .allOn, .syncFlash,
                .unison, .twinkle, .sparkle, .constellation,
                .shimmer, .glow, .fireflies, .alternate, .build, .drop
            ]
        )
    }

    func testEffectProtocolNamesMatchAudienceWebApp() {
        XCTAssertEqual(CrowdAction.unison.effectName, "unison")
        XCTAssertEqual(CrowdAction.shimmer.effectName, "shimmer")
        XCTAssertEqual(CrowdAction.twinkle.effectName, "twinkle")
        XCTAssertEqual(CrowdAction.sparkle.effectName, "sparkle")
        XCTAssertEqual(CrowdAction.glow.effectName, "glow")
        XCTAssertEqual(CrowdAction.fireflies.effectName, "fireflies")
        XCTAssertEqual(CrowdAction.alternate.effectName, "alternate")
        XCTAssertEqual(CrowdAction.constellation.effectName, "constellation")
        XCTAssertEqual(CrowdAction.build.effectName, "build")
        XCTAssertEqual(CrowdAction.drop.effectName, "drop")
        XCTAssertNil(CrowdAction.blackout.effectName)
        XCTAssertNil(CrowdAction.syncFlash.effectName)
    }

    func testMidiNoteNaming() {
        XCTAssertEqual(CueMapping.noteName(24), "C1")
        XCTAssertEqual(CueMapping.noteName(25), "C#1")
        XCTAssertEqual(CueMapping.noteName(30), "F#1")
        XCTAssertEqual(CueMapping.noteName(36), "C2")
    }

    func testLoopbackDiagnosticBuildsUnmappedChannel16Note() {
        XCTAssertEqual(
            MIDIManager.noteOnBytes(note: 127, channel: 16, velocity: 100),
            [0x9F, 127, 100]
        )
    }

    func testLoopbackDestinationMatchingPrefersExactName() {
        XCTAssertEqual(
            MIDIManager.bestDestinationIndex(
                sourceName: "IAC Driver CrowdLight",
                destinationNames: ["Other", "IAC Driver CrowdLight", "CrowdLight Backup"]
            ),
            1
        )
    }

    func testLoopbackDestinationMatchingAllowsSingleCrowdLightDestination() {
        XCTAssertEqual(
            MIDIManager.bestDestinationIndex(
                sourceName: "Different Source Label",
                destinationNames: ["Other", "IAC Driver CrowdLight"]
            ),
            1
        )
        XCTAssertNil(
            MIDIManager.bestDestinationIndex(
                sourceName: "Different Source Label",
                destinationNames: ["CrowdLight A", "CrowdLight B"]
            )
        )
    }

    func testMIDIParserHandlesMultipleMessagesAndVelocityZero() {
        let events = MIDIManager.parseNoteOns(bytes: [
            0x9F, 24, 100,
            0x9F, 25, 0,
            0xCF, 7,
            0x9F, 26, 64
        ])

        XCTAssertEqual(
            events,
            [
                ParsedMIDINoteOn(note: 24, channel: 16, velocity: 100),
                ParsedMIDINoteOn(note: 26, channel: 16, velocity: 64)
            ]
        )
    }

    func testMIDIParserSkipsSysExAndRealtimeSafely() {
        let events = MIDIManager.parseNoteOns(bytes: [
            0xF0, 0x01, 0x02, 0xF7,
            0xF8,
            0x90, 28, 90,
            0x80, 28, 0
        ])

        XCTAssertEqual(
            events,
            [ParsedMIDINoteOn(note: 28, channel: 1, velocity: 90)]
        )
    }

    func testPacketPayloadTraversalUsesOriginalVariableLengthList() {
        let capacity = 1024
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { raw.deallocate() }

        let packetList = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(packetList)

        let first: [UInt8] = [0x9F, 24, 100]
        first.withUnsafeBufferPointer { buffer in
            packet = MIDIPacketListAdd(
                packetList,
                capacity,
                packet,
                100,
                first.count,
                buffer.baseAddress!
            )
        }
        let second: [UInt8] = [0x9F, 28, 80, 0x9F, 29, 70]
        second.withUnsafeBufferPointer { buffer in
            packet = MIDIPacketListAdd(
                packetList,
                capacity,
                packet,
                200,
                second.count,
                buffer.baseAddress!
            )
        }
        let payloads = MIDIManager.packetPayloads(
            packetList: UnsafePointer(packetList)
        )
        XCTAssertEqual(payloads, [first, second])
    }
}
