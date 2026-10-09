import Foundation
import IdentifyKit
import Network
import Observation

// A tiny HTTP server on 127.0.0.1 that speaks CDDB, so XLD (or any ripper
// with a configurable freedb server) can ask drtagger for disc metadata.
// Point XLD's CDDB server at localhost, port `port`, path /~cddb/cddb.cgi.
@Observable
@MainActor
final class CDDBServer {

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var requestCount = 0
    private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private let responder = CDDBResponder(userAgent: IdentifyService.userAgent)
    private let queue = DispatchQueue(label: "us.priet.drtagger.cddb")

    func update(enabled: Bool, port: Int) {
        let wanted = UInt16(clamping: port)
        if enabled, isRunning, wanted == self.port { return }
        stop()
        guard enabled else { return }
        start(port: wanted)
    }

    private func start(port: UInt16) {
        lastError = nil
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 8880)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                    case .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                Task { @MainActor in self.serve(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
            self.port = port
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // One request per connection (HTTP/1.0 style): read the request line,
    // answer, close.
    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        let responder = self.responder
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } ?? ""
            Task {
                let body: String
                var status = "200 OK"
                if let query = Self.query(fromRequest: request) {
                    body = await responder.respond(toQuery: query)
                } else {
                    status = "400 Bad Request"
                    body = "500 Command syntax error.\n"
                }
                let response = "HTTP/1.0 \(status)\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                await MainActor.run { self?.requestCount += 1 }
            }
        }
    }

    // "GET /~cddb/cddb.cgi?cmd=… HTTP/1.1" → "cmd=…". POST bodies (some
    // clients) carry the same form after the blank line.
    nonisolated static func query(fromRequest request: String) -> String? {
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        if parts[0] == "POST", let blank = request.range(of: "\r\n\r\n") {
            let body = String(request[blank.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        }
        let target = String(parts[1])
        guard let q = target.firstIndex(of: "?") else { return nil }
        return String(target[target.index(after: q)...])
    }
}
