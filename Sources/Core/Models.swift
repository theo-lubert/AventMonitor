import Foundation

/// A logged-in Baby Monitor+ session. Stored in the Keychain; the password never is.
struct Session: Codable, Equatable {
    var sid: String
    var ecode: String
    var partner: String
    var uid: String
    var email: String
    var nickname: String
    var apiHost: String
    var deviceId: String
    var country: String
}

struct Camera: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let productId: String
    let category: String
    let online: Bool
}

struct BridgeInfo: Codable, Equatable {
    let port: Int
    let cameras: [BridgeCamera]
}

struct BridgeCamera: Codable, Equatable {
    let id: String
    let name: String
    let path: String
    let url: String
}

struct UserInfo: Decodable {
    let id: String
    let email: String
    let nickname: String
}

struct LoginStep: Decodable {
    let session: Session?
    let codeSent: Bool?
}

struct LoginParams: Encodable {
    var email: String
    var password: String
    var country: String
    var code: String = ""
    var apiHost: String
    var deviceId: String
}

struct StartBridgeParams: Encodable {
    let session: Session
    let cameras: [Camera]
    let port: Int
}

/// Country codes offered at login. The data center follows the account's region.
struct Country: Identifiable, Hashable {
    let code: String
    let name: String
    let apiHost: String
    var id: String { name }

    static let all: [Country] = [
        Country(code: "33", name: "France", apiHost: "a1.tuyaeu.com"),
        Country(code: "32", name: "Belgique", apiHost: "a1.tuyaeu.com"),
        Country(code: "41", name: "Suisse", apiHost: "a1.tuyaeu.com"),
        Country(code: "352", name: "Luxembourg", apiHost: "a1.tuyaeu.com"),
        Country(code: "49", name: "Allemagne", apiHost: "a1.tuyaeu.com"),
        Country(code: "34", name: "Espagne", apiHost: "a1.tuyaeu.com"),
        Country(code: "39", name: "Italie", apiHost: "a1.tuyaeu.com"),
        Country(code: "31", name: "Pays-Bas", apiHost: "a1.tuyaeu.com"),
        Country(code: "44", name: "Royaume-Uni", apiHost: "a1.tuyaeu.com"),
        Country(code: "1", name: "États-Unis", apiHost: "a1.tuyaus.com"),
        Country(code: "1", name: "Canada", apiHost: "a1.tuyaus.com"),
        Country(code: "91", name: "Inde", apiHost: "a1.tuyain.com"),
    ]
}
