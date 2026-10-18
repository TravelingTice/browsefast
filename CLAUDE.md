# BrowseFast

Agentic web browser for macOS (SwiftUI). The app lives in `app/`, the brand sheet in `brand/`. See `README.md` for structure and how to run it.

## Session log: read it

Every run of the app writes to `~/Library/Logs/BrowseFast/session.log`. It is the main way to see what happened in a run: which keys were checked, which pages loaded, and the exact element list the agent saw on each page. Read it after running or changing the app, before guessing at behavior.

- Each launch starts with a `===== New session started … =====` line. Show only the latest session:
  `awk '/New session started/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' ~/Library/Logs/BrowseFast/session.log`
- Every line is `<ISO timestamp> [category] message`, with optional indented detail lines below it.
- Categories so far: `session`, `setup`, `keys`, `browser` (navigation), `page` (element snapshots).
- When the file passes 10 MB it is moved to `session.1.log`.

## Writing logs

- Use `Log.write(category, message, details:)` from `app/Sources/BrowseFastUI/Log.swift`. Don't use `print`.
- Log every meaningful step of new features (agent decisions, actions, model calls and their errors), so a run can be understood from the log alone.
- Never log API keys, or values typed into password fields. The element script already hides password values.

## Element snapshots

`app/Sources/BrowseFastUI/Resources/elements.js` is injected into every page. `window.__browsefast.snapshot()` returns the visible interactive elements, and `PageSnapshot.elementList` formats them as the numbered list Jev decides on. After changing either, run the app and check the `[page]` entries in the log.

## Conventions

- Commit directly to `main` unless asked otherwise.
- Build and run with `app/run.sh` (`app/run.sh build` to only build). Don't use plain `swift build`/`swift run` for builds you launch: the script signs the binary with a stable identity, and an unsigned rebuild makes the Keychain ask the user for their password again.
