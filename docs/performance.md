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

## Next work, in order

1. **Measure real workloads.** Record the app and helper separately in Instruments (Time Profiler, Allocations and
   Energy Log). Use the same Mac, power mode, index and query set for both revisions. Startup, first query, warm query,
   fast typing and a long scrolling session have different bottlenecks.
2. **Avoid rescoring when changing a kind filter.** The window currently makes an all-kind search for filter counts
   and a filtered search for full results. Cache ranked candidate IDs for a query and hydrate only the visible slice.
   Keep ranking, per-kind limits and weaker-match thresholds identical; filtering only the first 120 hits would lose
   valid deeper matches.
3. **Reduce search SQL overhead.** Profile metadata hydration and FTS coverage queries. Batch reads for the final
   candidate IDs, and consider a bounded prepared-statement cache if SQLite preparation shows up in profiles.
4. **Scale beyond large personal indexes.** Every semantic query currently scans every vector. Benchmark block sizes
   and Accelerate throughput first. Consider a disk-backed approximate nearest-neighbor index only when real index
   sizes justify its extra storage, maintenance and possible recall loss.
5. **Improve image cancellation.** The new queues bound work and prevent stale images from publishing. If native
   rendering still wastes time when scrolling, add per-consumer cancellation with Quick Look request cancellation and
   AVAssetImageGenerator cancellation, without canceling another view's shared request.
6. **Make first-run setup shorter.** The existing folder estimates and optional code step are useful, but a future
   pass can put code and indexing schedules in progressive disclosure. Keep privacy choices and folder estimates
   visible before indexing starts.
7. **Measure model variants separately.** A smaller model or more aggressive quantization could reduce disk/RAM use,
   but needs multilingual, screenshot, code and audio/video evals and a deliberate index migration. This pass keeps
   search quality and index compatibility stable.

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
previous revision. Do not report speed or bundle-size improvements until these measurements exist.
