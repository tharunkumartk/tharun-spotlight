import Foundation

/// Scores how well a typed query names an app, the way Alfred does: an exact
/// name beats a prefix, which beats a later word ("code" → Visual Studio
/// Code), initials ("vsc"), a substring, and last a scattered match.
enum Fuzzy {
    struct Name {
        /// Folded (lowercase, no accents) characters of the name.
        let chars: [Character]
        /// Where each word starts in `chars`: after spaces or punctuation, at
        /// camel-case humps (TablePlus) and between digits and letters (1Password).
        let starts: [Int]

        init(_ s: String) {
            var chars: [Character] = []
            var starts: [Int] = []
            var prev: Character?
            for ch in s {
                let isWord = ch.isLetter || ch.isNumber
                if isWord {
                    let boundary: Bool
                    if let p = prev {
                        boundary = !(p.isLetter || p.isNumber)
                            || (p.isLowercase && ch.isUppercase)
                            || (p.isNumber != ch.isNumber)
                    } else {
                        boundary = true
                    }
                    if boundary { starts.append(chars.count) }
                }
                chars.append(contentsOf: Fuzzy.fold(String(ch)))
                prev = ch
            }
            self.chars = chars
            self.starts = starts
        }

        var words: [ArraySlice<Character>] {
            starts.enumerated().map { k, s in
                let end = k + 1 < starts.count ? starts[k + 1] : chars.count
                return chars[s..<end]
            }
        }
    }

    static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased())
    }

    /// Higher is better; nil when `query` doesn't match `name` at all.
    static func score(_ query: String, _ name: String) -> Int? {
        score(fold(query), Name(name))
    }

    static func score(_ q: [Character], _ n: Name) -> Int? {
        let chars = n.chars
        guard !q.isEmpty, !chars.isEmpty else { return nil }
        if chars == q { return 1000 }
        if chars.starts(with: q) { return 900 - min(chars.count - q.count, 50) }
        for s in n.starts.dropFirst() where chars[s...].starts(with: q) {
            return 800 - min(s, 50)
        }
        let compact = q.filter { $0 != " " }
        if compact.count >= 2, acronym(compact[...], n.words[...]) {
            return 700
        }
        if let at = find(q, in: chars) {
            return 600 - min(at, 50)
        }
        // Scattered letters, starting at a word: "safri" → Safari, "phshp" → Photoshop
        if compact.count >= 3, let gaps = scattered(compact, n) {
            return 300 - min(gaps * 10, 250)
        }
        return nil
    }

    /// How much of a file search the file names themselves explain, 0…1: the
    /// share of the query's words found (starting a word, or as initials)
    /// in the best of `paths`' names. fsearch also matches words
    /// against folders, so "strange loop wire instructions" finds
    /// strange-loop/…/INSTRUCTIONS.md; that scores 0.25 here. Filters such
    /// as ext:pdf and -word don't count.
    static func nameConfidence(_ query: String, paths: [String]) -> Double {
        let words = queryWords(query).filter { $0.count >= 2 }
        guard !words.isEmpty else { return 1 }
        var best = 0
        for p in paths {
            let name = Name(((p as NSString).lastPathComponent as NSString).deletingPathExtension)
            best = max(best, words.filter { (score($0, name) ?? 0) >= 700 }.count)
            if best == words.count { break }
        }
        return Double(best) / Double(words.count)
    }

    /// The words of a file search, folded, without fsearch's filters
    /// (ext:pdf, in:…) and exclusions (-word).
    static func queryWords(_ query: String) -> [[Character]] {
        query.split(separator: " ").map(String.init)
            .filter { !$0.contains(":") && !$0.hasPrefix("-") }
            .map { fold($0) }
    }

    /// How well a file's name matches, 0…100: each word's `score` in the name
    /// (1000 → 100%), averaged over the words. A word fsearch matched only in
    /// a folder on the path counts 40% of its match there, and one it matched
    /// only by a typo counts 30%. A query that names the file whole (several
    /// words spelling its start) scores as one. Nil for filters alone.
    static func filePercent(_ query: String, path: String) -> Int? {
        let words = queryWords(query)
        guard !words.isEmpty else { return nil }
        let name = Name(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        if words.count > 1, let s = score(Array(words.joined(separator: " ")), name), s >= 850 { return s / 10 }
        let folders = (path as NSString).deletingLastPathComponent.split(separator: "/").map { Name(String($0)) }
        var total = 0.0
        for w in words {
            if let s = score(w, name) {
                total += Double(s) / 1000
            } else if let s = folders.compactMap({ score(w, $0) }).max() {
                total += 0.4 * Double(s) / 1000
            } else {
                total += 0.3
            }
        }
        return Int((total / Double(words.count) * 100).rounded())
    }

    /// The share of the query's words that start a word in `text`, 0…100.
    static func wordsPercent(_ query: String, in text: String) -> Int {
        let words = queryWords(query)
        guard !words.isEmpty else { return 0 }
        let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { fold(String($0)) }
        let found = words.filter { w in tokens.contains { $0.starts(with: w) } }.count
        return found * 100 / words.count
    }

    /// Each query letter continues the current word or starts a later one:
    /// "vsc" and "vscode" both name Visual Studio Code.
    static func acronym(_ q: ArraySlice<Character>, _ words: ArraySlice<ArraySlice<Character>>) -> Bool {
        if q.isEmpty { return true }
        guard let w = words.first else { return false }
        var k = 0
        while k < w.count, k < q.count, w[w.startIndex + k] == q[q.startIndex + k] {
            k += 1
            if acronym(q.dropFirst(k), words.dropFirst()) { return true }
        }
        return acronym(q, words.dropFirst())
    }

    static func find(_ q: [Character], in s: [Character]) -> Int? {
        guard q.count <= s.count else { return nil }
        for i in 0...(s.count - q.count) where s[i..<(i + q.count)].elementsEqual(q) {
            return i
        }
        return nil
    }

    /// Letters in order, the first at a word start; returns the letters skipped.
    static func scattered(_ q: [Character], _ n: Name) -> Int? {
        let s = n.chars
        for start in n.starts where s[start] == q[0] {
            var j = start + 1
            var gaps = 0
            var ok = true
            for ch in q.dropFirst() {
                var found = false
                while j < s.count {
                    defer { j += 1 }
                    if s[j] == ch { found = true; break }
                    gaps += 1
                }
                if !found { ok = false; break }
            }
            if ok { return gaps }
        }
        return nil
    }
}
