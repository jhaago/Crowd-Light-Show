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

final class MIDIManager: ObservableObject {
    @Published var sources: [MIDISourceInfo] = []
    @Published var connectedSourceID: Int32 = 0
    @Published var connectedSourceName: String = "Not connected"
    @Published var lastMessage: String = "No MIDI received"

    var onNoteOn: ((Int, Int, Int) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
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
        if client != 0 { MIDIClientDispose(client) }
    }

    private func createClient() {
        let clientStatus = MIDIClientCreate("CrowdLight Bridge" as CFString, nil, nil, &client)
        guard clientStatus == noErr else {
            lastMessage = "Could not create CoreMIDI client (\(clientStatus))"
            return
        }

        let refCon = Unmanaged.passUnretained(self).toOpaque()
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

    static func parseNoteOns(bytes: [UInt8]) -> [ParsedMIDINoteOn] {
        var result: [ParsedMIDINoteOn] = []
        var index = 0

        while index < bytes.count {
            let status = bytes[index]

            // CoreMIDI packet data uses complete MIDI messages; running status is
            // not expected here. Stray data bytes are ignored defensively.
            if status < 0x80 {
                index += 1
                continue
            }

            // Single-byte realtime messages may be interleaved.
            if status >= 0xF8 {
                index += 1
                continue
            }

            if status >= 0xF0 {
                switch status {
                case 0xF0:
                    // Skip SysEx through EOX, or to packet end for a fragment.
                    index += 1
                    while index < bytes.count && bytes[index] != 0xF7 {
                        index += 1
                    }
                    if index < bytes.count { index += 1 }
                case 0xF1, 0xF3:
                    index += min(2, bytes.count - index)
                case 0xF2:
                    index += min(3, bytes.count - index)
                default:
                    index += 1
                }
                continue
            }

            let messageType = status & 0xF0
            let channel = Int(status & 0x0F) + 1
            let length = (messageType == 0xC0 || messageType == 0xD0) ? 2 : 3

            guard index + length <= bytes.count else {
                break
            }

            if messageType == 0x90 {
                let note = Int(bytes[index + 1])
                let velocity = Int(bytes[index + 2])
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

            index += length
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
