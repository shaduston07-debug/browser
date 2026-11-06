import Foundation
import WebKit

/// Opens WebSockets for extensions from the app, so they can carry the same Origin Chrome would send
/// (chrome-extension://<Chrome Web Store ID>). Servers like Claude's bridge reject WebKit's own
/// webkit-extension:// origin. The extension side talks to this through runtime.connectNative.
final class NativeWebSocketProxy: NSObject, URLSessionWebSocketDelegate {
    @MainActor private static var live: [ObjectIdentifier: NativeWebSocketProxy] = [:]

    private let port: WKWebExtension.MessagePort
    private let origin: String?
    private let extensionName: String
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var label = ""
    private var finished = false

    @MainActor
    static func attach(to port: WKWebExtension.MessagePort, storeID: String?, extensionName: String) {
        let origin = storeID.flatMap { ChromeWebStore.isExtensionID($0) ? "chrome-extension://\($0)" : nil }
        let proxy = NativeWebSocketProxy(port: port, origin: origin, extensionName: extensionName)
        live[ObjectIdentifier(proxy)] = proxy
    }

    @MainActor
    private init(port: WKWebExtension.MessagePort, origin: String?, extensionName: String) {
        self.port = port
        self.origin = origin
        self.extensionName = extensionName
        super.init()
        port.messageHandler = { [weak self] message, _ in
            Task { @MainActor [weak self] in self?.handle(message) }
        }
        port.disconnectHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.shutdown(notify: false) }
        }
    }

    // MARK: Messages from the extension

    @MainActor
    private func handle(_ message: Any?) {
        guard let body = message as? [String: Any], let command = body["inkwell"] as? String else { return }
        switch command {
        case "ws.open":
            guard let urlString = body["url"] as? String, let url = URL(string: urlString) else {
                post(["type": "close", "code": 1006, "reason": "bad url", "wasClean": false])
                return
            }
            open(url: url, protocols: body["protocols"] as? [String] ?? [])
        case "ws.send":
            if let text = body["text"] as? String {
                task?.send(.string(text)) { _ in }
            } else if let b64 = body["base64"] as? String, let data = Data(base64Encoded: b64) {
                task?.send(.data(data)) { _ in }
            }
        case "ws.close":
            let code = URLSessionWebSocketTask.CloseCode(rawValue: body["code"] as? Int ?? 1000) ?? .normalClosure
            let reason = (body["reason"] as? String)?.data(using: .utf8)
            task?.cancel(with: code, reason: reason)
        default:
            break
        }
    }

    @MainActor
    private func open(url: URL, protocols: [String]) {
        label = (url.host ?? "") + url.path
        var request = URLRequest(url: url)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.setValue(UserAgentMode.chromeMac.string, forHTTPHeaderField: "User-Agent")
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        log("info", "Native WebSocket connecting: \(label) (origin \(origin ?? "default"))")
        task.resume()
    }

    @MainActor
    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    self.post(["type": "message", "text": text])
                    self.receive()
                case .success(.data(let data)):
                    self.post(["type": "message", "base64": data.base64EncodedString()])
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    break // didCompleteWithError / didClose report the outcome
                }
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate (delivered on the main queue)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol negotiated: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log("info", "Native WebSocket open: \(self.label)")
            self.post(["type": "open", "protocol": negotiated ?? ""])
            self.receive()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let code = closeCode.rawValue
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log("warn", "Native WebSocket closed: \(self.label) (code \(code)\(text.isEmpty ? "" : ", \(text)"))")
            self.post(["type": "close", "code": code, "reason": text, "wasClean": true])
            self.shutdown(notify: false)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let message = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, !self.finished else { return }
            guard let message else { return }
            self.log("error", "Native WebSocket failed: \(self.label) — \(message)" + (status.map { " (HTTP \($0))" } ?? ""))
            self.post(["type": "error"])
            self.post(["type": "close", "code": 1006, "reason": status.map { "HTTP \($0)" } ?? message, "wasClean": false])
            self.shutdown(notify: false)
        }
    }

    // MARK: Helpers

    @MainActor
    private func post(_ message: [String: Any]) {
        guard !finished else { return }
        port.sendMessage(message) { _ in }
    }

    @MainActor
    private func shutdown(notify: Bool) {
        guard !finished else { return }
        if notify { post(["type": "close", "code": 1001, "reason": "", "wasClean": true]) }
        finished = true
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        port.disconnect()
        Self.live[ObjectIdentifier(self)] = nil
    }

    @MainActor
    private func log(_ level: String, _ text: String) {
        ExtensionLogStore.shared.add(extension: extensionName, level: level, where: "app", text: text)
    }
}
