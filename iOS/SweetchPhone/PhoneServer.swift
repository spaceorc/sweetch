import Foundation
import Network
import UIKit

/// What the app heard, for the keyboard on the same phone: a tiny server on the loopback address,
/// answering the keyboard as a Mac's dictation server does (`/ping`, `/next`). It's how a dictation
/// heard on the phone itself reaches the field — the keyboard can't see the app's files, and needs
/// no Mac for this. Alive while the app is (right after a dictation it is).
final class PhoneServer: @unchecked Sendable {
    static let shared = PhoneServer()
    static let port: UInt16 = 8181

    private let queue = DispatchQueue(label: "sweetch.phone-server", attributes: .concurrent)
    private var listener: NWListener?
    private let heard = NSCondition()
    private var latest: (seq: Int, text: String)?
    private var delivered = false

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// A dictation's text, for the keyboard waiting on `/next`.
    func publish(_ text: String) {
        guard !text.isEmpty else { return }
        heard.lock()
        latest = (Int(Date().timeIntervalSince1970 * 1000), text)
        delivered = false
        heard.broadcast()
        heard.unlock()
        stayAwake()
    }

    /// Behind, iOS suspends the app as soon as it has nothing to do — before the keyboard, waiting
    /// on `/next` or coming back to the field, has the text. A few seconds for it.
    private func stayAwake() {
        DispatchQueue.main.async {
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
            Task.detached { [self] in
                for _ in 0..<40 {
                    if heard.withLock({ delivered }) { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                // The answer on its way out.
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else { connection.cancel(); return }
            let parts = line.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let components = URLComponents(string: target)
            var reply: [String: Any] = ["ok": true]
            if components?.path == "/next" {
                let items = components?.queryItems ?? []
                let after = Int(items.first { $0.name == "after" }?.value ?? "") ?? 0
                let wait = min(Double(items.first { $0.name == "wait" }?.value ?? "") ?? 25, 25)
                reply = self.next(after: after, wait: wait)
            }
            let body = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func next(after: Int, wait: TimeInterval) -> [String: Any] {
        let deadline = Date().addingTimeInterval(wait)
        heard.lock()
        defer { heard.unlock() }
        while (latest?.seq ?? 0) <= after, heard.wait(until: deadline) {}
        guard let latest, latest.seq > after else { return ["seq": after] }
        delivered = true
        return ["seq": latest.seq, "text": latest.text]
    }
}
