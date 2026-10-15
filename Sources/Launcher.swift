import AppKit

struct ResultItem {
    enum Action {
        case openApp(String)
        case openFile(String)
        case copy(String)
        case openURL(URL)
        case searchFiles(String)
        case none
    }

    var title: String
    var subtitle: String
    var action: Action
    var iconPath: String? = nil
    var symbol: String? = nil
    /// How well it matched, shown at the right of the row. Each source has its
    /// own scale (see README), so compare scores within a source only.
    var score: String? = nil

    /// A file or app: ⌘-click reveals it, and it can be dragged out.
    var isFile: Bool {
        switch action {
        case .openApp, .openFile: return true
        default: return false
        }
    }
}

/// Borderless, and non-activating: it takes the keyboard without pulling the
/// app you were in to the back, so closing it leaves you where you were.
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Alfred's look: one large search line, results below with icon, name,
/// path and a ⌘-number, the selection a rounded accent-colored bar.
final class LauncherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let apps: AppCatalog
    private let fsearch: FSearchClient
    private let digup: DigUpClient
    private let panel: LauncherPanel
    private let effect = NSVisualEffectView()
    private let border = PassthroughView()
    private let field = NSTextField()
    private let modeIcon = NSImageView()
    /// The pill at the start of the search line naming the mode ("Files", "Contents").
    private let chip = NSView()
    private let chipIcon = NSImageView()
    private let chipLabel = NSTextField(labelWithString: "")
    /// What the search line searches. A leading space (or ') enters `.files`,
    /// a leading ` enters `.contents`; backspace on an empty line goes back to apps.
    private enum Mode: String {
        case apps
        /// By name with fsearch, plus DigUp's content matches once typing pauses.
        case files
        /// By what's in them only, with DigUp.
        case contents

        var symbol: String {
            switch self {
            case .apps: return "magnifyingglass"
            case .files: return "doc.text.magnifyingglass"
            case .contents: return "sparkle.magnifyingglass"
            }
        }
    }
    private var mode = Mode.apps
    private let separator = NSBox()
    private let scroll = NSScrollView()
    private let table = ResultTable()
    private var items: [ResultItem] = []
    private var selected = 0
    private var generation = 0
    /// File mode: fsearch's answer for the current query (nil until it
    /// comes), DigUp's, and the pending DigUp search.
    private var fileHits: Result<[FSHit], FSearchError>?
    private var meaningHits: [MeaningHit] = []
    private var meaningWork: DispatchWorkItem?
    private var monitor: Any?
    /// ⌘ is down: file and app rows say ⌘-click shows them in Finder.
    private var commandHeld = false
    /// What was searched before, oldest first: the mode and the line when a
    /// result was opened. ↑ on a fresh line steps back through it.
    private var history: [(mode: Mode, text: String)] = LauncherController.loadHistory()
    /// Where ↑ ↓ are in `history`, while the line is a recalled search.
    private var historyIndex: Int?
    /// The panel's top edge on screen: it grows downward as results come in.
    private var top: CGFloat = 0
    private let font = NSFont.systemFont(ofSize: 30, weight: .light)

    private let width: CGFloat = 680
    private let pad: CGFloat = 10
    private let fieldHeight: CGFloat = 52
    private let rowHeight: CGFloat = 54
    private let maxRows = 9
    private let radius: CGFloat = 14

    init(apps: AppCatalog, fsearch: FSearchClient, digup: DigUpClient) {
        self.apps = apps
        self.fsearch = fsearch
        self.digup = digup
        panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 72),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        build()
    }

    var isVisible: Bool { panel.isVisible }

    private func build() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.maskImage = roundedMask(radius: radius)
        panel.contentView = effect

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        effect.addSubview(field)

        chip.wantsLayer = true
        chip.layer?.cornerRadius = 8
        chip.isHidden = true
        chipIcon.contentTintColor = .white
        chipLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        chipLabel.textColor = .white
        chip.addSubview(chipIcon)
        chip.addSubview(chipLabel)
        effect.addSubview(chip)

        modeIcon.contentTintColor = .tertiaryLabelColor
        modeIcon.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(modeIcon)

        separator.boxType = .separator
        effect.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.onClick = { [weak self] row, mods in self?.run(row, modifiers: mods) }
        table.fileForRow = { [weak self] row in
            guard let self, self.items.indices.contains(row) else { return nil }
            switch self.items[row].action {
            case .openApp(let p), .openFile(let p): return p
            default: return nil
            }
        }
        table.onDrop = { [weak self] path in
            self?.hide()
            self?.fsearch.reportOpen(path)
        }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        effect.addSubview(scroll)

        // A hairline edge, as on Spotlight, so the panel reads on dark wallpapers too.
        border.wantsLayer = true
        border.layer?.cornerRadius = radius
        border.layer?.borderWidth = 1
        border.autoresizingMask = [.width, .height]
        effect.addSubview(border)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            if e.type == .flagsChanged {
                self.setCommandHeld(e.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting([.capsLock, .numericPad, .function]) == .command)
                return e
            }
            return self.handleKey(e) // nil swallows the key
        }
        layoutViews()
    }

    // MARK: - Showing

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        apps.refresh()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        top = vf.maxY - vf.height * 0.2
        panel.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: top - panel.frame.height))
        field.stringValue = ""
        historyIndex = nil
        commandHeld = false
        setMode(.apps)
        update(items: [])
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.border.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func hide() {
        generation += 1
        panel.orderOut(nil)
        // If something activated us (reopening the app, an alert), hand the
        // keyboard back to the app underneath.
        if NSApp.isActive { NSApp.hide(nil) }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func layoutViews() {
        let n = min(items.count, maxRows)
        let list: CGFloat = n == 0 ? 0 : 1 + 6 + CGFloat(n) * rowHeight + 6
        let h = pad + fieldHeight + pad + list
        var f = panel.frame
        f.size = NSSize(width: width, height: h)
        f.origin.y = top - h
        panel.setFrame(f, display: true)

        let fieldBottom = h - pad - fieldHeight
        let textHeight: CGFloat = 38
        let labelWidth = ceil(chipLabel.intrinsicContentSize.width)
        let chipSize = NSSize(width: 32 + labelWidth + 10, height: 30)
        chip.frame = NSRect(x: 18, y: fieldBottom + (fieldHeight - chipSize.height) / 2, width: chipSize.width, height: chipSize.height)
        chipIcon.frame = NSRect(x: 10, y: 6, width: 18, height: 18)
        chipLabel.frame = NSRect(x: 32, y: 5, width: labelWidth, height: 20)
        let fieldX: CGFloat = mode == .apps ? 20 : chip.frame.maxX + 10
        field.frame = NSRect(x: fieldX, y: fieldBottom + (fieldHeight - textHeight) / 2, width: width - fieldX - 58, height: textHeight)
        modeIcon.frame = NSRect(x: width - 46, y: fieldBottom + (fieldHeight - 26) / 2, width: 26, height: 26)
        separator.isHidden = n == 0
        separator.frame = NSRect(x: 0, y: list - 1, width: width, height: 1)
        scroll.isHidden = n == 0
        scroll.frame = NSRect(x: 8, y: 6, width: width - 16, height: CGFloat(n) * rowHeight)
        table.sizeLastColumnToFit()
        border.frame = effect.bounds
        DispatchQueue.main.async { self.panel.invalidateShadow() }
    }

    private func update(items new: [ResultItem], keepSelection: Bool = false) {
        items = new
        selected = keepSelection ? min(selected, max(new.count - 1, 0)) : 0
        // Reload before resizing: setFrame(display:) lays the table out
        // right away, and with the old row count it would ask for rows
        // past the end of the new, shorter list.
        table.reloadData()
        layoutViews()
        if !items.isEmpty { table.scrollRowToVisible(selected) }
    }

    /// Shows or hides the mode's pill, and the placeholder and icon that go with it.
    private func setMode(_ new: Mode) {
        if new != .apps, mode == .apps {
            digup.warmUp()
            fsearch.warmUp()
        }
        mode = new
        let on = new != .apps
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            self.chip.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        }
        chipLabel.stringValue = new == .contents ? "Contents" : "Files"
        chipIcon.image = NSImage(systemSymbolName: new.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        if on, chip.isHidden {
            chip.alphaValue = 0
            chip.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self.chip.animator().alphaValue = 1
            }
        } else if !on {
            chip.isHidden = true
        }
        field.placeholderAttributedString = NSAttributedString(
            string: [Mode.apps: "Apps  ·  space: files  ·  `: contents  ·  45+32",
                     .files: "Search files  ·  ext:pdf  in:~/Documents",
                     .contents: "Describe what's in the file"][new]!,
            attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: font])
        layoutViews()
        updateModeIcon()
    }

    private func updateModeIcon() {
        let symbol = mode == .apps && Calc.evaluate(field.stringValue) != nil ? "equal.circle" : mode.symbol
        modeIcon.contentTintColor = mode == .apps ? .tertiaryLabelColor : .controlAccentColor
        modeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
    }

    // MARK: - Searching

    /// A leading space (or ', as in Alfred) switches to file search, and a
    /// leading ` to content search; the character becomes the mode's pill.
    func controlTextDidChange(_ obj: Notification) {
        historyIndex = nil
        let raw = field.stringValue
        if mode == .apps, let first = raw.first, let new: Mode = first == "`" ? .contents : first == " " || first == "'" ? .files : nil {
            field.stringValue = String(raw.dropFirst())
            moveCursorToEnd()
            setMode(new)
        }
        search()
    }

    private func search() {
        generation += 1
        let gen = generation
        let raw = field.stringValue
        updateModeIcon()

        if mode == .contents {
            return searchContents(raw.trimmingCharacters(in: .whitespaces), gen)
        }
        if mode == .files {
            let q = raw.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else {
                return update(items: [ResultItem(
                    title: "Search files",
                    subtitle: "Type a name. Filters work too: ext:pdf  in:~/Documents  type:image  mtime:<7d  grep:TODO",
                    action: .none, symbol: "doc.text.magnifyingglass")] + accessHint)
            }
            fileHits = nil
            meaningHits = []
            fsearch.search(q, limit: 50) { [weak self] r in
                guard let self, gen == self.generation else { return }
                self.fileHits = r
                self.showFiles(q)
            }
            // By meaning too, once typing pauses: DigUp embeds the query
            // (tens of ms) and compares it with every passage it indexed.
            // fsearch's filters (ext:, in:, grep:…) mean a name search.
            meaningWork?.cancel()
            guard digup.isAvailable, q.count >= 3, !q.split(separator: " ").contains(where: { $0.contains(":") }) else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, gen == self.generation else { return }
                self.digup.search(q, limit: 20) { [weak self] hits in
                    guard let self, gen == self.generation else { return }
                    self.meaningHits = hits
                    self.showFiles(q)
                }
            }
            meaningWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }

        let q = raw.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return update(items: []) }
        var head: [ResultItem] = []
        if let v = Calc.evaluate(q) {
            head.append(ResultItem(
                title: Calc.format(v, grouping: true),
                subtitle: "\(q) =   ·   ⏎ copies the result",
                action: .copy(Calc.format(v, grouping: false)),
                iconPath: "/System/Applications/Calculator.app"))
        }
        let scored = apps.search(q, limit: maxRows)
        let local = scored.map(\.app)
        let localItems = scored.map { appItem($0.app, percent: min($0.match / 10, 100)) }
        update(items: withFallbacks(head + localItems, q))

        // The index knows apps outside the usual folders (Downloads, a
        // mounted disk image) and forgives typos: fill any room left with them.
        guard local.count < maxRows, head.isEmpty else { return }
        fsearch.search("type:app " + q, limit: 20) { [weak self] r in
            guard let self, gen == self.generation, case .success(let hits) = r else { return }
            let knownPaths = Set(local.map(\.path))
            let knownNames = Set(local.map { $0.name.lowercased() })
            var seen = Set<String>()
            let extra = hits
                .filter { AppCatalog.isUserFacing($0.path) && !knownPaths.contains($0.path) }
                .filter { h in
                    let name = Self.appName(h.path).lowercased()
                    return !knownNames.contains(name) && seen.insert(name).inserted
                }
                .prefix(self.maxRows - local.count)
                .map { ResultItem(title: Self.appName($0.path), subtitle: Self.tilde($0.path), action: .openApp($0.path),
                                  iconPath: $0.path, score: Fuzzy.filePercent(q, path: $0.path).map(Self.percent)) }
            guard !extra.isEmpty else { return }
            self.update(items: self.withFallbacks(localItems + extra, q), keepSelection: true)
        }
    }

    /// Content mode: only what DigUp finds by meaning and by exact words.
    private func searchContents(_ q: String, _ gen: Int) {
        meaningWork?.cancel()
        guard digup.isAvailable else {
            return update(items: [ResultItem(
                title: "Searching by content needs DigUp",
                subtitle: "brew install --cask arahim3/tap/digup, then pick the folders it should read",
                action: .openURL(URL(string: "https://github.com/ARahim3/DigUp")!), symbol: Mode.contents.symbol)])
        }
        guard !q.isEmpty else {
            return update(items: [ResultItem(
                title: "Search by what's in a file",
                subtitle: "In your own words: strange loop wire instructions  ·  the lease clause about pets",
                action: .none, symbol: Mode.contents.symbol)])
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.digup.search(q, limit: 30) { [weak self] hits in
                guard let self, gen == self.generation else { return }
                guard !hits.isEmpty else {
                    return self.update(items: [ResultItem(
                        title: "Nothing in DigUp's index matches “\(q)”",
                        subtitle: "DigUp: \(self.digup.status). Add folders in DigUp, or ⌫ and space to search names",
                        action: .none, symbol: "doc.questionmark")])
                }
                self.update(items: hits.map { self.meaningItem($0, query: q) })
            }
        }
        meaningWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Name matches and meaning matches in one list. When the names explain
    /// the query (every word starts a word in some top file name) they lead;
    /// otherwise the files whose contents match lead, since fsearch then
    /// matched words in folder names or by typo.
    private func showFiles(_ q: String) {
        let names: [FSHit]
        switch fileHits {
        case nil:
            guard !meaningHits.isEmpty else { return } // wait for fsearch
            names = []
        case .success(let hits)?:
            names = hits
        case .failure(let e)?:
            guard !meaningHits.isEmpty else {
                return update(items: [ResultItem(
                    title: e.description, subtitle: "fsearch", action: .none, symbol: "exclamationmark.triangle")])
            }
            names = []
        }
        let confidence = Fuzzy.nameConfidence(q, paths: names.prefix(5).map(\.path))
        let nameItems = names.map { fileItem($0, query: q) }
        // A meaning match that barely stands out is noise next to name
        // matches (gibberish still gets "strong" hits); content mode shows them all.
        let meaningItems = meaningHits.filter { Self.meaningPercent($0, q) >= 20 }.map { meaningItem($0, query: q) }
        let ordered = confidence >= 1 ? nameItems + meaningItems : meaningItems + nameItems
        var seen = Set<String>()
        let merged = ordered.filter { item in
            guard case .openFile(let p) = item.action else { return true }
            return seen.insert(p).inserted
        }
        guard !merged.isEmpty else {
            return update(items: [ResultItem(
                title: "No files match “\(q)”", subtitle: "Try fewer letters, or a filter like ext:pdf",
                action: .none, symbol: "doc.questionmark")] + accessHint)
        }
        // The second answer for a query reorders the first: stay on the file
        // that was selected, wherever it moved.
        var current: String?
        if items.indices.contains(selected), case .openFile(let p) = items[selected].action { current = p }
        let list = Array(merged.prefix(50)) + accessHint
        update(items: list)
        if fileHits != nil, !meaningHits.isEmpty, let current,
           let i = list.firstIndex(where: { if case .openFile(let p) = $0.action { return p == current }; return false }) {
            select(i)
        }
    }

    /// A last row while fsearch can't read Desktop, Documents and Downloads,
    /// so a file missing from there isn't a mystery.
    private var accessHint: [ResultItem] {
        guard fsearch.fullDiskAccess == false else { return [] }
        return [ResultItem(
            title: "Desktop, Documents and Downloads aren't searched",
            subtitle: "fsearch needs Full Disk Access: add ~/.local/bin/fsearch, then Restart fsearch in the menu bar",
            action: .openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!),
            symbol: "lock")]
    }

    private func withFallbacks(_ items: [ResultItem], _ q: String) -> [ResultItem] {
        guard items.isEmpty else { return items }
        var out = [ResultItem(
            title: "Search files for “\(q)”", subtitle: "fsearch, across your whole disk",
            action: .searchFiles(q), symbol: "doc.text.magnifyingglass")]
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        if let url = c.url {
            let browser = NSWorkspace.shared.urlForApplication(toOpen: url)?.path
            out.append(ResultItem(
                title: "Search Google for “\(q)”", subtitle: "Open in your browser",
                action: .openURL(url), iconPath: browser, symbol: "globe"))
        }
        return out
    }

    private func appItem(_ app: AppEntry, percent: Int) -> ResultItem {
        ResultItem(title: app.name, subtitle: Self.tilde(app.path), action: .openApp(app.path), iconPath: app.path,
                   score: Self.percent(percent))
    }

    static func percent(_ p: Int) -> String { "\(p)%" }

    private func fileItem(_ hit: FSHit, query: String) -> ResultItem {
        let dir = Self.tilde((hit.path as NSString).deletingLastPathComponent)
        return ResultItem(
            title: (hit.path as NSString).lastPathComponent,
            subtitle: hit.detail.map { "\(dir)  —  \($0)" } ?? dir,
            action: .openFile(hit.path), iconPath: hit.path, score: Fuzzy.filePercent(query, path: hit.path).map(Self.percent))
    }

    /// A file DigUp found by what's in it: the passage that matched, marked ≈.
    private func meaningItem(_ hit: MeaningHit, query: String) -> ResultItem {
        var parts: [String] = []
        if hit.kind == "pdf", let page = hit.loc { parts.append("p. \(Int(page))") }
        parts.append(hit.excerpt.map { "“\($0)”" } ?? Self.tilde((hit.path as NSString).deletingLastPathComponent))
        return ResultItem(
            title: (hit.path as NSString).lastPathComponent,
            subtitle: "≈ " + parts.joined(separator: "  ·  "),
            action: .openFile(hit.path), iconPath: hit.path,
            score: Self.percent(Self.meaningPercent(hit, query)))
    }

    /// From how far it stands out by meaning, or, matched on exact words
    /// alone, the share of the query's words in the passage.
    static func meaningPercent(_ hit: MeaningHit, _ query: String) -> Int {
        hit.z.map(DigUpClient.percent(z:)) ?? Fuzzy.wordsPercent(query, in: hit.excerpt ?? hit.path)
    }

    static func appName(_ path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        // The arrows step through past searches from a fresh line, and keep
        // doing so while the line is one; ⌃P ⌃N always move the selection.
        case #selector(NSResponder.moveUp(_:)) where isArrowKey && (historyIndex != nil || isFreshLine):
            if !history.isEmpty { recall(max((historyIndex ?? history.count) - 1, 0)) }
        case #selector(NSResponder.moveDown(_:)) where isArrowKey && historyIndex != nil:
            recall(historyIndex! + 1)
        case #selector(NSResponder.moveUp(_:)): select(selected - 1)
        case #selector(NSResponder.moveDown(_:)): select(selected + 1)
        case #selector(NSResponder.moveRight(_:)) where historyIndex != nil:
            // → keeps the recalled search: the arrows go back to the results.
            historyIndex = nil
            return false
        case #selector(NSResponder.insertNewline(_:)): run(selected, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        case #selector(NSResponder.cancelOperation(_:)): hide()
        case #selector(NSResponder.insertTab(_:)): autocomplete()
        case #selector(NSResponder.deleteBackward(_:)) where mode != .apps && field.stringValue.isEmpty:
            // Backspace on an empty line drops the pill: back to apps.
            setMode(.apps)
            search()
        default: return false
        }
        return true
    }

    private var isArrowKey: Bool {
        let code = NSApp.currentEvent?.keyCode
        return code == 126 || code == 125
    }

    private var isFreshLine: Bool { mode == .apps && field.stringValue.isEmpty }

    /// Puts a past search on the line; one past the newest clears it.
    private func recall(_ i: Int) {
        guard i < history.count else {
            historyIndex = nil
            field.stringValue = ""
            setMode(.apps)
            return search()
        }
        historyIndex = i
        setMode(history[i].mode)
        field.stringValue = history[i].text
        moveCursorToEnd()
        search()
    }

    private func remember(_ mode: Mode, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        history.removeAll { $0.mode == mode && $0.text == text }
        history.append((mode, text))
        if history.count > 100 { history.removeFirst(history.count - 100) }
        UserDefaults.standard.set(history.map { [$0.mode.rawValue, $0.text] }, forKey: "History")
    }

    private static func loadHistory() -> [(mode: Mode, text: String)] {
        (UserDefaults.standard.array(forKey: "History") as? [[String]] ?? []).compactMap { e in
            guard e.count == 2, let m = Mode(rawValue: e[0]) else { return nil }
            return (m, e[1])
        }
    }

    private func setCommandHeld(_ on: Bool) {
        guard on != commandHeld else { return }
        commandHeld = on
        let rows = table.rows(in: table.visibleRect)
        for r in rows.location..<(rows.location + rows.length) {
            (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? ResultCell)?.setRevealing(on)
        }
    }

    /// ⌘1–⌘9 open a row; ⌘⏎ reveals in Finder; ⌥⏎ copies the path. The
    /// panel isn't the active app's window, so the Edit shortcuts are
    /// routed here rather than through a menu bar.
    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow else { return e }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        if mods == .command, let d = digitKeys[e.keyCode] {
            if d <= items.count { run(d - 1, modifiers: []) }
            return nil
        }
        if e.keyCode == 36 || e.keyCode == 76, !mods.isDisjoint(with: [.command, .option]) {
            run(selected, modifiers: mods)
            return nil
        }
        let edit: [String: String] = ["x": "cut:", "c": "copy:", "v": "paste:", "a": "selectAll:", "z": "undo:"]
        if mods == .command, let action = edit[key] {
            _ = panel.firstResponder?.tryToPerform(Selector(action), with: nil)
            return nil
        }
        if mods == [.command, .shift], key == "z" {
            _ = panel.firstResponder?.tryToPerform(Selector(("redo:")), with: nil)
            return nil
        }
        return e
    }

    private func select(_ i: Int) {
        guard !items.isEmpty else { return }
        let old = selected
        selected = max(0, min(i, items.count - 1))
        for r in Set([old, selected]) where r < items.count {
            (table.rowView(atRow: r, makeIfNecessary: false) as? ResultRowView)?.highlighted = r == selected
            (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? ResultCell)?.setSelected(r == selected)
        }
        table.scrollRowToVisible(selected)
    }

    /// Tab completes the selected name into the search line, as in Alfred.
    private func autocomplete() {
        guard items.indices.contains(selected) else { return }
        let item = items[selected]
        switch item.action {
        case .openApp: field.stringValue = item.title
        case .openFile(let p): field.stringValue = (p as NSString).lastPathComponent
        default: return
        }
        historyIndex = nil
        moveCursorToEnd()
        search()
    }

    private func moveCursorToEnd() {
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    private func run(_ i: Int, modifiers: NSEvent.ModifierFlags) {
        guard items.indices.contains(i) else { return }
        let item = items[i]
        let query = field.stringValue
        if case .none = item.action { return }
        if case .searchFiles = item.action {} else { remember(mode, query) }
        switch item.action {
        case .none:
            return
        case .searchFiles(let q):
            field.stringValue = q
            moveCursorToEnd()
            setMode(.files)
            search()
        case .copy(let s):
            hide()
            copy(s)
        case .openURL(let url):
            hide()
            NSWorkspace.shared.open(url)
        case .openApp(let p), .openFile(let p):
            hide()
            let url = URL(fileURLWithPath: p)
            if modifiers.contains(.option) {
                copy(p)
            } else if modifiers.contains(.command) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if case .openApp = item.action {
                apps.recordLaunch(p, query: query)
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
                fsearch.reportOpen(p)
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: ResultCell.id, owner: nil) as? ResultCell ?? ResultCell(frame: .zero)
        cell.configure(items[row], index: row, selected: row == selected, revealing: commandHeld)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = ResultRowView()
        v.highlighted = row == selected
        return v
    }

    private func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Takes clicks itself: a click opens the row, ⌘-click shows it in Finder,
/// ⌥-click copies its path. (NSTableView would read ⌘-click as "toggle
/// selection".) Dragging a file or app row drags the file itself, as from
/// Finder: into a folder, an email, the Dock.
final class ResultTable: NSTableView {
    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    /// The file or app a row stands for, if it can be dragged out.
    var fileForRow: ((Int) -> String?)?
    /// A dragged file was dropped somewhere.
    var onDrop: ((String) -> Void)?
    private var dragging: String?

    override func mouseDown(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        guard r >= 0, let window else { return }
        let start = event.locationInWindow
        let path = fileForRow?(r)
        // A click opens on release; moving a few points first starts a drag.
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                return onClick?(r, event.modifierFlags.intersection(.deviceIndependentFlagsMask)) ?? ()
            }
            let p = next.locationInWindow
            if let path, hypot(p.x - start.x, p.y - start.y) >= 4 {
                return drag(path, from: event)
            }
        }
    }

    private func drag(_ path: String, from event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
        let image = Self.dragImage(path)
        let at = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: at.x - 16, y: at.y - image.size.height / 2,
                                     width: image.size.width, height: image.size.height), contents: image)
        dragging = path
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// The file's icon and name, as Finder shows a dragged file.
    static func dragImage(_ path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let name = NSAttributedString(string: FileManager.default.displayName(atPath: path), attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let side: CGFloat = 32
        let label = NSSize(width: min(ceil(name.size().width) + 12, 320), height: ceil(name.size().height) + 4)
        let size = NSSize(width: side + 4 + label.width, height: side)
        return NSImage(size: size, flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            let box = NSRect(x: side + 4, y: (side - label.height) / 2, width: label.width, height: label.height)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: box, xRadius: label.height / 2, yRadius: label.height / 2).fill()
            name.draw(with: box.insetBy(dx: 6, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
    }

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // As from Finder: the place it lands decides (a folder on the same
        // disk moves it, another disk or an app copies, ⌥ copies, ⌘⌥ aliases).
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { dragging = nil }
        if operation != [], let path = dragging { onDrop?(path) }
    }
}

final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ResultRowView: NSTableRowView {
    var highlighted = false {
        didSet { if oldValue != highlighted { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
}

final class ResultCell: NSView {
    static let id = NSUserInterfaceItemIdentifier("result")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let score = NSTextField(labelWithString: "")
    private var item: ResultItem?
    private var selected = false
    /// ⌘ is down and this is a file: say that a click shows it in Finder.
    private var revealing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 17)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.lineBreakMode = .byTruncatingMiddle
        shortcut.font = .systemFont(ofSize: 13)
        shortcut.alignment = .right
        score.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        score.alignment = .right
        for l in [title, subtitle, shortcut, score] {
            l.cell?.usesSingleLineMode = true
            l.maximumNumberOfLines = 1
        }
        for v in [icon, title, subtitle, shortcut, score] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        let w = bounds.width
        icon.frame = NSRect(x: 10, y: (h - 36) / 2, width: 36, height: 36)
        shortcut.frame = NSRect(x: w - 52, y: (h - 18) / 2, width: 40, height: 18)
        let scoreWidth: CGFloat = score.stringValue.isEmpty ? 0 : 44
        score.frame = NSRect(x: w - 52 - scoreWidth - 4, y: (h - 16) / 2, width: scoreWidth, height: 16)
        let x: CGFloat = 58
        let tw = w - x - (shortcut.stringValue.isEmpty ? 12 : 60) - (scoreWidth > 0 ? scoreWidth + 4 : 0)
        if subtitle.isHidden {
            title.frame = NSRect(x: x, y: (h - 22) / 2, width: tw, height: 22)
        } else {
            title.frame = NSRect(x: x, y: h / 2 - 1, width: tw, height: 22)
            subtitle.frame = NSRect(x: x, y: h / 2 - 18, width: tw, height: 16)
        }
    }

    func configure(_ item: ResultItem, index: Int, selected: Bool, revealing: Bool) {
        self.item = item
        self.selected = selected
        title.stringValue = item.title
        shortcut.stringValue = index < 9 ? "⌘\(index + 1)" : ""
        score.stringValue = item.score ?? ""
        icon.image = Icons.image(path: item.iconPath, symbol: item.symbol)
        setRevealing(revealing)
    }

    func setSelected(_ on: Bool) {
        selected = on
        applyColors()
    }

    func setRevealing(_ on: Bool) {
        guard let item else { return }
        revealing = on && item.isFile
        subtitle.stringValue = revealing ? "Click to show in Finder  ·  \(item.subtitle)" : item.subtitle
        subtitle.isHidden = subtitle.stringValue.isEmpty
        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        let on = selected
        title.textColor = on ? .white : .labelColor
        subtitle.textColor = revealing ? (on ? .white : .controlAccentColor)
            : on ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        shortcut.textColor = on ? NSColor.white.withAlphaComponent(0.8) : .tertiaryLabelColor
        score.textColor = on ? NSColor.white.withAlphaComponent(0.7) : .tertiaryLabelColor
        icon.contentTintColor = on ? .white : .secondaryLabelColor
    }
}

enum Icons {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(path: String?, symbol: String?) -> NSImage? {
        if let p = path {
            if let i = cache.object(forKey: p as NSString) { return i }
            let i = NSWorkspace.shared.icon(forFile: p)
            cache.setObject(i, forKey: p as NSString)
            return i
        }
        guard let s = symbol else { return nil }
        return NSImage(systemSymbolName: s, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .regular))
    }
}
