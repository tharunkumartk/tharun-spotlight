import Foundation
#if canImport(Darwin)
import Darwin
private let streamType = SOCK_STREAM
private let sendFlags: Int32 = 0 // SO_NOSIGPIPE is set on the socket
#else
import Glibc
private let streamType = Int32(SOCK_STREAM.rawValue)
private let sendFlags = Int32(MSG_NOSIGNAL)
#endif

struct FSHit {
    let path: String
    let kind: String
    /// For a content search (`grep:`), the first matching line.
    let detail: String?
}

struct FSearchError: Error, CustomStringConvertible {
    let description: String
}

/// Talks to the fsearch daemon: JSON lines over
/// `~/Library/Application Support/FSearch/fsearch.sock`, one connection kept
/// open (the daemon keeps the cores warm between keystrokes for it). Starts
/// the daemon when nothing is listening, like the CLI does.
final class FSearchClient {
    let socketPath: String
    let binary: String?
    /// The last connection problem, nil while connected. Read on the main thread.
    private(set) var problem: String?

    private var fd: Int32 = -1
    private var pending = Data()
    private var started = false
    private let queue = DispatchQueue(label: "fsearch.client", qos: .userInteractive)
    private let lock = NSLock()
    private var latest = 0

    init(socketPath: String = FSearchClient.defaultSocket, binary: String? = FSearchClient.findBinary()) {
        self.socketPath = socketPath
        self.binary = binary
    }

    static var defaultSocket: String {
        NSHomeDirectory() + "/Library/Application Support/FSearch/fsearch.sock"
    }

    static func findBinary() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/fsearch",
            "/opt/homebrew/bin/fsearch",
            "/usr/local/bin/fsearch",
            Bundle.main.resourcePath.map { $0 + "/fsearch" },
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A name search (or content search, with `grep:`). Answers arrive on the
    /// main thread; a search overtaken by a newer one is dropped unanswered.
    func search(_ q: String, limit: Int, completion: @escaping (Result<[FSHit], FSearchError>) -> Void) {
        lock.lock()
        latest += 1
        let id = latest
        lock.unlock()
        queue.async {
            guard self.isLatest(id) else { return }
            let r = self.request(["q": q, "limit": limit, "boost": true]).map(Self.hits)
            guard self.isLatest(id) else { return }
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Tells fsearch you opened this, so it ranks higher for a while.
    func reportOpen(_ path: String) {
        queue.async { _ = self.request(["op": "open", "path": path]) }
    }

    /// Connects (starting the daemon if needed) ahead of the first search.
    func warmUp() {
        queue.async { _ = self.request(["op": "ping"]) }
    }

    private func isLatest(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return id == latest
    }

    static func hits(_ v: [String: Any]) -> [FSHit] {
        if let files = v["files"] as? [[String: Any]] {
            return files.compactMap { f in
                guard let path = f["path"] as? String else { return nil }
                let m = (f["matches"] as? [[String: Any]])?.first
                let detail = m.map { "\($0["line"] ?? ""): " + (($0["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces) }
                return FSHit(path: path, kind: "file", detail: detail)
            }
        }
        let hits = v["hits"] as? [[String: Any]] ?? []
        return hits.compactMap { h in
            (h["path"] as? String).map { FSHit(path: $0, kind: h["kind"] as? String ?? "file", detail: nil) }
        }
    }

    // MARK: - On `queue`

    private func request(_ obj: [String: Any]) -> Result<[String: Any], FSearchError> {
        let r = exchange(obj)
        let problem: String?
        switch r {
        case .success: problem = nil
        case .failure(let e): problem = e.description
        }
        DispatchQueue.main.async { self.problem = problem }
        return r
    }

    private func exchange(_ obj: [String: Any]) -> Result<[String: Any], FSearchError> {
        guard var body = try? JSONSerialization.data(withJSONObject: obj) else {
            return .failure(FSearchError(description: "bad request"))
        }
        body.append(0x0a)
        for _ in 0..<2 {
            if fd < 0, let e = connectOrStart() { return .failure(e) }
            if writeAll(body), let line = readLine() {
                guard let v = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    return .failure(FSearchError(description: "fsearch sent something unreadable"))
                }
                if v["ok"] as? Bool == true { return .success(v) }
                return .failure(FSearchError(description: v["error"] as? String ?? "fsearch error"))
            }
            // A dead connection (daemon restarted) or a timeout: start over.
            disconnect()
        }
        return .failure(FSearchError(description: "fsearch isn't answering (still indexing?)"))
    }

    private func connectOrStart() -> FSearchError? {
        if tryConnect() { return nil }
        guard let bin = binary else {
            return FSearchError(description: "fsearch isn't installed: run build.sh again, or put it in ~/.local/bin")
        }
        if !started {
            started = true
            startDaemon(bin)
        }
        for _ in 0..<150 {
            usleep(20_000)
            if tryConnect() { return nil }
        }
        return FSearchError(description: "can't reach the fsearch daemon (see ~/Library/Application Support/FSearch/daemon.log)")
    }

    private func startDaemon(_ bin: String) {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = dir + "/daemon.log"
        if !FileManager.default.fileExists(atPath: log) { _ = FileManager.default.createFile(atPath: log, contents: nil) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["MallocSpaceEfficient"] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        if let h = FileHandle(forWritingAtPath: log) {
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        }
        try? p.run()
    }

    private func tryConnect() -> Bool {
        let s = socket(AF_UNIX, streamType, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(s)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        #if canImport(Darwin)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        // A first search can wait on the index loading; past this, give up and reconnect.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        guard ok else {
            close(s)
            return false
        }
        fd = s
        pending.removeAll()
        started = false
        return true
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        pending.removeAll()
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            while off < raw.count {
                let n = send(fd, base + off, raw.count - off, sendFlags)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                off += n
            }
            return true
        }
    }

    private func readLine() -> Data? {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            if let nl = pending.firstIndex(of: 0x0a) {
                let line = Data(pending[pending.startIndex..<nl])
                pending = Data(pending[pending.index(after: nl)...])
                return line
            }
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return nil }
            pending.append(buf, count: n)
        }
    }
}
