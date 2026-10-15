# macOS performance and simplicity

This is a native Apple Silicon app, with macOS 14 as the minimum. The shipped application uses SwiftUI/AppKit,
Apple's readers, SQLite/FTS5, Accelerate and a static llama.cpp runtime with Metal. Sparkle supports signed updates when a distributor configures a feed; source builds use manual GitHub releases. The MLX
Python worker is a development reference and is not shipped.

## Changes in this pass

| Area | Change | Expected effect |
|---|---|---|
| Maintenance | Removed the separate desktop shell, portable readers, bundled vendor fetchers, device selection, non-Mac packaging and update feed | One app, one runtime, one set of native readers and one CI platform |
| Search | Wait 120 ms before semantic work; the window also debounces keyword work; stale generations cannot publish results | Fewer vector scans and GPU calls during rapid typing |
| Cold search | Show keyword results while waiting for the text encoder | File names and exact words remain usable during warm-up or model download |
| Idle | Default encoder timeout changed from 600 to 120 seconds; existing explicit settings are honored | Model and vector memory return sooner, with a cold-start tradeoff on the next search |
| Thumbnails | 12 MiB cost budget, 160 entries | Keeps a long browsing session from retaining every thumbnail |
| Previews | 48 MiB cost budget, 120 entries | Bounds retained large images; includes display scale, modification time and highlighted PDF terms in keys |
| Rendering | Share duplicate requests, render at most four images per cache, cancel queued work when clearing | Fewer duplicate renders and less work in bursts; old work cannot refill a cleared cache |
| Result views | Default to a lazy compact list; remember list/grid preference | Smaller image requests and less visual scanning for document searches |
| Window lifecycle | Cancel searches and discard main-window results on close; release the hotkey panel's views after its fade | Hidden UI releases its image state and cannot receive late search updates |

These are implementation changes and expected effects, not measured speedups. `NSCache` limits are eviction hints;
visible SwiftUI images, system caches, in-flight renders, model memory and vectors have their own footprint. Each
image cache permits four active renders, so thumbnails and previews together can have eight. Already-running native
renders may finish after cancellation, but cleared caches reject their output.

Removing the other platforms does not by itself reduce the old Mac app's bundle: those dependencies were already
excluded from its build. The model still needs about 865 MB on disk and dominates the installation. The embedding
model, quantization, prompts, vector format, index version and ranking rules were kept unchanged, so existing Mac
indexes remain compatible.

## Search work completed

- `Searcher.searchPage` builds all-kind counts and a complete selected-kind page from the same vector and FTS
  snapshot. It preserves the global 1,000-row FTS budget, the 100-file keyword budget within each filter, per-kind
  limits, score ordering, excerpts, code definition lines and weaker-match thresholds. Matches below the all-kind
  page limit remain available to filtered pages.
- The main window reuses its completed query vector when only a filter changes. It skips the intermediate keyword
  stage and model request in that case. Switching between files and code still uses the appropriate prompt.
- A single recent query retains its best segment per file, keyword coverage and snippets. Its result-page cache is
  limited to 16 pages of at most 256 results; its metadata cache holds at most 1,024 segments. A different query,
  explicit reload or idle vector release discards it.
- File and segment metadata are fetched with one join per 400 distinct segment IDs, shared by all/filtered views.
  Code fallback text and line locations use that same batch. Identifier definition lookups remain bounded to the
  first ten results, with up to 300 stretches per file.
- Keyword coverage combines up to 32 term lookups into one prepared statement; snippets are fetched together for
  newly needed files. Common results are hydrated once rather than once for each view.
- Cache freshness checks use SQLite's [`data_version`](https://www.sqlite.org/pragma.html#pragma_data_version)
  for other connections and `sqlite3_total_changes64` for the search connection's own writes. Committed indexing
  changes refresh cached file facts and vectors. Folder exclusions and file existence are still checked by the app.
- `SearchMetrics` exposes phase timings, actual vector scans, prepared statement counts and hydrated row counts.
  `digup-benchmark` exercises the production search implementation with deterministic synthetic indexes, without
  reading the app's real index, downloading a model or including query encoding in the reported search times.

## Reproduce the profiles

On an Apple Silicon Mac with full Xcode 26 or later:

```sh
# Current implementation only; output contains 10k, 50k and 100k-vector workloads.
scripts/profile-search.sh --sizes 10000,50000,100000 --iterations 15 --output search-profile.json

# The earlier implementation and the current one, on the same Mac.
python3 scripts/compare-search.py --baseline 0f0bd5f --output build.noindex/search-profile
```

The comparison creates separate Swift packages containing each revision's actual `DigUpKit` sources, builds both in
release mode with the same compiler, and runs them sequentially. The earlier version receives counters/timers and a
page API adapter that calls its original all-kind and filtered searches. Its ranking and SQL stay intact. No copy of
an older production search engine is shipped in the app. The comparator rejects unrecognized baseline layouts.

The fixture has one 768-dimensional float16 vector per file, six file kinds, repeated document text and deterministic
outliers. It includes exact-word matches and semantic matches beyond the all-kind result limit. Fifteen measurements
per workload give nearest-rank p50 and p95. Index creation/checkpointing and initial vector loading are reported
separately from query latency. Peak resident memory is the process high-water mark, cumulative across datasets.
Each scenario measures either one window update or a complete cycle through six filters, as its name indicates.

The reports cover first search, distinct queries, first-time filter cycles, repeated filter cycles and keyword-only
pages. They exclude the embedding model, UI rendering, outer app source validation and file existence checks. These
synthetic results measure engine work; they do not predict first-launch time, total app memory or every real query.
FTS coverage/snippet reads are part of the new ranking phase, so phase boundaries differ slightly from the old engine;
compare end-to-end search times for speedup claims.

The macOS workflow runs the native comparison and uploads `before.json`, `after.json` and `summary.json` as the
`search-profile-macos-arm64` artifact. Native and VPS reports are versioned under `benchmarks/results/`; VPS reports use actual Swift
search and SQLite code with a temporary CPU vector-math adapter instead of Apple's Accelerate and are separate from
native Mac measurements. Regression tests include 160 old/new hit-field comparisons in the VPS validation harness,
multilingual keyword tests, bounded SQL batches, deep filtered results, local/external writes, idle cache release,
code line targets, and window filter reuse/cancellation tests.

## Native Mac measurements

Measured in [the successful macOS CI run](https://github.com/manasseh-fikadu/DigUp-Mac/actions/runs/38768848550)
on October 15, 2026, using release builds and Apple's Accelerate backend. The arm64 runner reported macOS 26.6.2,
three processors and 7 GiB physical memory. The baseline is `0f0bd5f`; the optimized revision is `32d9146`.
Raw timings, phase measurements, memory high-water marks and revision IDs are saved in
[`benchmarks/results/macos-arm64-32d9146`](../benchmarks/results/macos-arm64-32d9146/).

A first-time cycle through all six kind filters, p50/p95 milliseconds:

| Vectors | Before p50 | After p50 | Before p95 | After p95 | Vector scans | Prepared statements |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 258.20 | 75.68 | 362.61 | 115.02 | 11 → 1 | 2687 → 28 |
| 50,000 | 1276.69 | 451.19 | 1542.56 | 615.67 | 11 → 1 | 2717 → 28 |
| 100,000 | 2570.53 | 645.41 | 3145.70 | 945.39 | 11 → 1 | 2717 → 28 |

At 100,000 vectors, a distinct-query window update changed from 479.97 to 302.40 ms p50 and from 494 to 10 prepared
statements. Revisiting the six cached filters changed from 2450.52 to 0.45 ms p50, with no new vector scans and six
revision-check statements. These figures measure the engine with precomputed query vectors, excluding model encoding
and UI work; filter-cache results apply only while that query remains cached.

Batching did not improve every workload. The 100,000-file keyword-only case changed from 309.69 to 319.24 ms p50
and from 341.90 to 434.79 ms p95, despite reducing prepares from 414 to 10. Common-word FTS coverage/snippet reads
remain expensive: the optimized distinct-query run averaged 81.06 ms in initial keyword selection and 184.39 ms in
ranking, which includes those additional FTS reads, versus 27.67 ms in vector scanning. This makes common-word FTS
work the next optimization target for this fixture; fewer statements alone are not evidence of lower latency.

The same CI run passed 114 tests across 15 suites, built the release app and verified its bundle signature. Model
reference tests still require the optional local model files described below. This run does not replace Instruments
profiling of a real library, model startup, interactive rendering or simultaneous indexing.

## VPS measurements

Measured on the same Linux VPS with Swift 6.2 release builds and SQLite 3.46.1. The temporary validation package uses
the production search/database code and a Swift SIMD CPU adapter in place of Accelerate. These are engine-only,
synthetic measurements; they are not Mac latency estimates. Raw reports and source identification are in
[`benchmarks/results`](../benchmarks/results/).

A first-time cycle through all six kind filters, p50/p95 milliseconds:

| Vectors | Before p50 | After p50 | Before p95 | After p95 | Vector scans | Prepared statements |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 584.55 | 149.02 | 603.34 | 166.31 | 11 → 1 | 2687 → 28 |
| 50,000 | 2359.98 | 476.62 | 2421.46 | 490.35 | 11 → 1 | 2717 → 28 |
| 100,000 | 4486.44 | 872.04 | 4583.60 | 890.28 | 11 → 1 | 2717 → 28 |

At 100,000 vectors, a distinct-query window update (all-kind counts plus a filtered page) changed from
808.55 to 493.96 ms p50, and from 494 to 10 prepared statements. A repeated six-filter cycle changed from 4513.40 to 0.89 ms p50
with no new vector scans and six revision-check statements. Repeated-page timings are sensitive to shared-VPS
scheduling; use the native comparison on your own Mac for decisions about user-visible latency.

The remaining distinct-query costs include the full vector matrix scan/conversion and FTS ranking over common words.
The result-page cache specifically removes repeated candidate ranking during filter revisits. A prepared-statement
cache was not added: batching removes most prepares without introducing statement lifetime/schema invalidation state.

## Remaining profiling work

1. Record real app/helper workloads in Instruments (Time Profiler, Allocations, Energy Log): cold/warm queries,
   typing, scrolling and indexing at the same time. Use the same Mac, power mode, index and query set for both revisions.
2. For indexes beyond personal-library sizes, benchmark Accelerate block sizes and memory bandwidth. Introduce
   approximate nearest-neighbor indexing only if scan time justifies its storage, maintenance and possible recall loss.
3. If scrolling profiles still show wasted work, cancel native Quick Look and AVAssetImageGenerator requests per
   consumer while preserving another view's shared render.
4. Consider shorter setup and alternative model/quantization sizes separately, with search-quality evals and an
   explicit index migration where vectors change.

## Mac verification

Run `scripts/check-mac.sh`, then `scripts/package-dmg.sh` for a local DMG. The native checks need full Xcode 26 or
later and an Apple Silicon Mac. CI does not download the 865 MB model; reference-vector tests may be skipped unless
the pinned model files are already installed. Run them locally with the model present before a release.

Use `scripts/dev-run.sh` so measurement runs have isolated defaults and indexes. Before shipping, check:

- First launch, model download, folder permissions, indexing estimates and pause/resume.
- A burst of typing: immediate panel keyword matches, window keyword matches after the pause, then semantic results;
  no old query replaces the new one. Clear or close the window while it is searching.
- List/grid switching, resizing at the minimum width, a narrow preview pane, light/dark mode, keyboard selection,
  Quick Look, opening a PDF page or video moment, Finder reveal, copying and dragging.
- Code filter, `code:` queries, code search turned off, a model that is not installed, and no-match states.
- Move the window between Retina and non-Retina displays; previews should be crisp and correctly scaled.
- Scroll through a large set of image/PDF/video results; inspect both peak and settled memory. Close the last search
  surface, wait two minutes, and confirm the query helper exits and vector memory is released.

For timing, use the existing `app.log` search timestamps. Keep p50 and p95 from a fixed query set, the index file/segment
counts, cold/warm status, peak app/helper footprint and CPU/energy observations. Compare with a clean checkout of the
previous revision. Keep engine-only benchmark gains separate from total app latency and bundle-size claims.
