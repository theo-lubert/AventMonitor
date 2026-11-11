import Foundation

/// Error returned by AventCore, with Tuya's machine-readable code when there is one.
struct CoreError: LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? {
        switch code {
        case "USER_PASSWD_WRONG": return "Email ou mot de passe incorrect."
        case "MFA_CODE_ERROR", "USER_MFA_CODE_ERROR", "MFA_CODE_INVALID": return "Code de vérification incorrect ou expiré."
        case let c where c.hasPrefix("USER_SESSION"): return "La session a expiré. Reconnectez-vous."
        default: return message.isEmpty ? "Erreur inconnue" : message
        }
    }

    var isSessionExpired: Bool { code.hasPrefix("USER_SESSION") || code == "USER_NOT_LOGIN" }
}

/// Swift front for the Go library that embeds aventproxy.
/// Every call is JSON in, JSON out, and runs off the main thread.
enum AventCore {
    private static let queue = DispatchQueue(label: "AventCore.calls", qos: .userInitiated, attributes: .concurrent)

    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let result: T?
        let error: String?
        let code: String?
    }

    private struct Request<P: Encodable>: Encodable {
        let method: String
        let params: P
    }

    private struct InitResult: Decodable { let ready: Bool; let log: String? }

    /// Starts the embedded bridge's storage and logging (`bridge.log`) in `dataDirectory`.
    static func initialize(dataDirectory: URL) throws {
        let raw = dataDirectory.path.withCString { ptr -> String in
            guard let out = AventInit(UnsafeMutablePointer(mutating: ptr)) else { return "" }
            defer { AventFree(out) }
            return String(cString: out)
        }
        let _: InitResult = try decode(raw)
    }

    static func call<T: Decodable, P: Encodable>(_ method: String, _ params: P) async throws -> T {
        let body = try JSONEncoder().encode(Request(method: method, params: params))
        let json = String(decoding: body, as: UTF8.self)
        let raw: String = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: callSync(json)) }
        }
        return try decode(raw)
    }

    /// Blocking variant, for app termination.
    static func stopBridgeNow() {
        _ = callSync(#"{"method":"stopBridge","params":{}}"#)
    }

    private static func callSync(_ json: String) -> String {
        json.withCString { ptr -> String in
            guard let out = AventCall(UnsafeMutablePointer(mutating: ptr)) else { return "" }
            defer { AventFree(out) }
            return String(cString: out)
        }
    }

    private static func decode<T: Decodable>(_ raw: String) throws -> T {
        let env = try JSONDecoder().decode(Envelope<T>.self, from: Data(raw.utf8))
        if env.ok, let result = env.result { return result }
        throw CoreError(code: env.code ?? "", message: env.error ?? "")
    }
}
