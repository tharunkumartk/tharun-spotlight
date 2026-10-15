import Foundation

struct MeaningHit {
    let path: String
    /// "pdf", "doc", "image", "screenshot", "audio", "video".
    let kind: String
    /// Cosine similarity of the best passage, when it matched by meaning.
    let cosine: Double?
    /// How far that passage stands out from everything indexed, in standard
    /// deviations (DigUp's own gate for a meaning match).
    let z: Double?
    /// 1-based rank among exact-word matches, when it matched by words.
    let keywordRank: Int?
    /// PDF page, or seconds into audio or video.
    let loc: Double?
    let excerpt: String?
}

/// Searches files by what's in them through DigUp (github.com/ARahim3/DigUp),
/// which indexes the folders you pick in its app with EmbeddingGemma 2, on
/// this Mac. Runs its `digup search-service` helper: JSON lines over a pipe,
/// the index open and the query encoder warm between keystrokes. Nothing is
/// sent anywhere.
final class DigUpClient {
    let binary: String?
    /// "not installed", or what the index held when file search last opened. Read on the main thread.
    private(set) var status: String

    private var process: Process?
    private var input: FileHandle?
    private let lock = NSLock()
    private var nextID = 0
    private var waiting: [Int: ([String: Any]?) -> Void] = [:]
    /// One search in flight at a time; a newer query typed meanwhile waits
    /// here, replacing any older one that hadn't been sent.
    private var inFlight = false
    private var queued: (q: String, limit: Int, completion: ([MeaningHit]) -> Void)?

    init(binary: String? = DigUpClient.findBinary()) {
        self.binary = binary
        status = binary == nil ? "not installed (brew install --cask arahim3/tap/digup)" : "idle"
    }

    var isAvailable: Bool { binary != nil }

    static func findBinary() -> String? {
        let candidates = [
            "/Applications/DigUp.app/Contents/Helpers/digup",
            NSHomeDirectory() + "/Applications/DigUp.app/Contents/Helpers/digup",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The strong matches for `q` (DigUp's own cut: within half the top
    /// score), best first, on the main thread. A search overtaken by a newer
    /// one before it was sent is dropped unanswered.
    func search(_ q: String, limit: Int, completion: @escaping ([MeaningHit]) -> Void) {
        lock.lock()
        if inFlight {
            queued = (q, limit, completion)
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()
        send(["op": "search", "q": q, "limit": limit, "meaning": true]) { [weak self] reply in
            let hits = reply.map(Self.hits) ?? []
            DispatchQueue.main.async { completion(hits) }
            self?.sendQueued()
        }
    }

    /// Starts the helper and loads the model and vectors, ahead of a search;
    /// picks up what DigUp indexed since last time.
    func warmUp() {
        guard isAvailable else { return }
        send(["op": "reload"]) { _ in }
        send(["op": "prewarm"]) { [weak self] reply in
            let text: String
            switch reply?["vectors"] as? Int {
            case nil: text = "not answering"
            case 0?: text = "nothing indexed yet: pick folders in DigUp"
            case let n?: text = "\(n) passages and pictures indexed"
            }
            DispatchQueue.main.async { self?.status = text }
        }
    }

    /// A meaning match as a percent, from how far it stands out (`z`), not
    /// its cosine: EmbeddingGemma's cosines bunch together (on one index, the
    /// top hit for gibberish had 0.71 and for "lease agreement" 0.77), while
    /// z went from 3.4 for gibberish to 5–6 for real matches. So 3 → 0%, 6 → 100%.
    static func percent(z: Double) -> Int {
        Int((min(max((z - 3) / 3, 0), 1) * 100).rounded())
    }

    static func hits(_ v: [String: Any]) -> [MeaningHit] {
        let all = v["hits"] as? [[String: Any]] ?? []
        let strong = v["strong"] as? Int ?? all.count
        return all.prefix(strong).compactMap { h in
            guard let path = h["path"] as? String else { return nil }
            return MeaningHit(
                path: path, kind: h["kind"] as? String ?? "file",
                cosine: (h["cosine"] as? NSNumber)?.doubleValue,
                z: (h["z"] as? NSNumber)?.doubleValue,
                keywordRank: h["keyword_rank"] as? Int,
                loc: (h["loc"] as? NSNumber)?.doubleValue,
                excerpt: (h["excerpt"] as? String).map {
                    $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                })
        }
    }

    private func sendQueued() {
        lock.lock()
        inFlight = false
        let next = queued
        queued = nil
        lock.unlock()
        if let next { search(next.q, limit: next.limit, completion: next.completion) }
    }

    // MARK: - The helper process

    private func send(_ obj: [String: Any], reply: @escaping ([String: Any]?) -> Void) {
        lock.lock()
        if process?.isRunning != true, !start() {
            lock.unlock()
            return reply(nil)
        }
        nextID += 1
        let id = nextID
        waiting[id] = reply
        let handle = input
        lock.unlock()
        var o = obj
        o["id"] = id
        guard var line = try? JSONSerialization.data(withJSONObject: o) else { return finish(id, nil) }
        line.append(0x0a)
        do { try handle?.write(contentsOf: line) } catch { finish(id, nil) }
    }

    private func finish(_ id: Int, _ value: [String: Any]?) {
        lock.lock()
        let r = waiting.removeValue(forKey: id)
        lock.unlock()
        r?(value)
    }

    /// Under `lock`.
    private func start() -> Bool {
        guard let bin = binary else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // No folders: search everything DigUp indexed (its app decides what that is).
        p.arguments = ["search-service", "--encoder-idle", "600"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in self?.died() }
        do { try p.run() } catch { return false }
        process = p
        input = stdin.fileHandleForWriting
        let out = stdout.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            while true {
                let chunk = out.availableData
                if chunk.isEmpty { return } // the helper exited
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0a) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    guard let v = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                          let id = v["id"] as? Int else { continue } // events ("ready", encoder state)
                    self?.finish(id, v["ok"] as? Bool == false ? nil : v)
                }
            }
        }
        return true
    }

    /// The helper quit or crashed: fail what it owed, start afresh next time.
    private func died() {
        lock.lock()
        let owed = waiting
        waiting.removeAll()
        process = nil
        input = nil
        lock.unlock()
        for r in owed.values { r(nil) }
    }
}
