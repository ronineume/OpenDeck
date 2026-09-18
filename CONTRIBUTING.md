# Contributing to OpenDeck

Thanks for taking a look. This is a small, deliberately dependency-free macOS app —
one `swiftc` invocation, no Xcode project, no SwiftPM, no third-party packages.

## Requirements

- **Deployment target:** macOS 15, Apple silicon
- **Developed and tested on:** macOS 27 (26A428)
- Xcode **or** the Command Line Tools (`xcode-select --install`)

## Build and test

```sh
./build.sh                     # release build -> build/OpenDeck.app
./build.sh debug               # debug build
./build/OpenDeck.app/Contents/MacOS/OpenDeck --selftest
```

`--selftest` is the project's safety net: it runs headless, uses a throwaway layout
file, writes no preferences, and never touches your real
`~/Library/Application Support/OpenDeck/layout.json` or your real preferences domain.
Please run it before opening a PR, and keep it green.

Two more harnesses are available while working:

```sh
# offscreen render — no Screen Recording permission needed
./build/OpenDeck.app/Contents/MacOS/OpenDeck --snapshot /tmp/deck.png

# page-switch timing, plus two regression probes: that the page dots follow the
# scroll, and that a remembered page is restored while the deck is being built
./build/OpenDeck.app/Contents/MacOS/OpenDeck --bench 60
```

## Adding a check

A new assertion is only worth adding if it can fail. After you add one, prove it:

```sh
python3 Tools/mutation-test.py                  # every mutation
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
  guarantee, and it covers more than `save()`: `--bench` and `--snapshot` must not even
  carry state over. Any new call site that builds a store without an explicit `storeURL`
  is a call site that can write into a real user's Application Support folder.
- **Headless runs write nothing.** `--selftest`, `--bench` and `--snapshot` set
  `AppEnvironment.isHeadless` before anything reads `DeckSettings.shared`, and
  `DeckSettings` then builds its store with `persists: false`
  (`Services/DeckSettings.swift`). Every property there writes itself back through its
  `didSet` and the initialiser writes too, so a guard placed at the call sites is a guard
  someone will forget; keep it in front of the store instead. Reads stay allowed on
  purpose — `--snapshot` renders the real settings, and gating reads would make its
  picture a lie.
- **The pre-rename identity lives in exactly one place.** `StateHandover`
  (`Services/StateHandover.swift`) owns the only occurrences of `LaunchDeck` and
  `local.launchdeck.app` in the repo. It runs once from the app's startup path, copies
  instead of moving, and never overwrites live state — it is the only path that can
  strand a user's layout, so keep it copy-only and keep its checks green.
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
please attach a copy of `~/Library/Application Support/OpenDeck/layout.json` — that
file is the whole persisted state, so it is usually enough to reproduce.
