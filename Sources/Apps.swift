import Foundation

struct AppEntry {
    let name: String
    let path: String
    /// The bundle's file name, when Finder shows it under another name.
    let alias: Fuzzy.Name?
    let folded: Fuzzy.Name
}

/// The installed apps, scanned from the usual folders (a few hundred bundles,
/// a few milliseconds), plus what you launch, so the app you pick for a query
/// comes first next time.
final class AppCatalog {
    private(set) var apps: [AppEntry] = []
    private var lastScan = Date.distantPast
    private var scanning = false
    private let defaults = UserDefaults.standard
    private var counts: [String: Int]
    private var picks: [String: String]

    static let roots: [(String, Int)] = [
        ("/Applications", 3),
        ("/System/Applications", 2),
        (NSHomeDirectory() + "/Applications", 3),
        ("/System/Library/CoreServices/Applications", 1),
    ]
    static let singles = ["/System/Library/CoreServices/Finder.app"]

    init() {
        counts = defaults.dictionary(forKey: "appLaunchCounts") as? [String: Int] ?? [:]
        picks = defaults.dictionary(forKey: "appPicks") as? [String: String] ?? [:]
    }

    /// Rescans in the background, at most every 30 s unless forced.
    func refresh(force: Bool = false) {
        guard !scanning, force || Date().timeIntervalSince(lastScan) > 30 else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scan()
            DispatchQueue.main.async {
                self.apps = found
                self.lastScan = Date()
                self.scanning = false
            }
        }
    }

    static func scan() -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [AppEntry] = []
        func add(_ path: String) {
            guard seen.insert((path as NSString).resolvingSymlinksInPath).inserted else { return }
            let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var name = fm.displayName(atPath: path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            out.append(AppEntry(name: name, path: path, alias: name == file ? nil : Fuzzy.Name(file), folded: Fuzzy.Name(name)))
        }
        func walk(_ dir: String, _ depth: Int) {
            guard depth > 0, let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for n in names where !n.hasPrefix(".") {
                let p = dir + "/" + n
                if n.hasSuffix(".app") {
                    add(p)
                } else {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { walk(p, depth - 1) }
                }
            }
        }
        for (root, depth) in roots { walk(root, depth) }
        for p in singles where fm.fileExists(atPath: p) { add(p) }
        return out
    }

    func search(_ query: String, limit: Int) -> [AppEntry] {
        let q = Fuzzy.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        let pick = picks[String(q)]
        var scored: [(Int, AppEntry)] = []
        for app in apps {
            guard var s = [Fuzzy.score(q, app.folded), app.alias.flatMap { Fuzzy.score(q, $0) }].compactMap({ $0 }).max() else { continue }
            s += min(counts[app.path] ?? 0, 20) * 6
            if app.path == pick { s += 500 }
            scored.append((s, app))
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.name.count < $1.1.name.count }
        return scored.prefix(limit).map { $0.1 }
    }

    /// Remembers the pick: launched apps rank higher, and this exact query
    /// brings this app first from now on.
    func recordLaunch(_ path: String, query: String) {
        counts[path, default: 0] += 1
        let q = String(Fuzzy.fold(query.trimmingCharacters(in: .whitespaces)))
        if !q.isEmpty { picks[q] = path }
        defaults.set(counts, forKey: "appLaunchCounts")
        defaults.set(picks, forKey: "appPicks")
    }

    /// An app found by fsearch worth offering: not a helper inside another
    /// bundle, a cache, a build product or the Trash.
    static func isUserFacing(_ path: String) -> Bool {
        let bad = [".app/", "/Library/", "/.Trash/", "/DerivedData/", "/node_modules/", "/.build/", "/build/", "/Build/", "/target/", "/.cache/", "/private/"]
        return path.hasSuffix(".app") && !bad.contains { path.contains($0) }
    }
}
