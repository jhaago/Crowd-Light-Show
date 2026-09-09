import Foundation
import CoreMIDI
import Combine

struct ParsedMIDINoteOn: Equatable {
    let note: Int
    let channel: Int
    let velocity: Int
}

private func crowdLightMIDIReadProc(
    _ packetList: UnsafePointer<MIDIPacketList>,
    _ readProcRefCon: UnsafeMutableRawPointer?,
    _ srcConnRefCon: UnsafeMutableRawPointer?
) {
    guard let readProcRefCon else { return }
    let manager = Unmanaged<MIDIManager>.fromOpaque(readProcRefCon).takeUnretainedValue()
    manager.handle(packetList: packetList)
}

private func crowdLightMIDINotifyProc(
    _ message: UnsafePointer<MIDINotification>,
    _ refCon: UnsafeMutableRawPointer?
) {
    guard let refCon else { return }
    let manager = Unmanaged<MIDIManager>.fromOpaque(refCon).takeUnretainedValue()
    manager.handleMIDISystemChanged()
}

final class MIDIManager: ObservableObject {
    @Published var sources: [MIDISourceInfo] = []
    @Published var connectedSourceID: Int32 = 0
    @Published var connectedSourceName: String = "Not connected"
    @Published var lastMessage: String = "No MIDI received"

    var onNoteOn: ((Int, Int, Int) -> Void)?
    var onSourceLost: (() -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var connectedEndpoint = MIDIEndpointRef()

    init() {
        createClient()
        refreshSources()
    }

    deinit {
        if connectedEndpoint != 0 {
            MIDIPortDisconnectSource(inputPort, connectedEndpoint)
        }
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    private func createClient() {
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        let clientStatus = MIDIClientCreate(
            "CrowdLight Bridge" as CFString,
            crowdLightMIDINotifyProc,
            refCon,
            &client
        )
        guard clientStatus == noErr else {
            lastMessage = "Could not create CoreMIDI client (\(clientStatus))"
            return
        }

        let portStatus = MIDIInputPortCreate(
            client,
            "CrowdLight MIDI Input" as CFString,
            crowdLightMIDIReadProc,
            refCon,
            &inputPort
        )
        if portStatus != noErr {
            lastMessage = "Could not create MIDI input port (\(portStatus))"
        }

        let outputStatus = MIDIOutputPortCreate(
            client,
            "CrowdLight MIDI Test Output" as CFString,
            &outputPort
        )
        if outputStatus != noErr {
            lastMessage = "Could not create MIDI test output port (\(outputStatus))"
        }
    }

    func refreshSources() {
        var discovered: [MIDISourceInfo] = []
        let count = MIDIGetNumberOfSources()

        for index in 0..<count {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0 else { continue }

            var uniqueID: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)

            var unmanagedName: Unmanaged<CFString>?
            let status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName)
            var name = "MIDI Source \(index + 1)"
            if status == noErr, let unmanagedName {
                name = unmanagedName.takeRetainedValue() as String
            } else {
                var fallback: Unmanaged<CFString>?
                if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &fallback) == noErr,
                   let fallback {
                    name = fallback.takeRetainedValue() as String
                }
            }

            discovered.append(
                MIDISourceInfo(
                    id: uniqueID,
                    endpoint: UInt32(endpoint),
                    name: name
                )
            )
        }

        let sorted = discovered.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if Thread.isMainThread {
            self.sources = sorted
        } else {
            DispatchQueue.main.async {
                self.sources = sorted
            }
        }
    }

    fileprivate func handleMIDISystemChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let previousID = self.connectedSourceID
            self.refreshSources()

            guard previousID != 0 else { return }
            guard !self.sources.contains(where: { $0.id == previousID }) else { return }

            if self.connectedEndpoint != 0 {
                MIDIPortDisconnectSource(self.inputPort, self.connectedEndpoint)
                self.connectedEndpoint = 0
            }
            self.connectedSourceID = 0
            self.connectedSourceName = "MIDI source lost"
            self.lastMessage = "Selected MIDI source disappeared. External cues have been disarmed."
            self.onSourceLost?()
        }
    }

    func connect(to sourceID: Int32) {
        guard inputPort != 0 else { return }

        if connectedEndpoint != 0 {
            MIDIPortDisconnectSource(inputPort, connectedEndpoint)
            connectedEndpoint = 0
        }

        guard let source = sources.first(where: { $0.id == sourceID }) else {
            DispatchQueue.main.async {
                self.connectedSourceID = 0
                self.connectedSourceName = "Not connected"
            }
            return
        }

        let endpoint = MIDIEndpointRef(source.endpoint)
        let status = MIDIPortConnectSource(inputPort, endpoint, nil)
        DispatchQueue.main.async {
            if status == noErr {
                self.connectedEndpoint = endpoint
                self.connectedSourceID = source.id
                self.connectedSourceName = source.name
                self.lastMessage = "Listening to \(source.name)"
            } else {
                self.connectedSourceID = 0
                self.connectedSourceName = "Connection failed"
                self.lastMessage = "Could not connect MIDI source (\(status))"
            }
        }
    }

    func autoSelectCrowdLightSource() -> Int32? {
        refreshSources()
        if let source = sources.first(where: {
            $0.name.localizedCaseInsensitiveContains("CrowdLight")
        }) {
            connect(to: source.id)
            return source.id
        }
        return nil
    }

    static func noteOnBytes(note: Int, channel: Int, velocity: Int = 100) -> [UInt8] {
        let safeNote = UInt8(max(0, min(127, note)))
        let safeChannel = UInt8(max(1, min(16, channel)) - 1)
        let safeVelocity = UInt8(max(1, min(127, velocity)))
        return [0x90 | safeChannel, safeNote, safeVelocity]
    }

    static func noteOffBytes(note: Int, channel: Int) -> [UInt8] {
        let safeNote = UInt8(max(0, min(127, note)))
        let safeChannel = UInt8(max(1, min(16, channel)) - 1)
        return [0x80 | safeChannel, safeNote, 0]
    }

    static func bestDestinationIndex(
        sourceName: String,
        destinationNames: [String]
    ) -> Int? {
        let source = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return destinationNames.firstIndex(where: {
            $0.compare(
                source,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        })
    }

    func sendLoopbackTest(
        note: Int = 127,
        channel: Int,
        velocity: Int = 100
    ) -> Result<String, Error> {
        guard outputPort != 0 else {
            return .failure(MIDILoopbackError.outputPortUnavailable)
        }
        guard connectedSourceID != 0 else {
            return .failure(MIDILoopbackError.noSelectedSource)
        }

        var destinations: [(endpoint: MIDIEndpointRef, name: String)] = []
        for index in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(index)
            guard endpoint != 0 else { continue }

            var unmanagedName: Unmanaged<CFString>?
            var name = "MIDI Destination \(index + 1)"
            if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName) == noErr,
               let unmanagedName {
                name = unmanagedName.takeRetainedValue() as String
            } else {
                var fallback: Unmanaged<CFString>?
                if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &fallback) == noErr,
                   let fallback {
                    name = fallback.takeRetainedValue() as String
                }
            }
            destinations.append((endpoint, name))
        }

        let names = destinations.map(\.name)
        guard let match = Self.bestDestinationIndex(
            sourceName: connectedSourceName,
            destinationNames: names
        ) else {
            return .failure(
                MIDILoopbackError.noMatchingDestination(
                    source: connectedSourceName,
                    destinations: names
                )
            )
        }

        // Send a matching Note Off in the same diagnostic packet. CrowdLight
        // consumes only the Note On, while generic MIDI listeners will not be
        // left with a latched note if they also observe the dedicated IAC bus.
        let bytes =
            Self.noteOnBytes(
                note: note,
                channel: channel,
                velocity: velocity
            ) +
            Self.noteOffBytes(
                note: note,
                channel: channel
            )

        let capacity = 64
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: capacity,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { raw.deallocate() }

        let packetList = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(packetList)
        let added = bytes.withUnsafeBufferPointer { buffer in
            MIDIPacketListAdd(
                packetList,
                capacity,
                packet,
                0,
                buffer.count,
                buffer.baseAddress!
            )
        }

        guard added != nil else {
            return .failure(MIDILoopbackError.packetBuildFailed)
        }

        let status = MIDISend(
            outputPort,
            destinations[match].endpoint,
            UnsafePointer(packetList)
        )
        guard status == noErr else {
            return .failure(MIDILoopbackError.sendFailed(status))
        }

        return .success(destinations[match].name)
    }

    static func parseNoteOns(bytes: [UInt8]) -> [ParsedMIDINoteOn] {
        var result: [ParsedMIDINoteOn] = []
        var index = 0

        while index < bytes.count {
            let status = bytes[index]

            // Running status is not expected from the dedicated ProPresenter
            // IAC path. Stray data bytes are ignored defensively.
            if status < 0x80 {
                index += 1
                continue
            }

            // MIDI realtime bytes may legally appear between any other MIDI
            // bytes without affecting the surrounding message.
            if status >= 0xF8 {
                index += 1
                continue
            }

            if status >= 0xF0 {
                switch status {
                case 0xF0:
                    index += 1
                    while index < bytes.count && bytes[index] != 0xF7 {
                        index += 1
                    }
                    if index < bytes.count { index += 1 }
                case 0xF1, 0xF3:
                    var needed = 1
                    index += 1
                    while index < bytes.count && needed > 0 {
                        let byte = bytes[index]
                        if byte >= 0xF8 {
                            index += 1
                            continue
                        }
                        if byte >= 0x80 { break }
                        needed -= 1
                        index += 1
                    }
                case 0xF2:
                    var needed = 2
                    index += 1
                    while index < bytes.count && needed > 0 {
                        let byte = bytes[index]
                        if byte >= 0xF8 {
                            index += 1
                            continue
                        }
                        if byte >= 0x80 { break }
                        needed -= 1
                        index += 1
                    }
                default:
                    index += 1
                }
                continue
            }

            let messageType = status & 0xF0
            let channel = Int(status & 0x0F) + 1
            let dataCount = (messageType == 0xC0 || messageType == 0xD0) ? 1 : 2

            var data: [UInt8] = []
            data.reserveCapacity(dataCount)
            var cursor = index + 1

            while cursor < bytes.count && data.count < dataCount {
                let byte = bytes[cursor]
                if byte >= 0xF8 {
                    cursor += 1
                    continue
                }
                if byte >= 0x80 {
                    break
                }
                data.append(byte)
                cursor += 1
            }

            guard data.count == dataCount else {
                // If a new status interrupted a truncated message, let the next
                // loop process that status rather than swallowing it.
                index = max(index + 1, cursor)
                continue
            }

            if messageType == 0x90, data.count == 2 {
                let note = Int(data[0])
                let velocity = Int(data[1])
                if velocity > 0 {
                    result.append(
                        ParsedMIDINoteOn(
                            note: note,
                            channel: channel,
                            velocity: velocity
                        )
                    )
                }
            }

            index = cursor
        }

        return result
    }

    static func packetPayloads(
        packetList: UnsafePointer<MIDIPacketList>
    ) -> [[UInt8]] {
        let packetCount = Int(packetList.pointee.numPackets)
        guard packetCount > 0,
              let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet),
              let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)
        else { return [] }

        var payloads: [[UInt8]] = []
        payloads.reserveCapacity(packetCount)

        // Work directly inside CoreMIDI's original variable-length packet-list
        // buffer. Do not copy MIDIPacket and then advance relative to the copy.
        var packetPointer = UnsafeRawPointer(packetList)
            .advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)

        for packetIndex in 0..<packetCount {
            let length = Int(packetPointer.pointee.length)
            let dataPointer = UnsafeRawPointer(packetPointer)
                .advanced(by: dataOffset)
                .assumingMemoryBound(to: UInt8.self)

            payloads.append(
                Array(
                    UnsafeBufferPointer(
                        start: dataPointer,
                        count: max(0, length)
                    )
                )
            )

            // Advance inside the ORIGINAL CoreMIDI list buffer. Using
            // MIDIPacketNext is correct here because packetPointer points into
            // that buffer; the old bug called it on a copied MIDIPacket value.
            if packetIndex + 1 < packetCount {
                let mutablePacket = UnsafeMutablePointer(mutating: packetPointer)
                packetPointer = UnsafePointer(MIDIPacketNext(mutablePacket))
            }
        }

        return payloads
    }

    fileprivate func handle(packetList: UnsafePointer<MIDIPacketList>) {
        for bytes in Self.packetPayloads(packetList: packetList) {
            for event in Self.parseNoteOns(bytes: bytes) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lastMessage = "Note \(event.note) • Ch \(event.channel) • Vel \(event.velocity)"
                    self.onNoteOn?(event.note, event.channel, event.velocity)
                }
            }
        }
    }

}


enum MIDILoopbackError: LocalizedError {
    case outputPortUnavailable
    case noSelectedSource
    case noMatchingDestination(source: String, destinations: [String])
    case packetBuildFailed
    case sendFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .outputPortUnavailable:
            return "CrowdLight could not create its CoreMIDI test output port."
        case .noSelectedSource:
            return "Select the CrowdLight IAC MIDI source first."
        case .noMatchingDestination(let source, let destinations):
            let available = destinations.isEmpty ? "none" : destinations.joined(separator: ", ")
            return "No matching IAC MIDI destination was found for \(source). Available destinations: \(available)."
        case .packetBuildFailed:
            return "CrowdLight could not build the MIDI loopback packet."
        case .sendFailed(let status):
            return "CoreMIDI could not send the loopback test (OSStatus \(status))."
        }
    }
}
