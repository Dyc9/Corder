import Foundation

// corder-mcp: the stdio side of Corder's MCP server.
//
// MCP clients (Claude Code, Claude Desktop, Cursor) start a command and talk
// JSON-RPC over its stdin/stdout, one message per line. Corder serves MCP on
// its loopback HTTP server (`POST /mcp`, see MCPService.swift); this bridge
// forwards every line there and prints the reply. Port and token come from
// ~/Library/Application Support/Corder/mcp.json, which the app rewrites on
// every launch. If Corder isn't running it is started in the background.
//
//   claude mcp add corder -- /Applications/Corder.app/Contents/MacOS/corder-mcp

let discoveryURL = ProcessInfo.processInfo.environment["CORDER_MCP_DISCOVERY"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Corder/mcp.json")

struct Endpoint { let url: URL; let token: String }

func readEndpoint() -> Endpoint? {
    guard let data = try? Data(contentsOf: discoveryURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = obj["port"] as? Int, let token = obj["token"] as? String,
          let url = URL(string: "http://127.0.0.1:\(port)/mcp") else { return nil }
    return Endpoint(url: url, token: token)
}

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    // A transcription can legitimately take most of an hour.
    c.timeoutIntervalForRequest = 4000
    c.timeoutIntervalForResource = 4000
    return URLSession(configuration: c)
}()

func log(_ s: String) {
    FileHandle.standardError.write(Data("corder-mcp: \(s)\n".utf8))
}

actor Output {
    func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
let output = Output()

actor Launcher {
    private var launched = false
    private var known: Endpoint?
    /// Starts Corder (hidden, in the background) once and waits until its
    /// MCP endpoint answers. The endpoint is reused until a request to it
    /// fails (`recheck`), then re-read: a relaunch may change the port.
    func ensureRunning(recheck: Bool = false) async -> Endpoint? {
        if !recheck, let known { return known }
        if let e = readEndpoint(), await reachable(e) { known = e; return e }
        if !launched {
            launched = true
            log("Corder is not running, starting it")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-j", "-b", "com.3mpq.Corder"]
            try? p.run()
            p.waitUntilExit()
        }
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let e = readEndpoint(), await reachable(e) { known = e; return e }
        }
        known = nil
        return nil
    }

    private func reachable(_ e: Endpoint) async -> Bool {
        var req = URLRequest(url: e.url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("Bearer \(e.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":"probe","method":"ping"}"#.utf8)
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
let launcher = Launcher()

func forward(_ line: Data) async {
    let id = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["id"]
    for attempt in 0..<2 {
        guard let e = await launcher.ensureRunning(recheck: attempt > 0) else { break }
        var req = URLRequest(url: e.url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(e.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = line
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 202 { return }                         // notification
            if status == 200, !data.isEmpty { await output.write(data); return }
            log("HTTP \(status) from Corder")
        } catch {
            log("request failed (\(error.localizedDescription))\(attempt == 0 ? ", retrying" : "")")
        }
    }
    // Answer requests (not notifications) so the client doesn't hang.
    guard let id else { return }
    let err: [String: Any] = ["jsonrpc": "2.0", "id": id,
                              "error": ["code": -32000, "message": "Corder is not reachable. Open Corder and try again."]]
    if let data = try? JSONSerialization.data(withJSONObject: err) { await output.write(data) }
}

// Each message runs on its own task: a long transcribe_audio must not hold
// up a ping or a tools/list that arrives meanwhile.
await withTaskGroup(of: Void.self) { group in
    do {
        for try await line in FileHandle.standardInput.bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let data = Data(trimmed.utf8)
            group.addTask { await forward(data) }
        }
    } catch {
        log("stdin closed: \(error.localizedDescription)")
    }
}
