#!/usr/bin/env python3
"""Compare two search-engine revisions on the same Apple Silicon Mac, without loading an embedding model.

    python3 scripts/compare-search.py --baseline 0f0bd5f --output build.noindex/search-profile

Builds isolated, dependency-free Swift packages containing each revision's actual DigUpKit sources and the same
synthetic benchmark. Legacy sources receive counters/timers and a page API adapter; their ranking and SQL stay intact.
The real app index is never opened. Temporary packages and synthetic indexes are removed when the run ends.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BASELINE = "0f0bd5f9a1c9773af3aa77c537fdf99b0eeb8eb9"


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def revision(ref):
    if ref == "working-tree":
        return ref
    return git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()


def sources(ref):
    prefix = "Sources/DigUpKit/"
    if ref == "working-tree":
        return {str(p.relative_to(ROOT)): p.read_text() for p in (ROOT / prefix).rglob("*.swift")}
    files = git("ls-tree", "-r", "-z", "--name-only", ref, "--", prefix).decode().split("\0")
    return {p: git("show", f"{ref}:{p}").decode() for p in files if p.endswith(".swift")}


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Unsupported baseline source layout; expected one occurrence of {old!r}")
    return source.replace(old, new, 1)


def instrument_legacy(files, public_types):
    """Only add observation and an adapter which calls the old all/filtered searches verbatim."""
    path = "Sources/DigUpKit/Searcher.swift"
    source = files[path]
    if "public func searchPage(" in source:
        return files
    source = replace_once(source, "public final class Searcher {", """public final class Searcher {
    public private(set) var vectorScanCount = 0
    public private(set) var lastMetrics = SearchMetrics()
    private var vectorTime = 0.0, keywordTime = 0.0, rankingTime = 0.0, hydrationTime = 0.0
    private func elapsed(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    public func searchPage(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil, limit: Int = 120) throws -> SearchPage {
        let statements = store.db.preparedStatementCount, scans = vectorScanCount
        let times = (vectorTime, keywordTime, rankingTime, hydrationTime)
        let all = try search(text, queryVector: queryVector, limit: limit)
        let hits = try kinds.map { try search(text, queryVector: queryVector, kinds: $0, limit: limit) } ?? all
        lastMetrics = SearchMetrics()
        lastMetrics.sqlStatements = store.db.preparedStatementCount - statements
        lastMetrics.vectorScans = vectorScanCount - scans
        lastMetrics.vectorMilliseconds = vectorTime - times.0
        lastMetrics.keywordMilliseconds = keywordTime - times.1
        lastMetrics.rankingMilliseconds = rankingTime - times.2
        lastMetrics.hydrationMilliseconds = hydrationTime - times.3
        return SearchPage(all: all, hits: hits)
    }
""")
    source = replace_once(source, "        // Meaning: score every vector", "        let vectorStart = DispatchTime.now().uptimeNanoseconds\n        // Meaning: score every vector")
    source = replace_once(source, "        // Words: FTS5", "        vectorTime += elapsed(vectorStart)\n        let keywordStart = DispatchTime.now().uptimeNanoseconds\n        // Words: FTS5")
    source = replace_once(source, "        // A file qualifies", "        keywordTime += elapsed(keywordStart)\n        let rankingStart = DispatchTime.now().uptimeNanoseconds\n        // A file qualifies")
    source = replace_once(source, "        let wordRank = Dictionary", "        rankingTime += elapsed(rankingStart)\n        let hydrationStart = DispatchTime.now().uptimeNanoseconds\n        let wordRank = Dictionary")
    source = replace_once(source, "        return hits\n", "        hydrationTime += elapsed(hydrationStart)\n        return hits\n")
    source = replace_once(source, "    private func score(_ query: [Float]) -> [Float] {", "    private func score(_ query: [Float]) -> [Float] {\n        vectorScanCount += 1")
    files[path] = source
    files["Sources/DigUpKit/BenchmarkTypes.swift"] = "import Foundation\n" + public_types
    path = "Sources/DigUpKit/Database.swift"
    source = files[path]
    if "preparedStatementCount" not in source:
        source = replace_once(source, "    let handle: OpaquePointer", """    public private(set) var preparedStatementCount = 0
    fileprivate func didPrepareStatement() { preparedStatementCount += 1 }
    let handle: OpaquePointer""")
        source = replace_once(source, "        self.db = db\n", "        self.db = db\n        db.didPrepareStatement()\n")
    files[path] = source
    return files


def prepare(folder, files, benchmark):
    folder.mkdir()
    for name, contents in files.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
    path = folder / "benchmarks/SearchBenchmark/Benchmark.swift"
    path.parent.mkdir(parents=True)
    path.write_text(benchmark)
    (folder / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "SearchProfile", platforms: [.macOS(.v14)],
    products: [.executable(name: "digup-benchmark", targets: ["SearchBenchmark"])],
    targets: [.target(name: "DigUpKit"),
              .executableTarget(name: "SearchBenchmark", dependencies: ["DigUpKit"], path: "benchmarks/SearchBenchmark")])
''')


def summarize(before, after):
    comparisons = []
    scenarios = ["firstSearch", "distinctQueries", "sixFilterCycle", "repeatedFilterCycle", "keywordPage"]
    for previous, current in zip(before["datasets"], after["datasets"]):
        assert previous["vectors"] == current["vectors"]
        rows = {}
        for name in scenarios:
            a, b = previous[name], current[name]
            rows[name] = {
                "beforeP50Milliseconds": a["p50Milliseconds"], "afterP50Milliseconds": b["p50Milliseconds"],
                "beforeP95Milliseconds": a["p95Milliseconds"], "afterP95Milliseconds": b["p95Milliseconds"],
                "p50Speedup": a["p50Milliseconds"] / max(b["p50Milliseconds"], 1e-9),
                "beforeStatements": a["meanStatements"], "afterStatements": b["meanStatements"],
                "beforeVectorScans": a["meanVectorScans"], "afterVectorScans": b["meanVectorScans"],
            }
        comparisons.append({"vectors": current["vectors"], "scenarios": rows})
    return {"beforeRevision": before.get("revision"), "afterRevision": after.get("revision"), "datasets": comparisons}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=BASELINE)
    parser.add_argument("--current", default="working-tree")
    parser.add_argument("--sizes", default="10000,50000,100000")
    parser.add_argument("--iterations", default="15", type=int)
    parser.add_argument("--output", type=Path, default=ROOT / "build.noindex/search-profile")
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        parser.error("Native comparison requires an Apple Silicon Mac with Xcode 26 or later")
    before_ref, after_ref = revision(args.baseline), revision(args.current)
    current = sources(after_ref)
    types = current["Sources/DigUpKit/Searcher.swift"]
    types = types[types.index("/// One window update:"):types.index("/// Hybrid search:")]
    before = instrument_legacy(sources(before_ref), types)
    benchmark = (ROOT / "benchmarks/SearchBenchmark/Benchmark.swift").read_text()
    env = dict(os.environ)
    if not env.get("DEVELOPER_DIR") and Path("/Applications/Xcode.app").exists():
        env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="DigUp-compare-") as scratch:
        for label, ref, code in [("before", before_ref, before), ("after", after_ref, current)]:
            package = Path(scratch) / label
            prepare(package, code, benchmark)
            env["DIGUP_BENCHMARK_REVISION"] = ref
            print(f"Profiling {label}: {ref}", flush=True)
            subprocess.run(["xcrun", "swift", "run", "-c", "release", "--package-path", str(package),
                            "digup-benchmark", "--sizes", args.sizes, "--iterations", str(args.iterations),
                            "--directory", scratch, "--output", str(args.output.resolve() / f"{label}.json")],
                           env=env, stdout=subprocess.DEVNULL, check=True)
    previous = json.loads((args.output / "before.json").read_text())
    current = json.loads((args.output / "after.json").read_text())
    summary = summarize(previous, current)
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
