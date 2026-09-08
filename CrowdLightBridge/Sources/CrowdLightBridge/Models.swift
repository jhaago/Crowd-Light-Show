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
    case shimmer
    case twinkle
    case sparkle
    case glow
    case fireflies
    case alternate
    case constellation
    case build
    case drop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blackout: return "BLACKOUT"
        case .allOn: return "ALL LIGHTS ON"
        case .syncFlash: return "SYNC FLASH"
        case .unison: return "UNISON"
        case .shimmer: return "SHIMMER"
        case .twinkle: return "TWINKLE"
        case .sparkle: return "SPARKLE"
        case .glow: return "GLOW"
        case .fireflies: return "FIREFLIES"
        case .alternate: return "ALTERNATE"
        case .constellation: return "CONSTELLATION"
        case .build: return "BUILD"
        case .drop: return "DROP"
        }
    }

    var detail: String {
        switch self {
        case .blackout: return "Turn all audience flashlights off"
        case .allOn: return "Hold all audience flashlights on"
        case .syncFlash: return "One synchronized flash"
        case .unison: return "Everyone flashes together on the BPM grid"
        case .shimmer: return "Rapid-looking staggered sparkle across phone groups"
        case .twinkle: return "Random stars, still locked to the BPM grid"
        case .sparkle: return "Sparse, short star flashes"
        case .glow: return "Long synchronized ON/OFF holds"
        case .fireflies: return "Sparse phones glow for longer at different times"
        case .alternate: return "Two invisible crowd halves swap ON and OFF"
        case .constellation: return "Four invisible groups rotate by beat"
        case .build: return "Participation grows from sparse to full across eight beats"
        case .drop: return "Dark pattern beats followed by a synchronized crowd hit"
        }
    }

    var effectName: String? {
        switch self {
        case .unison: return "unison"
        case .shimmer: return "shimmer"
        case .twinkle: return "twinkle"
        case .sparkle: return "sparkle"
        case .glow: return "glow"
        case .fireflies: return "fireflies"
        case .alternate: return "alternate"
        case .constellation: return "constellation"
        case .build: return "build"
        case .drop: return "drop"
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
        CueMapping(note: 30, action: .constellation),
        CueMapping(note: 31, action: .shimmer),
        CueMapping(note: 32, action: .glow),
        CueMapping(note: 33, action: .fireflies),
        CueMapping(note: 34, action: .alternate),
        CueMapping(note: 35, action: .build),
        CueMapping(note: 36, action: .drop)
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
