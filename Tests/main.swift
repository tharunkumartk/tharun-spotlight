// Linux test harness for the parts that don't need AppKit:
//   swiftc Sources/Calc.swift Sources/Fuzzy.swift Sources/Apps.swift Sources/FSearchClient.swift Tests/main.swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("ok    \(what)") } else { failures += 1; print("FAIL  \(what)") }
}

// MARK: Calc

let calc: [(String, Double?)] = [
    ("45+32/658", 45 + 32.0 / 658), ("2^10", 1024), ("-2^2", -4), ("2**3", 8), ("(1+2)*3", 9),
    ("(1+2", 3), ("3x4", 12), ("3 x 4", 12), ("1,250*2", 2500), ("50%", 0.5), ("15% * 80", 12),
    ("10 % 3", 1), ("2pi", 2 * Double.pi), ("sqrt(16)+1", 5), ("sqrt 16", 4), ("sin(pi/2)^2", 1),
    ("5!", 120), ("1e3+1", 1001), ("2e", 2 * M_E), ("10/4=", 2.5), ("=10/4", 2.5), ("8÷2", 4),
    ("6×7", 42), ("log(1000)", 3), ("ln(e)", 1), ("(2+3)(4)", 20), ("1.5*2", 3), (".5+.25", 0.75),
    ("100 - 2 * 3", 94), ("2^3^2", 512), ("1/3*3", 1), ("200 + 10%", 200.1), ("3 X 4", 12),
    // Not math: nothing to show
    ("42", nil), ("-5", nil), ("pi", nil), ("e", nil), ("safari", nil), ("xcode", nil), ("x", nil),
    ("1.2.3", nil), ("45+", nil), ("", nil), ("1/0", nil), ("2 3", nil), ("calc", nil), ("sqrt", nil),
    ("1password", nil), ("tan", nil), ("photoshop 2024", nil),
]
for (input, want) in calc {
    let got = Calc.evaluate(input)
    let ok: Bool
    switch (got, want) {
    case (nil, nil): ok = true
    case let (g?, w?): ok = abs(g - w) <= 1e-9 * max(1, abs(w))
    default: ok = false
    }
    check(ok, "calc \(input.debugDescription) -> \(got.map { String($0) } ?? "nil") (want \(want.map { String($0) } ?? "nil"))")
}
print("format:", Calc.format(45 + 32.0 / 658, grouping: false), Calc.format(1234567.5, grouping: true),
      Calc.format(0.1 + 0.2, grouping: false), Calc.format(1e20, grouping: false), Calc.format(-3, grouping: true))
check(Calc.format(0.1 + 0.2, grouping: false) == "0.3", "format hides float noise")
check(Calc.format(45 + 32.0 / 658, grouping: false) == "45.0486322188", "format 45+32/658")

// MARK: Fuzzy

func s(_ q: String, _ n: String) -> Int? { Fuzzy.score(q, n) }
check(s("safari", "Safari") == 1000, "exact")
check(s("Café", "cafe") == 1000 && s("cafe", "Café") == 1000, "accents and case fold")
check((s("saf", "Safari") ?? 0) > (s("saf", "Microsoft Safety") ?? 0), "prefix beats later word")
check(s("code", "Visual Studio Code") != nil, "later word")
check(s("vsc", "Visual Studio Code") != nil, "initials")
check(s("vscode", "Visual Studio Code") != nil, "initials then word")
check(s("tp", "TablePlus") != nil, "camel case initials")
check(s("1p", "1Password 7") != nil, "digit/letter boundary")
check(s("sysset", "System Settings") != nil && s("sys set", "System Settings") != nil, "word prefixes")
check(s("safri", "Safari") != nil, "scattered letters")
check(s("xyz", "Safari") == nil && s("fari", "Safari") != nil, "no match / substring")
check(s("q", "Safari") == nil, "single stray letter")
let names = ["Safari", "System Settings", "Slack", "Messages", "Spotify", "Notes", "Visual Studio Code", "Screenshot"]
for q in ["s", "sl", "sett", "vsc", "note", "scr"] {
    let ranked = names.compactMap { n in s(q, n).map { (n, $0) } }.sorted { $0.1 > $1.1 }
    print("  \(q.debugDescription):", ranked.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
}
check(AppCatalog.isUserFacing("/Users/me/Downloads/Foo.app"), "user app ok")
check(!AppCatalog.isUserFacing("/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"), "nested app skipped")
check(!AppCatalog.isUserFacing("/Users/me/Library/Caches/x.app"), "Library skipped")

// MARK: FSearchClient against a fake daemon

func wait<T>(_ start: (@escaping (T) -> Void) -> Void) -> T? {
    var out: T?
    start { out = $0 }
    let deadline = Date().addingTimeInterval(10)
    while out == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return out
}

let sock = NSTemporaryDirectory() + "fl-test-\(getpid()).sock"
setenv("FAKE_SOCK", sock, 1)
let fake = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/fake_fsearch.py"
let client = FSearchClient(socketPath: sock, binary: fake)

// The client starts the "daemon" itself on first use.
let r1 = wait { done in client.search("report", limit: 10) { done($0) } }
if case .success(let hits)? = r1 {
    check(hits.map(\.path) == ["/Users/me/report.txt"] && hits[0].kind == "file", "search starts daemon and parses hits")
} else { check(false, "search starts daemon: \(String(describing: r1))") }

let r2 = wait { done in client.search("grep:let", limit: 10) { done($0) } }
if case .success(let hits)? = r2 {
    check(hits.first?.detail == "12: let x = 1;", "grep files parsed: \(hits.first?.detail ?? "nil")")
} else { check(false, "grep") }

let r3 = wait { done in client.search("boom", limit: 10) { done($0) } }
if case .failure(let e)? = r3 { check(e.description == "indexing: 40%", "server error passed through") } else { check(false, "error") }

// Typing fast: only the newest search answers.
var answered: [String] = []
for q in ["slow1", "slow2", "slow3", "final"] {
    client.search(q, limit: 10) { r in if case .success(let h) = r { answered.append(h[0].path) } }
}
let until = Date().addingTimeInterval(2)
while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
check(answered == ["/Users/me/final.txt"], "stale searches dropped: \(answered)")

client.reportOpen("/Users/me/report.txt")
Thread.sleep(forTimeInterval: 0.3)
check((try? String(contentsOfFile: sock + ".opened", encoding: .utf8)) == "/Users/me/report.txt\n", "open reported")

// The daemon dies: the next search restarts it and reconnects.
// Ask the fake to exit over a raw connection.
do {
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(sock.utf8)) }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    let msg = Array("{\"op\":\"die\"}\n".utf8)
    _ = send(fd, msg, msg.count, Int32(MSG_NOSIGNAL))
    Thread.sleep(forTimeInterval: 0.3)
    close(fd)
}
let r4 = wait { done in client.search("again", limit: 10) { done($0) } }
if case .success(let hits)? = r4 { check(hits.first?.path == "/Users/me/again.txt", "reconnects after daemon restart") } else { check(false, "reconnect: \(String(describing: r4))") }

let none = FSearchClient(socketPath: NSTemporaryDirectory() + "nothing-here.sock", binary: nil)
let r5 = wait { done in none.search("x", limit: 1) { done($0) } }
if case .failure(let e)? = r5 { check(e.description.contains("isn't installed"), "no binary: \(e.description)") } else { check(false, "no binary") }

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
