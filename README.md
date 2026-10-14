# FastLauncher

An Alfred-style launcher for macOS, built on [fsearch](https://github.com/noahdunnagan/fsearch).

Press **⌘Space**, then:

| You type | You get |
|---|---|
| `saf` | apps: Safari. Fuzzy: `vsc` finds Visual Studio Code, `safri` finds Safari |
| <code>&nbsp;report</code> (leading space, or `'`) | files across the whole disk, via fsearch. The space turns into a **Files** pill in the search bar; ⌫ on an empty line goes back to apps |
| `45+32/658` | the answer as you type. ⏎ copies it |

## Install

Needs macOS 13+ and the Xcode command line tools (`xcode-select --install`).

```bash
./build.sh --install
```

This compiles the app, installs fsearch to `~/.local/bin` if it's missing (the
prebuilt release on Apple Silicon; on Intel it needs Rust), then copies the
app to `/Applications` and opens it. A magnifying glass shows up in the menu bar.

### Take ⌘Space from Spotlight

Spotlight owns ⌘Space until you turn its shortcut off:
**System Settings → Keyboard → Keyboard Shortcuts… → Spotlight →** uncheck
**Show Spotlight search**. FastLauncher asks about this on first launch.

To use another shortcut instead:

```bash
defaults write dev.fastlauncher.app Hotkey "opt+space"
```

then quit and reopen FastLauncher.

### Full Disk Access (optional)

FastLauncher starts the fsearch daemon, which indexes your disk (seconds
to a few minutes the first time). Without Full Disk Access it skips protected
folders such as Mail and Messages. To index everything, add FastLauncher in
**System Settings → Privacy & Security → Full Disk Access**. Each rebuild
changes the ad-hoc signature, so you'll need to grant it again after one.

## Keys

| Key | Action |
|---|---|
| ↑ ↓ (or ⌃P ⌃N) | move the selection |
| ⏎ | open (for a math result: copy it) |
| ⌘1 … ⌘9 | open that row |
| ⌘⏎ | reveal in Finder |
| ⌥⏎ | copy the path |
| ⇥ | complete the selected name into the search line |
| space (first character) | switch to file search |
| ⌫ on an empty line | leave file search |
| esc | close |

## File search

Everything after the leading space goes to fsearch as written, so its query
language works:

```
 invoice ext:pdf
 notes in:~/Documents mtime:<7d
 type:image size:>5mb
 grep:TODO in:~/Developer/app
```

Files you open from FastLauncher rank higher for a while (fsearch's frecency).

## Apps

FastLauncher scans `/Applications`, `/System/Applications`, `~/Applications`
and Finder. It also asks fsearch for apps found anywhere else, such as in
Downloads or on a mounted disk image. It learns as you go: the app you pick
for a query comes first the next time you type that query, and the apps you
launch most rank higher.

When nothing matches, it offers to search files or Google instead.

## Math

Accepts `+ - * / ^ %`, parentheses (you can leave the last ones unclosed while
typing), `x`/`×`/`÷`, `!`, `pi`, `e`, `sqrt`, `sin`/`cos`/`tan` (in radians),
`ln`, `log`, `abs`, and more. `15% * 80` gives 12 and `10 % 3` gives 1. A
plain number, or anything that doesn't parse, shows no result.

## Layout

```
Sources/main.swift          app delegate, ⌘Space hotkey (Carbon), menu bar item
Sources/Launcher.swift      the panel, results list, keys, actions
Sources/Calc.swift          the expression parser
Sources/Fuzzy.swift         app name matching
Sources/Apps.swift          app catalog and launch history
Sources/FSearchClient.swift fsearch daemon client (JSON lines over its unix socket)
Tests/                      Linux tests for the non-UI parts, plus a fake daemon
```
