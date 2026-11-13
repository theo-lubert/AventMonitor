import Foundation

/// One data point value (Tuya "DPS"). Cameras use booleans, integers and strings.
enum DPValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)
    /// Anything else (objects, arrays, fractions): kept so a read never fails, never sent.
    case other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            self = .other
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        case .other: try c.encodeNil()
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string("1"), .string("true"): return true
        case .string("0"), .string("false"): return false
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .int(let i): return i
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// What `deviceState` returns: the camera's data points as the cloud last saw them.
struct DeviceSnapshot: Decodable, Equatable {
    let online: Bool
    let dps: [String: DPValue]
}

struct DeviceParams: Encodable {
    let session: Session
    let id: String
}

struct SetDPSParams: Encodable {
    let session: Session
    let id: String
    let dps: [String: DPValue]
}

/// Data point codes, from aventproxy's examples/DPS_REFERENCE.md.
enum DP {
    static let nightLight = "138"
    static let brightness = "158"
    static let lightTimer = "240"
    static let lightTimerOn = "241"
    static let lightRemaining = "242"
    static let lullabyControl = "201"
    static let lullabyTrack = "202"
    static let lullabyMode = "203"
    static let temperature = "207"
    static let volume = "209"
    static let lullabyTimerOn = "243"
    static let lullabyTimer = "244"
    static let lullabyRemaining = "245"
    static let lullabyState = "246"
    static let lullabyCurrent = "248"
}

enum PlayMode: String, CaseIterable, Identifiable {
    case loop, loop1, shuffle
    var id: String { rawValue }

    var label: String {
        switch self {
        case .loop: return "Tout répéter"
        case .loop1: return "Répéter le morceau"
        case .shuffle: return "Aléatoire"
        }
    }

    var systemImage: String {
        switch self {
        case .loop: return "repeat"
        case .loop1: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }
}

/// The 15 sounds built into the monitor, in id order (which is also the order Next follows).
enum Lullaby {
    enum Category: String, CaseIterable {
        case lullabies = "Berceuses"
        case noise = "Bruits apaisants"
        case nature = "Nature"
    }

    struct Track: Identifiable, Equatable {
        let index: Int
        let name: String
        let category: Category
        var id: Int { index }
    }

    static let catalogue: [Track] = [
        ("Baa Baa Black Sheep", Category.lullabies),
        ("Berceuse de Brahms", .lullabies),
        ("Rock-a-Bye Baby", .lullabies),
        ("Golden Slumbers", .lullabies),
        ("Hush Little Baby", .lullabies),
        ("Chut de maman", .noise),
        ("Rivière apaisante", .noise),
        ("Battements de cœur", .noise),
        ("Aspirateur", .noise),
        ("Bruit blanc", .noise),
        ("Chant des oiseaux", .nature),
        ("Vent dans la vallée", .nature),
        ("Bord de mer", .nature),
        ("Nature la nuit", .nature),
        ("Averse", .nature),
    ].enumerated().map { Track(index: $0.offset, name: $0.element.0, category: $0.element.1) }

    /// First id of each block the catalogue is published under. Units of the same product
    /// use different blocks, and a camera ignores an id outside its own (aventproxy #91).
    static let blockStarts = [3_542_154, 12_072_916]

    static func track(id: Int?) -> Track? {
        guard let id else { return nil }
        for start in blockStarts where (start..<start + catalogue.count).contains(id) {
            return catalogue[id - start]
        }
        return nil
    }

    /// The id to send to play `track`, in the block of the id the camera last reported.
    static func id(of track: Track, current: Int?) -> Int {
        let start = blockStarts.first { start in
            current.map { (start..<start + catalogue.count).contains($0) } ?? false
        } ?? blockStarts[0]
        return start + track.index
    }

    /// DPS 202's payload, as the official app sends it.
    static func playPayload(id: Int) -> String {
        #"{"bizcode":"phi-no-bm","id":\#(id)}"#
    }

    /// The track id inside DPS 248, a JSON string like `{"bizcode":"phi-no-bm","id":3542155,"errcode":0}`.
    static func currentID(in value: DPValue?) -> Int? {
        guard let text = value?.string, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["id"] as? NSNumber)?.intValue
    }
}

/// Timer choices offered for the night light and lullabies, in seconds. The monitor accepts up to 90 min.
enum RoomTimer {
    static let choices: [Int] = [900, 1800, 3600, 5400]

    static func label(_ seconds: Int) -> String {
        seconds >= 3600 && seconds % 3600 == 0 ? "\(seconds / 3600) h"
            : seconds > 3600 ? "\(seconds / 3600) h \((seconds % 3600) / 60)" : "\(seconds / 60) min"
    }

    /// "18 min", "1 h 05", or "< 1 min".
    static func remaining(_ seconds: Int) -> String {
        if seconds < 60 { return "< 1 min" }
        let minutes = (seconds + 59) / 60
        return minutes >= 60 ? String(format: "%d h %02d", minutes / 60, minutes % 60) : "\(minutes) min"
    }
}

/// A camera's room controls, read from its data points. Every field is nil until the
/// camera has reported it, so the interface never shows a guess as a fact.
struct RoomState: Equatable {
    var online: Bool
    var dps: [String: DPValue]

    var nightLight: Bool? { dps[DP.nightLight]?.bool }
    var brightness: Int? { dps[DP.brightness]?.int }
    /// Auto-off delay in seconds, nil when off.
    var lightTimer: Int? { dps[DP.lightTimerOn]?.bool == true ? dps[DP.lightTimer]?.int : nil }
    var lightRemaining: Int? { dps[DP.lightRemaining]?.int.flatMap { $0 > 0 ? $0 : nil } }

    var lullabyPlaying: Bool? { dps[DP.lullabyState]?.string.map { $0 == "playing" } }
    var currentTrackID: Int? { Lullaby.currentID(in: dps[DP.lullabyCurrent]) }
    var currentTrack: Lullaby.Track? { Lullaby.track(id: currentTrackID) }
    var volume: Int? { dps[DP.volume]?.int }
    var playMode: PlayMode? { dps[DP.lullabyMode]?.string.flatMap(PlayMode.init(rawValue:)) }
    var lullabyTimer: Int? { dps[DP.lullabyTimerOn]?.bool == true ? dps[DP.lullabyTimer]?.int : nil }
    var lullabyRemaining: Int? { dps[DP.lullabyRemaining]?.int.flatMap { $0 > 0 ? $0 : nil } }

    /// °C. The camera reports hundredths of a degree.
    var temperature: Double? { dps[DP.temperature]?.int.map { Double($0) / 100 } }
}
