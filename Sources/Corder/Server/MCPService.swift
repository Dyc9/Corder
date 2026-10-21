import Foundation
import Swifter

/// Model Context Protocol endpoint, so an AI client (Claude Code, Claude
/// Desktop, Cursor…) can hand Corder an audio file to transcribe ON THIS MAC
/// and keep the result as a session, and read the user's sessions back.
///
/// Transport: MCP's Streamable HTTP in its simplest form, one JSON-RPC
/// message per `POST /mcp`, answered with `application/json` (no SSE, no
/// sessions). Clients speak stdio, so the bundle ships `corder-mcp`, a tiny
/// bridge that forwards each stdin line here and prints the reply.
///
/// Auth: a random token in `mcp.json` (0600, next to the accounts folder),
/// sent as `Authorization: Bearer`. The local server answers any local
/// process, and this endpoint can read every transcript and write files
/// into the Library, so it must not be open the way plain GETs are. The
/// token is never served over HTTP (the old /mcp-token endpoint handed out
/// the Supabase JWT to anyone, see 0fcce88). Reading it needs the same
/// user's file access the recordings themselves need.
enum MCPService {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static var discoveryURL: URL { AppPaths.supportRoot.appendingPathComponent("mcp.json") }

    /// Writes `{port, token}` for the bridge; keeps an existing token so a
    /// configured client survives relaunches.
    static func publish(port: UInt16) {
        let fm = FileManager.default
        var token = ""
        if let data = try? Data(contentsOf: discoveryURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = obj["token"] as? String, t.count >= 32 {
            token = t
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            token = bytes.map { String(format: "%02x", $0) }.joined()
        }
        currentToken.withLock { $0 = token }
        let payload: [String: Any] = ["port": Int(port), "token": token, "pid": Int(getpid())]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? fm.createDirectory(at: discoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: discoveryURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: discoveryURL.path)
        } catch {
            FileLogger.log("MCP: could not write \(discoveryURL.lastPathComponent): \(error)")
        }
    }

    private static let currentToken = LockedValue("")

    static func register(on server: HttpServer) {
        server.post["/mcp"] = { req in handle(req) }
        server.get["/mcp"] = { _ in .raw(405, "Method Not Allowed", ["Allow": "POST"], nil) }
    }

    // MARK: - JSON-RPC

    private static func handle(_ req: HttpRequest) -> HttpResponse {
        let (status, body) = respond(to: Data(req.body), authorization: req.headers["authorization"] ?? "")
        switch status {
        case 200:
            return .raw(200, "OK", ["Content-Type": "application/json"]) { try $0.write(body ?? Data("{}".utf8)) }
        case 202:
            return .raw(202, "Accepted", nil, nil)
        default:
            return .raw(401, "Unauthorized", ["Content-Type": "application/json"]) {
                try $0.write(Data(#"{"error":"missing or wrong Corder MCP token"}"#.utf8))
            }
        }
    }

    /// Transport-free core of `POST /mcp`: 401 without the token, 202 for a
    /// notification, otherwise 200 with the JSON-RPC response.
    static func respond(to body: Data, authorization: String) -> (status: Int, body: Data?) {
        let expected = currentToken.withLock { $0 }
        guard !expected.isEmpty, constantTimeEquals(authorization, "Bearer \(expected)") else {
            return (401, nil)
        }
        guard let message = try? JSONSerialization.jsonObject(with: body) else {
            return (200, encode(errorFor(id: NSNull(), code: -32700, message: "Parse error")))
        }
        if let batch = message as? [[String: Any]] {
            let out = batch.compactMap { dispatch($0) }
            return out.isEmpty ? (202, nil) : (200, encode(out))
        }
        guard let obj = message as? [String: Any] else {
            return (200, encode(errorFor(id: NSNull(), code: -32600, message: "Invalid Request")))
        }
        guard let out = dispatch(obj) else { return (202, nil) }
        return (200, encode(out))
    }

    /// Test hook: set the token without touching the real discovery file.
    static func setTokenForTesting(_ token: String) { currentToken.withLock { $0 = token } }

    /// nil for notifications (no `id`), which get no response body.
    private static func dispatch(_ msg: [String: Any]) -> [String: Any]? {
        let method = msg["method"] as? String ?? ""
        guard let id = msg["id"] else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = protocolVersions.contains(asked) ? asked : protocolVersions[0]
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "corder", "title": "Corder", "version": appVersion],
                "instructions": """
                    Corder is the user's meeting recorder on this Mac. `transcribe_audio` transcribes an audio or video \
                    file on this Mac (on-device model by default, nothing is uploaded) and saves the result as a session \
                    in the user's Corder library; give it an absolute path. Use list_meetings / search_transcripts / \
                    get_meeting to read existing sessions.
                    """,
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": MCPTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let sendableArgs = UncheckedArgs(value: args)
            let timeout = MCPTools.timeout(for: name, args: args)
            let outcome = Routes.awaitBlocking(timeout: timeout, label: "MCP \(name)") { () -> MCPTools.Output? in
                await MCPTools.call(name: name, args: sendableArgs.value)
            } ?? MCPTools.Output(text: "Corder did not answer within \(Int(timeout)) s.", isError: true)
            return result(id: id, [
                "content": [["type": "text", "text": outcome.text]],
                "isError": outcome.isError,
            ])
        default:
            return errorFor(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private struct UncheckedArgs: @unchecked Sendable { let value: [String: Any] }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func errorFor(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func encode(_ body: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// A value behind a lock (Swifter threads read the token the main thread set).
final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
