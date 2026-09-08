import Foundation

struct MIDISourceInfo: Identifiable, Hashable {
    let id: Int32
    let endpoint: UInt32
    let name: String
}

enum CrowdAction: String, CaseIterable, Identifiable, Codable {
    case blackout
    case allOn
    case syncFlash
    case unison
    case twinkle
    case sparkle
    case constellation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blackout: return "BLACKOUT"
        case .allOn: return "ALL LIGHTS ON"
        case .syncFlash: return "SYNC FLASH"
        case .unison: return "UNISON"
        case .twinkle: return "TWINKLE"
        case .sparkle: return "SPARKLE"
        case .constellation: return "CONSTELLATION"
        }
    }

    var detail: String {
        switch self {
        case .blackout: return "Turn all audience flashlights off"
        case .allOn: return "Hold all audience flashlights on"
        case .syncFlash: return "One synchronized flash"
        case .unison: return "Everyone flashes together on the BPM grid"
        case .twinkle: return "Random stars, still locked to the BPM grid"
        case .sparkle: return "Sparse, short star flashes"
        case .constellation: return "Four invisible groups rotate by beat"
        }
    }

    var effectName: String? {
        switch self {
        case .unison: return "unison"
        case .twinkle: return "twinkle"
        case .sparkle: return "sparkle"
        case .constellation: return "constellation"
        default: return nil
        }
    }
}

struct CueMapping: Identifiable, Hashable {
    let id = UUID()
    let note: Int
    let action: CrowdAction

    var noteName: String { Self.noteName(note) }

    static func noteName(_ note: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let safe = max(0, min(127, note))
        let octave = (safe / 12) - 1
        return "\(names[safe % 12])\(octave)"
    }

    static let defaults: [CueMapping] = [
        CueMapping(note: 24, action: .blackout),
        CueMapping(note: 25, action: .allOn),
        CueMapping(note: 26, action: .syncFlash),
        CueMapping(note: 27, action: .unison),
        CueMapping(note: 28, action: .twinkle),
        CueMapping(note: 29, action: .sparkle),
        CueMapping(note: 30, action: .constellation)
    ]
}

struct BridgeLogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let message: String
    let success: Bool?

    var timeText: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: time)
    }
}
