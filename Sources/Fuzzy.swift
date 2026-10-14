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
