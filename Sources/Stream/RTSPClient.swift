import Foundation
import Network

/// Minimal RTSP client for the embedded bridge: DESCRIBE, SETUP (RTP over the
/// RTSP TCP connection), PLAY, keep-alive. Everything runs on `queue`.
final class RTSPClient {
    enum Media { case video, audio }

    enum Failure: LocalizedError {
        case closed, timeout, status(Int, String), unsupported(String), badURL
        var errorDescription: String? {
            switch self {
            case .closed: return "Connexion fermée par le pont"
            case .timeout: return "La caméra ne répond pas"
            case .status(let code, let method): return "\(method) refusé (\(code))"
            case .unsupported(let codec): return "Codec non pris en charge : \(codec)"
            case .badURL: return "Adresse du flux invalide"
            }
        }
    }

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    var onPacket: ((Media, Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let url: URL
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var buffer = Data()
    private var cseq = 0
    private var session: String?
    private var pending: ((Result<Response, Error>) -> Void)?
    private var pendingTimer: DispatchSourceTimer?
    private var channels: [UInt8: Media] = [:]
    private var keepAlive: DispatchSourceTimer?
    private var finished = false
    private var stopped = false

    init(url: URL, queue: DispatchQueue) {
        self.url = url
        self.queue = queue
    }

    func start() {
        queue.async { [self] in
            guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554)) else {
                finish(Failure.badURL)
                return
            }
            let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            connection = c
            c.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receive()
                    self.handshake()
                case .failed(let error):
                    self.finish(error)
                case .waiting(let error):
                    self.finish(error)
                default:
                    break
                }
            }
            c.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            guard !finished else { return }
            stopped = true
            if session != nil { send("TEARDOWN", url.absoluteString, completion: nil) }
            finish(nil)
        }
    }

    // MARK: Handshake

    private func handshake() {
        send("DESCRIBE", url.absoluteString, ["Accept": "application/sdp"]) { [self] result in
            guard case .success(let r) = result else { return fail(result) }
            let sdp = String(decoding: r.body, as: UTF8.self)
            let base = r.headers["content-base"] ?? url.absoluteString
            let media = Self.parseSDP(sdp)
            guard let video = media.first(where: { $0.kind == "video" }) else {
                return finish(Failure.unsupported("pas de piste vidéo"))
            }
            guard video.codec.uppercased().hasPrefix("H264") else {
                return finish(Failure.unsupported(video.codec))
            }
            let audio = media.first(where: { $0.kind == "audio" && $0.codec.uppercased().hasPrefix("PCMU") })
            setup(Self.resolve(video.control, base: base), interleaved: 0, media: .video) { [self] in
                if let audio {
                    setup(Self.resolve(audio.control, base: base), interleaved: 2, media: .audio, optional: true) { [self] in play() }
                } else {
                    play()
                }
            }
        }
    }

    private func setup(_ control: String, interleaved ch: UInt8, media: Media, optional: Bool = false, then next: @escaping () -> Void) {
        send("SETUP", control, ["Transport": "RTP/AVP/TCP;unicast;interleaved=\(ch)-\(ch + 1)"]) { [self] result in
            switch result {
            case .success(let r):
                if let s = r.headers["session"] { session = s.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) }
                channels[ch] = media
                next()
            case .failure:
                optional ? next() : fail(result)
            }
        }
    }

    private func play() {
        send("PLAY", url.absoluteString, ["Range": "npt=0.000-"]) { [self] result in
            guard case .success = result else { return fail(result) }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 20, repeating: 20)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.send("OPTIONS", self.url.absoluteString, completion: nil)
            }
            t.resume()
            keepAlive = t
        }
    }

    private func fail(_ result: Result<Response, Error>) {
        if case .failure(let e) = result { finish(e) }
    }

    // MARK: Requests

    private func send(_ method: String, _ uri: String, _ headers: [String: String] = [:],
                      completion: ((Result<Response, Error>) -> Void)?) {
        guard let connection, !finished || method == "TEARDOWN" else { return }
        cseq += 1
        var text = "\(method) \(uri) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: BabyMonitor/1.0\r\n"
        if let session { text += "Session: \(session)\r\n" }
        for (k, v) in headers { text += "\(k): \(v)\r\n" }
        text += "\r\n"
        if let completion {
            pending = { result in
                if case .success(let r) = result, !(200..<300).contains(r.status) {
                    completion(.failure(Failure.status(r.status, method)))
                } else {
                    completion(result)
                }
            }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 40)
            t.setEventHandler { [weak self] in self?.finish(Failure.timeout) }
            t.resume()
            pendingTimer?.cancel()
            pendingTimer = t
        }
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    // MARK: Receive & parse

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parse()
            }
            if let error { return self.finish(error) }
            if complete { return self.finish(Failure.closed) }
            self.receive()
        }
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let rtspPrefix = Data("RTSP/".utf8)

    private func parse() {
        while !buffer.isEmpty && !finished {
            let s = buffer.startIndex
            let first = buffer[s]
            if first == 0x24 { // '$' interleaved RTP/RTCP
                guard buffer.count >= 4 else { return }
                let channel = buffer[s + 1]
                let length = Int(buffer[s + 2]) << 8 | Int(buffer[s + 3])
                guard buffer.count >= 4 + length else { return }
                let payload = buffer.subdata(in: (s + 4)..<(s + 4 + length))
                buffer.removeSubrange(s..<(s + 4 + length))
                if let media = channels[channel] { onPacket?(media, payload) }
            } else if first == UInt8(ascii: "R") {
                guard buffer.count >= 5 else { return }
                guard buffer.starts(with: Self.rtspPrefix) else { buffer.removeFirst(); continue }
                guard let end = buffer.range(of: Self.headerEnd) else { return }
                let head = String(decoding: buffer[s..<end.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst()
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].lowercased()
                    headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return }
                let body = buffer.subdata(in: end.upperBound..<(end.upperBound + length))
                buffer.removeSubrange(s..<(end.upperBound + length))
                let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
                let handler = pending
                pending = nil
                pendingTimer?.cancel()
                pendingTimer = nil
                handler?(.success(Response(status: status, headers: headers, body: body)))
            } else {
                buffer.removeFirst() // resync
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        keepAlive?.cancel()
        pendingTimer?.cancel()
        let handler = pending
        pending = nil
        handler?(.failure(error ?? Failure.closed))
        connection?.cancel()
        connection = nil
        if !stopped { onClose?(error ?? Failure.closed) }
    }

    // MARK: SDP

    struct MediaDescription {
        var kind: String
        var codec = ""
        var control = ""
    }

    static func parseSDP(_ sdp: String) -> [MediaDescription] {
        var out: [MediaDescription] = []
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                let kind = line.dropFirst(2).split(separator: " ").first.map(String.init) ?? ""
                out.append(MediaDescription(kind: kind))
            } else if line.hasPrefix("a=rtpmap:"), !out.isEmpty {
                let parts = line.split(separator: " ")
                if parts.count > 1 { out[out.count - 1].codec = String(parts[1]) }
            } else if line.hasPrefix("a=control:"), !out.isEmpty {
                out[out.count - 1].control = String(line.dropFirst("a=control:".count))
            }
        }
        return out
    }

    static func resolve(_ control: String, base: String) -> String {
        if control.lowercased().hasPrefix("rtsp://") { return control }
        if control.isEmpty || control == "*" { return base }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }
}

/// One RTP packet (RFC 3550).
struct RTPPacket {
    let marker: Bool
    let sequence: UInt16
    let timestamp: UInt32
    let payload: Data

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 12, b[0] >> 6 == 2 else { return nil }
        let padding = b[0] & 0x20 != 0
        let ext = b[0] & 0x10 != 0
        let csrc = Int(b[0] & 0x0F)
        marker = b[1] & 0x80 != 0
        sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        var offset = 12 + csrc * 4
        if ext {
            guard b.count >= offset + 4 else { return nil }
            offset += 4 + (Int(b[offset + 2]) << 8 | Int(b[offset + 3])) * 4
        }
        var end = b.count
        if padding, let last = b.last { end -= Int(last) }
        guard offset <= end else { return nil }
        payload = Data(b[offset..<end])
    }
}
