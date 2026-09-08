import Foundation
import CoreMIDI
import Combine

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

        DispatchQueue.main.async {
            self.sources = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        if let source = sources.first(where: { $0.name.localizedCaseInsensitiveContains("CrowdLight") }) {
            connect(to: source.id)
            return source.id
        }
        return nil
    }

    fileprivate func handle(packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet

        for _ in 0..<packetList.pointee.numPackets {
            let length = Int(packet.length)
            if length >= 3 {
                withUnsafeBytes(of: packet.data) { rawBuffer in
                    let bytes = rawBuffer.bindMemory(to: UInt8.self)
                    var index = 0
                    while index + 2 < length {
                        let status = bytes[index]
                        let messageType = status & 0xF0
                        let channel = Int(status & 0x0F) + 1

                        if messageType == 0x90 {
                            let note = Int(bytes[index + 1])
                            let velocity = Int(bytes[index + 2])
                            if velocity > 0 {
                                DispatchQueue.main.async {
                                    self.lastMessage = "Note \(note) • Ch \(channel) • Vel \(velocity)"
                                    self.onNoteOn?(note, channel, velocity)
                                }
                            }
                            index += 3
                        } else if messageType == 0x80 || messageType == 0xA0 || messageType == 0xB0 || messageType == 0xE0 {
                            index += 3
                        } else if messageType == 0xC0 || messageType == 0xD0 {
                            index += 2
                        } else {
                            index += 1
                        }
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }
}
