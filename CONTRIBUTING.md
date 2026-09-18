# Contributing to LaunchDeck

Thanks for taking a look. This is a small, deliberately dependency-free macOS app —
one `swiftc` invocation, no Xcode project, no SwiftPM, no third-party packages.

## Requirements

- macOS 15 (Sequoia) or later, on Apple silicon
- Xcode **or** the Command Line Tools (`xcode-select --install`)

## Build and test

```sh
./build.sh                     # release build -> build/LaunchDeck.app
./build.sh debug               # debug build
./build/LaunchDeck.app/Contents/MacOS/LaunchDeck --selftest
```

`--selftest` is the project's safety net: it runs headless, uses a throwaway layout
file, and never touches your real `~/Library/Application Support/LaunchDeck/layout.json`.
Please run it before opening a PR, and keep it green.

Two more harnesses are available while working:

```sh
# offscreen render — no Screen Recording permission needed
./build/LaunchDeck.app/Contents/MacOS/LaunchDeck --snapshot /tmp/deck.png

# page-switch timing, and a regression check that the page dots follow the scroll
./build/LaunchDeck.app/Contents/MacOS/LaunchDeck --bench 60
```

## Adding a check

A new assertion is only worth adding if it can fail. After you add one, prove it:

```sh
python3 Tools/mutation-test.py                 # every mutation
python3 Tools/mutation-test.py M5-your-mutation # just one
```

The script copies `Sources/`, breaks exactly one repair by a **text anchor**, rebuilds,
and runs the suite. If the suite stays green, the mutation *survived* — meaning your
new check does not actually discriminate, and the run exits non-zero.

Anchors must be unique within the file they patch; a drifted anchor is reported as
`anchor appears 0 time(s), refusing to patch` rather than silently doing nothing.

## Code conventions

- **No macro-backed SwiftUI property wrappers** — no `@State`, `@StateObject`,
  `@Observable`, `@Environment`. They do not compile with Command Line Tools alone.
  Mutable UI state lives in `ObservableObject` view models and is consumed through
  `@ObservedObject` / `@Binding` / `@FocusState`.
- **One owner per piece of state.** The current page is owned by `PagingModel`
  (`UI/PagingState.swift`) and read only through `resolved(count:)`. The layout is
  owned by `DeckStore` (`Services/DeckStore.swift`).
- **Do not put the grid in the paging observation graph.** `PagesScroller` observes
  `PageJumper`, never `PagingModel` — merging them rebuilds up to 175 cells per scroll
  tick. This invariant is held by comments and review, not by the test suite.
- **Read-only stores stay read-only.** `DeckStore(readOnly: true)` is a per-call-site
  guarantee. The dev tools (`--bench`, `--snapshot`) pass it; any new call site must
  too, or it can overwrite a real user's layout.
- **Comments explain why, not what.** Where a fix looks arbitrary, say which failure it
  prevents — several existing comments do exactly that, and they are the most useful
  documentation in the repo.

## Pull requests

- One concern per PR, with the reason in the description.
- State what you ran: `./build.sh`, `--selftest` result, and any mutation run.
- If you change behaviour on purpose, say so explicitly and update `README.md`.
- Screenshots are welcome for UI changes; `docs/deck.png` is regenerated with
  `--snapshot`.

## Reporting bugs

Include your macOS version, the build you ran (`./build.sh` from which commit), and
what you expected versus what happened. If the deck lost or duplicated layout entries,
please attach a copy of `~/Library/Application Support/LaunchDeck/layout.json` — that
file is the whole persisted state, so it is usually enough to reproduce.
