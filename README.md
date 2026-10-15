<p align="center"><img src="docs/logo.png" width="96" alt=""></p>
<h1 align="center">DigUp for Mac</h1>
<p align="center"><b>Describe it. Dig it up.</b><br>Private search for the files on your Mac.</p>

DigUp finds pictures, screenshots, PDFs, documents, audio, video and code by what you remember about them. Search for
“the clause about pets in the lease”, “a dog on the beach”, or “where they talk about sleep”. Exact names, numbers and
words work too. Results open at the matching page, moment or line.

This source tree targets **Apple Silicon Macs running macOS 14 or later**. The app uses SwiftUI and AppKit, Apple's
file readers and text recognition, and a statically linked llama.cpp runtime with Metal. There is one native app and
one helper executable. This is a macOS-focused derivative of [ARahim3/DigUp](https://github.com/ARahim3/DigUp),
with the original MIT license and author attribution preserved.

## Install the DMG

**Release status:** no DMG has been uploaded for this version yet. [Native Mac CI](https://github.com/manasseh-fikadu/DigUp-Mac/actions/runs/38768848550)
has passed the release build, 114 tests, bundle signature verification and large-index benchmarks. Interactive UI
verification and DMG packaging remain to be done on your Mac. Follow [Build on your Mac](#build-on-your-mac).
Once a DMG is published:

1. Open [this repository's Releases](https://github.com/manasseh-fikadu/DigUp-Mac/releases) and download
   `DigUp-<version>.dmg` from the release's **Assets**. Your Mac needs an M-series chip and macOS 14 or later.
2. Double-click the downloaded DMG in Finder.
3. Drag **DigUp.app** onto the **Applications** shortcut in the DMG window. Quit an older DigUp before replacing it.
4. Eject the mounted **DigUp** disk and open **DigUp** from Applications.
5. Complete setup: choose your folders, allow access when macOS asks, and download the model once (about 865 MB).
6. Press **⇧⌘Space** to search. The app stays in the menu bar when its window closes.

If macOS blocks a build because its developer cannot be verified, first confirm you downloaded it from this
repository. After trying to open it, go to **System Settings → Privacy & Security → Open Anyway** and confirm opening
DigUp. Follow [Apple's instructions](https://support.apple.com/en-us/102445) for your macOS version. Notarized releases
should open normally. A local ad-hoc signed DMG is for testing; distribution builds should be signed and notarized.

To update manually, quit DigUp, install the newer DMG the same way and replace the app in Applications. Your model,
settings and index stay in your Library folder. **Check for Updates…** opens this repository's Releases page until
this project has its own signed update feed.

## Use it

1. Choose the folders DigUp may read. Setup estimates the first indexing pass before you commit to a large folder.
2. Download the embedding model once (about 865 MB). Everything indexed and searched stays on your Mac.
3. Press **⇧⌘Space** from any app and describe what you need.

The main window starts with a compact list. Switch to the picture grid for visual searches; DigUp remembers your
choice. The preview shows why a result matched. Code search is optional, has its own chosen folders, and is available
through the Code filter or `code: your query`.

| Shortcut | Action |
|---|---|
| ⇧⌘Space | Open the search panel; change this shortcut in Settings |
| ↑ ↓ | Select results; in the grid, move by a row |
| ← → | Move between grid results after selecting one |
| ↩ | Open at the matching page, moment or line |
| Space / ⌘Y | Quick Look after selecting a result |
| ⌘↩ | Show in Finder |
| ⌘C | Copy the selected file |
| ⌘O | Open the panel's search in the main window |
| ⌘L | Focus and select the main window's search field |
| ⌘1…⌘6 / ⌘7 | Filter by file kind / code |

DigUp lives in the menu bar. From there you can pause indexing or open Settings. Videos open at their moment in
QuickTime Player or IINA; code opens at its line in your chosen editor.

## Small when idle

- Native ImageIO, PDFKit, AVFoundation and Vision read files without bundled media/PDF engines.
- Indexing runs in a helper process that exits after its work, returning its model memory to macOS.
- Exact words appear while the text encoder starts. Semantic searches wait for a 120 ms pause in typing, avoiding
  repeated GPU work and full vector scans during rapid typing.
- The text encoder and vector matrices unload after two minutes without a query by default. The next search warms
  them again. An existing custom `encoderIdleSeconds` setting still takes precedence.
- Hidden panels release their views; closing the main window cancels its searches. Lists and grids create rows
  lazily. Thumbnail and preview caches have 12 MiB and 48 MiB cost budgets, share duplicate
  requests, and each allow at most four image renders at a time. Cache clearing prevents old renders from refilling
  them. `NSCache` budgets are eviction hints, not a cap on the app's total memory.
- Changing a kind filter reuses the query vector, scored candidates and bounded result-page cache. File/segment
  metadata and keyword coverage are read in batches, and index writes invalidate cached search results.
- New files are indexed incrementally. Bulk indexing respects thermal state, Low Power Mode, your battery preference
  and optional indexing hours.

The model download is separate from the app bundle. Removing other platforms simplifies maintenance; the previous
Mac build already omitted their libraries. Bundle size, latency and energy improvements still need measurements on
real Mac hardware. See [the performance notes](docs/performance.md) for the remaining work and a measurement plan.

## What gets read

Only your chosen folders. DigUp reads images (including HEIC and RAW formats supported by macOS), screenshot text,
PDFs including scans, text and office documents, and audio/video supported by AVFoundation. Long documents are indexed
in stages so smaller files become searchable first. Audio uses overlapping 30-second windows; video uses frames per
shot and its soundtrack.

Code search is off by default. It reads source, notebook inputs and project docs, and respects git ignores. DigUp skips
keys, certificates, password files, hidden folders, app bundles, caches, generated code and cloud placeholders whose
contents would need downloading. It never modifies or uploads your files.

There is no account or telemetry. Network access downloads the model. Updates are manual by default; automatic
update checks are available only in builds configured with this project's own signed feed. The model is EmbeddingGemma 2, quantized to Q8_0, with text, images and audio mapped into
the same 768-dimensional space. SQLite FTS5 supplies exact-word matches and Accelerate scores vectors stored as float16.

## Build on your Mac

Use **Xcode 26 or later**, git, and CMake (`brew install cmake`), or `uv` for the script's pinned CMake environment.
Clone this repository, then select full Xcode if necessary:

```sh
git clone https://github.com/manasseh-fikadu/DigUp-Mac.git
cd DigUp-Mac
sudo xcode-select -s /Applications/Xcode.app
scripts/build-llama.sh
swift test
./build.sh
scripts/package-dmg.sh
```

`build.sh` builds the runtime if needed, embeds the `digup` helper and Sparkle, and signs the app. The outputs are
`build.noindex/DigUp.app` and `build.noindex/DigUp-<version>.dmg`. Open the app directly or drag it from the DMG into
Applications. The local DMG needs no notarization credentials; macOS may warn about an ad-hoc signed build.

For stable local signing, put your signing identity in `.sign-id` (gitignored), or pass `SIGN_ID`. For distribution,
use the existing notarized release script:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=DigUp scripts/release.sh
```

That script signs, notarizes and staples the app and DMG. It requires your Developer ID and a `notarytool` keychain
profile; see its header. It does not publish anything. Run `scripts/check-mac.sh` to build, test, bundle and verify the
app before packaging. A macOS CI workflow runs these checks too.

When the Mac build has been tested, publish the DMG under this repository's **Releases → Draft a new release**. Pick
a tag matching the app version in `Resources/Info.plist`, upload the DMG from `build.noindex/` (or
`build.noindex/release/` for the notarized build), describe what was tested, then publish the release. Until then,
the Releases page has no downloadable app for this version.

Automatic updates are intentionally unconfigured in source builds. To enable them for your distribution, supply your
own `SPARKLE_FEED` URL and `SPARKLE_KEY` public key when building, and sign the feed's releases with your matching
private key. `scripts/appcast.py` defaults to this repository's download URLs. The original project's update feed,
signing key and Homebrew publishing workflow are not used here.

This repository cannot build the app or a working DMG on a Linux VPS: SwiftUI, AppKit, Metal, code signing and DMG
creation require macOS. Swift syntax and shell scripts can be checked there.

## Development

`Sources/DigUpApp` contains the native interface; `Sources/DigUpKit` contains crawling, extraction, storage and search.
Its `Platform` folder uses Apple frameworks directly. `Sources/LlamaRuntime` bridges the pinned llama.cpp build.
`Sources/digup` is the helper and developer CLI (`.build/release/digup --help`).

Profile large synthetic indexes on your Mac without downloading a model:

```sh
scripts/profile-search.sh --sizes 10000,50000,100000 --iterations 15 --output search-profile.json
python3 scripts/compare-search.py --baseline 0f0bd5f --output build.noindex/search-profile
```

The comparison builds both revisions in temporary packages and runs them sequentially on the same machine. It reports
p50/p95 latency, prepared statement counts, vector scans, phase timings and process peak memory. Mac CI runs the same
comparison and uploads its JSON reports. See [performance notes](docs/performance.md) for methodology and results.

Use `scripts/dev-run.sh` for an isolated development app, model folder, settings and index. Tests use temporary indexes.
`evals/` contains search-quality checks. `scripts/make-testbed.sh` generates test media and needs developer-installed
ffmpeg; ffmpeg is not part of the app. `worker/` is an optional MLX Python reference for model comparisons, never bundled
with DigUp.

## Remove it

Quit DigUp, delete the app and `~/Library/Application Support/DigUp` (models and indexes), then remove
`~/Library/Preferences/com.abdurrahim.DigUp.plist` if you also want to reset settings.

## Acknowledgements and license

Built on [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) by Google DeepMind (Apache 2.0),
[llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) and [Sparkle](https://sparkle-project.org) (MIT).
Third-party notices ship in `Resources/Acknowledgements.txt`. DigUp is not affiliated with Google or Apple.
DigUp is [MIT licensed](LICENSE).
