# Contributing to DigUp

DigUp is a native macOS app for Apple Silicon. Keep changes focused, explain the user-visible behavior, and build
with full Xcode 26 or later. Open an issue before a substantial contribution so the direction can be agreed upon.

## Checks

Run `scripts/check-mac.sh` on your Mac. It builds the pinned Metal runtime, runs the Swift tests, builds the release
app and verifies its signature. For search/ranking changes, run the relevant `evals/` queries before and after. For
performance changes, measure both versions on the same Mac and index; see `docs/performance.md`.

The UI is in `Sources/DigUpApp`, the engine in `Sources/DigUpKit`, the Apple framework readers in its `Platform`
folder, and the llama.cpp bridge in `Sources/LlamaRuntime`. `Sources/digup` supplies the CLI and the app's indexing
and query helpers. The optional `worker/` MLX reference is development-only and is never bundled.

Prefer native controls and system frameworks. Keep indexing and rendering off the main actor, preserve keyboard and
VoiceOver access, and bound caches and background work. Do not add telemetry, accounts or cloud indexing.

## Bug reports

Include the Mac chip and RAM, macOS and DigUp versions, the steps or search that failed, and the expected behavior.
Logs are in `~/Library/Application Support/DigUp/index.noindex`, including `app.log`, `indexer.log` and worker logs.
They may contain paths and search text; review them before sharing.

For a security problem, use the repository's private vulnerability-reporting channel instead of a public issue.
