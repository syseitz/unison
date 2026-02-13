#!/usr/bin/env python3
"""Benchmark: Normal vs Lowmemory mode comparison.

Safe benchmark that uses an isolated UNISON dir (never touches ~/.unison).
Measures RSS (max resident set size) and wall-clock time for:
  - Initial sync (all files new)
  - SS1 (steady-state, nothing changed)
  - SS2 (second steady-state run)
  - Sync after modifying 1% of files
  - Sync after adding 1% new files
  - Sync after deleting 1% of files
  - Re-initial sync (archives deleted)

Creates a realistic directory structure with:
  - Flat directories (dir_NNNN/file_*.txt)
  - Nested directories (nested/a/b/c/.../file_*.txt) up to 5 levels deep

Usage:
  python3 bench/bench_compare.py [--no-cache] [--lowmemory-only] [NUM_FILES]

Options:
  --no-cache         Force fresh measurement of normal mode (ignore cache)
  --lowmemory-only   Only run lowmemory mode, use cached normal results

Exit codes:
  0 = benchmark completed (check output for regressions)
  1 = build or runtime error
"""
import os
import subprocess
import time
import shutil
import re
import sys
import multiprocessing
import json
import argparse

parser = argparse.ArgumentParser(description="Unison benchmark: Normal vs Lowmemory")
parser.add_argument("num_files", nargs="?", type=int, default=100_000,
                    metavar="NUM_FILES", help="Number of test files (default: 100000)")
parser.add_argument("--no-cache", action="store_true",
                    help="Force fresh normal-mode measurement (ignore cache)")
parser.add_argument("--lowmemory-only", action="store_true",
                    help="Only run lowmemory mode, load normal results from cache")
args = parser.parse_args()

NUM_FILES = args.num_files
FILES_PER_DIR = 5000
NEST_DEPTH = 5
NESTED_FRACTION = 0.2
CHANGE_FRACTION = 0.01  # 1% of files for modify/add/delete phases
N_CHANGE = max(100, int(NUM_FILES * CHANGE_FRACTION))

CACHE_VERSION = 2  # Bump when adding/removing phases

# Use external drive if available, otherwise /tmp
_EXTERNAL_BASE = "/Volumes/Daten/.caches"
BENCH_DIR = os.path.join(_EXTERNAL_BASE if os.path.isdir(_EXTERNAL_BASE) else "/tmp",
                         f"unison_bench_{os.getpid()}")
SRC = os.path.join(BENCH_DIR, "src")
DST = os.path.join(BENCH_DIR, "dst")
UNISON_HOME = os.path.join(BENCH_DIR, "unison_home")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
UNISON = os.path.join(PROJECT_DIR, "_build", "default", "src", "linktext.exe")

_CACHE_BASE = _EXTERNAL_BASE if os.path.isdir(_EXTERNAL_BASE) else "/tmp"
CACHE_FILE = os.path.join(_CACHE_BASE, f"unison_bench_normal_cache_{NUM_FILES}.json")

COMMON_ARGS = [
    "-batch", "-auto", "-silent", "-times", "-fastcheck", "true",
    "-confirmbigdel=false", "-logfile", "/dev/null", "-contactquietly",
    "-dumbtty",
]


# --------------- Cache ---------------

def load_normal_cache() -> list | None:
    """Load cached normal-mode results if they exist and match current config."""
    if not os.path.exists(CACHE_FILE):
        return None
    try:
        with open(CACHE_FILE) as f:
            data = json.load(f)
        if data.get("version") != CACHE_VERSION:
            return None
        if data.get("num_files") != NUM_FILES:
            return None
        results = data.get("results")
        if not results:
            return None
        ts = data.get("timestamp", "unknown")
        print(f"  Using cached normal-mode results from {ts}")
        print(f"  Cache: {CACHE_FILE}")
        return results
    except (json.JSONDecodeError, KeyError, TypeError):
        return None


def save_normal_cache(results: list) -> None:
    """Save normal-mode results to cache file."""
    data = {
        "version": CACHE_VERSION,
        "num_files": NUM_FILES,
        "results": results,
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    with open(CACHE_FILE, "w") as f:
        json.dump(data, f, indent=2)
    print(f"  Normal-mode results cached to {CACHE_FILE}")


# --------------- File creation ---------------

def _create_batch(args_tuple: tuple) -> int:
    """Worker: create a batch of files. Returns count created."""
    dirs_with_files = args_tuple
    count = 0
    for dir_path, files in dirs_with_files:
        os.makedirs(dir_path, exist_ok=True)
        for fname, content in files:
            with open(os.path.join(dir_path, fname), "w") as fh:
                fh.write(content)
            count += 1
    return count


def create_test_files():
    """Create NUM_FILES small files in SRC with a mixed flat + nested structure."""
    num_nested = int(NUM_FILES * NESTED_FRACTION)
    num_flat = NUM_FILES - num_nested
    num_flat_dirs = max(1, num_flat // FILES_PER_DIR)
    num_nested_dirs = max(1, num_nested // FILES_PER_DIR)
    total_dirs = num_flat_dirs + num_nested_dirs * NEST_DEPTH

    print(
        f"Creating {NUM_FILES:,} files "
        f"({num_flat:,} flat + {num_nested:,} nested, "
        f"~{total_dirs:,} dirs, depth up to {NEST_DEPTH})...",
        flush=True,
    )
    t0 = time.time()

    all_work: list[tuple[str, list[tuple[str, str]]]] = []

    # Flat directories
    file_idx = 0
    for d in range(num_flat_dirs):
        dir_path = os.path.join(SRC, f"dir_{d:05d}")
        files = []
        for f in range(FILES_PER_DIR):
            files.append((f"file_{file_idx:07d}.txt", f"content_{file_idx}\n"))
            file_idx += 1
        all_work.append((dir_path, files))

    # Nested directories
    files_placed = 0
    branch = 0
    while files_placed < num_nested:
        branch_base = os.path.join(SRC, "nested", f"branch_{branch:04d}")
        path = branch_base
        for level in range(NEST_DEPTH):
            path = os.path.join(path, f"lv{level}")
            remaining = num_nested - files_placed
            n_here = min(FILES_PER_DIR, remaining)
            if n_here <= 0:
                break
            files = []
            for f in range(n_here):
                files.append(
                    (f"nf_{file_idx:07d}.txt", f"nested_{file_idx}\n")
                )
                file_idx += 1
                files_placed += 1
            all_work.append((path, files))
            if files_placed >= num_nested:
                break
        branch += 1

    # Parallel creation
    ncpu = multiprocessing.cpu_count()
    batch_size = max(1, len(all_work) // (ncpu * 4))
    batches = [all_work[i:i + batch_size] for i in range(0, len(all_work), batch_size)]

    for dir_path, _ in all_work:
        os.makedirs(dir_path, exist_ok=True)

    with multiprocessing.Pool(ncpu) as pool:
        counts = pool.map(_create_batch, batches)

    total_created = sum(counts)
    t1 = time.time()
    print(
        f"Created {total_created:,} files in {len(all_work):,} dirs "
        f"using {ncpu} workers ({t1 - t0:.1f}s)\n",
        flush=True,
    )


# --------------- File mutation helpers ---------------

def modify_files(src_dir: str, count: int) -> int:
    """Modify `count` existing files in the first flat directories."""
    modified = 0
    d = 0
    while modified < count:
        dir_path = os.path.join(src_dir, f"dir_{d:05d}")
        if not os.path.isdir(dir_path):
            break
        for fname in sorted(os.listdir(dir_path)):
            if modified >= count:
                return modified
            fpath = os.path.join(dir_path, fname)
            if os.path.isfile(fpath):
                with open(fpath, "w") as fh:
                    fh.write(f"modified_{modified}_{time.time()}\n")
                modified += 1
        d += 1
    return modified


def add_files(src_dir: str, count: int) -> int:
    """Add `count` new files in a dedicated subdirectory."""
    add_dir = os.path.join(src_dir, "bench_added")
    os.makedirs(add_dir, exist_ok=True)
    for i in range(count):
        with open(os.path.join(add_dir, f"added_{i:07d}.txt"), "w") as fh:
            fh.write(f"added_{i}\n")
    return count


def delete_files(src_dir: str, count: int) -> int:
    """Delete `count` files from the last flat directories (no overlap with modify)."""
    deleted = 0
    flat_dirs = sorted([
        d for d in os.listdir(src_dir)
        if d.startswith("dir_") and os.path.isdir(os.path.join(src_dir, d))
    ], reverse=True)
    for dirname in flat_dirs:
        dir_path = os.path.join(src_dir, dirname)
        for fname in sorted(os.listdir(dir_path), reverse=True):
            if deleted >= count:
                return deleted
            fpath = os.path.join(dir_path, fname)
            if os.path.isfile(fpath):
                os.remove(fpath)
                deleted += 1
    return deleted


# --------------- Benchmark ---------------

def parse_time_output(stderr_text: str) -> dict:
    """Parse macOS /usr/bin/time -l output."""
    result = {}
    for line in stderr_text.split("\n"):
        line = line.strip()
        m = re.search(r"([\d.]+)\s+real", line)
        if m:
            result["wall_s"] = float(m.group(1))
        if "maximum resident set size" in line:
            m2 = re.search(r"(\d+)", line)
            if m2:
                result["rss_bytes"] = int(m2.group(1))
    return result


def run_sync(label: str, extra_args: list, env: dict) -> dict:
    """Run a unison sync and return timing/memory stats."""
    cmd = ["/usr/bin/time", "-l", UNISON, SRC, DST,
           "-servercmd", UNISON] + COMMON_ARGS + extra_args

    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    t1 = time.time()

    wall = t1 - t0
    stats = parse_time_output(r.stderr)
    rss_mb = stats.get("rss_bytes", 0) / (1024 * 1024)

    status = "OK" if r.returncode == 0 else f"FAIL(rc={r.returncode})"
    print(f"  {label:30s}  {wall:7.1f}s  {rss_mb:7.1f} MB RSS  [{status}]", flush=True)

    if r.returncode != 0:
        all_out = r.stdout.strip()
        all_err = r.stderr.strip()
        if all_out:
            print(f"    STDOUT ({len(all_out)} chars):")
            for line in all_out.split("\n")[-20:]:
                print(f"    > {line}")
        if all_err:
            time_keywords = [
                "involuntary context", "instructions retired",
                "cycles elapsed", "peak memory footprint",
                "maximum resident", "average shared",
                "average unshared", "page reclaims",
                "page faults", "swaps", "block input",
                "block output", "messages sent",
                "messages received", "signals received",
                "voluntary context",
            ]
            err_lines = [l for l in all_err.split("\n")
                         if not any(x in l for x in time_keywords)]
            if err_lines:
                print(f"    STDERR (filtered):")
                for line in err_lines[-20:]:
                    print(f"    > {line}")

    return {"label": label, "wall_s": wall, "rss_mb": rss_mb, "rc": r.returncode}


def run_benchmark(mode_label: str, extra_args: list) -> list:
    """Run all benchmark phases for a given mode."""
    env = os.environ.copy()
    env["UNISON"] = UNISON_HOME

    # Clean state
    for d in [DST, UNISON_HOME]:
        if os.path.exists(d):
            shutil.rmtree(d)
        os.makedirs(d, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"  {mode_label}")
    print(f"{'='*60}")

    results = []

    # Phase 1-3: Initial sync + steady state
    results.append(run_sync("Initial sync", extra_args, env))
    results.append(run_sync("SS1 (nothing changed)", extra_args, env))
    results.append(run_sync("SS2 (nothing changed)", extra_args, env))

    # Phase 4: Modify files in SRC, sync to DST
    n = modify_files(SRC, N_CHANGE)
    print(f"  --- Modified {n:,} files in SRC ---")
    results.append(run_sync("Sync after modify", extra_args, env))

    # Phase 5: Add new files to SRC, sync to DST
    n = add_files(SRC, N_CHANGE)
    print(f"  --- Added {n:,} files to SRC ---")
    results.append(run_sync("Sync after add", extra_args, env))

    # Phase 6: Delete files from SRC, sync to DST
    n = delete_files(SRC, N_CHANGE)
    print(f"  --- Deleted {n:,} files from SRC ---")
    results.append(run_sync("Sync after delete", extra_args, env))

    # Phase 7: Re-initial sync (delete archives + DST, sync from scratch)
    for d in [DST, UNISON_HOME]:
        shutil.rmtree(d)
        os.makedirs(d, exist_ok=True)
    print(f"  --- Archives + DST deleted for re-initial sync ---")
    results.append(run_sync("Re-initial sync", extra_args, env))

    return results


# --------------- Main ---------------

def main():
    use_cache = not args.no_cache
    lowmemory_only = args.lowmemory_only

    num_nested = int(NUM_FILES * NESTED_FRACTION)
    num_flat = NUM_FILES - num_nested
    print(f"{'='*60}")
    print(f"  Unison Benchmark: Normal vs Lowmemory")
    print(f"  Files: {NUM_FILES:,} ({num_flat:,} flat + {num_nested:,} nested)")
    print(f"  Nesting depth: {NEST_DEPTH} levels")
    print(f"  Change size: {N_CHANGE:,} files ({CHANGE_FRACTION*100:.0f}%)")
    print(f"  Binary: {UNISON}")
    if use_cache:
        print(f"  Cache: enabled (--no-cache to disable)")
    if lowmemory_only:
        print(f"  Mode: lowmemory-only (normal from cache)")
    print(f"{'='*60}\n")

    if not os.path.exists(UNISON):
        print(f"ERROR: Binary not found: {UNISON}")
        print("Run: eval $(opam env) && dune build src/linktext.exe")
        sys.exit(1)

    cached_normal = load_normal_cache() if use_cache else None

    if lowmemory_only and cached_normal is None:
        print("ERROR: --lowmemory-only requires cached normal results, but no cache found.")
        print(f"  Expected: {CACHE_FILE}")
        print("  Run once without --lowmemory-only first.")
        sys.exit(1)

    if os.path.exists(BENCH_DIR):
        shutil.rmtree(BENCH_DIR)
    os.makedirs(BENCH_DIR)

    try:
        # Normal mode: use cache or run fresh
        if cached_normal is not None:
            normal_results = cached_normal
            print(f"\n{'='*60}")
            print(f"  NORMAL MODE (from cache)")
            print(f"{'='*60}")
            for r in normal_results:
                status = "OK" if r["rc"] == 0 else f"FAIL(rc={r['rc']})"
                print(f"  {r['label']:30s}  {r['wall_s']:7.1f}s  {r['rss_mb']:7.1f} MB RSS  [{status}]")
            # Create test files for lowmemory run
            create_test_files()
        else:
            create_test_files()
            normal_results = run_benchmark("NORMAL MODE", [])
            if use_cache:
                save_normal_cache(normal_results)
            # Recreate SRC (phases 4-6 modified it)
            print("\nRecreating test files for lowmemory benchmark...")
            shutil.rmtree(SRC)
            create_test_files()

        # Lowmemory mode
        lowmem_results = run_benchmark("LOWMEMORY MODE", ["-lowmemory"])

        # ---- Summary table ----
        print(f"\n{'='*60}")
        print(f"  SUMMARY ({NUM_FILES:,} files)")
        print(f"{'='*60}")
        print(f"  {'Phase':<25s} {'Normal':>12s} {'Lowmemory':>12s} {'Diff':>10s}")
        print(f"  {'-'*25} {'-'*12} {'-'*12} {'-'*10}")

        for nr, lr in zip(normal_results, lowmem_results):
            label = nr["label"]
            nt, lt = nr["wall_s"], lr["wall_s"]
            diff_t = ((lt - nt) / nt * 100) if nt > 0 else 0
            print(f"  {label:<25s} {nt:9.1f}s   {lt:9.1f}s   {diff_t:+.0f}%")

        print()
        for nr, lr in zip(normal_results, lowmem_results):
            label = nr["label"]
            nm, lm = nr["rss_mb"], lr["rss_mb"]
            diff_m = ((lm - nm) / nm * 100) if nm > 0 else 0
            print(f"  {label:<25s} {nm:7.1f} MB   {lm:7.1f} MB   {diff_m:+.0f}%")

        # ---- Regression check ----
        print(f"\n{'='*60}")
        print(f"  REGRESSION CHECK")
        print(f"{'='*60}")

        n_pass = 0
        failures = []

        # RAM check: lowmemory should use less RAM than normal for every phase
        for nr, lr in zip(normal_results, lowmem_results):
            label = nr["label"]
            nm, lm = nr["rss_mb"], lr["rss_mb"]
            if lm < nm:
                n_pass += 1
                pct = (nm - lm) / nm * 100
                print(f"  PASS  {label:<25s}  {lm:>7.0f} MB < {nm:>7.0f} MB  (-{pct:.0f}%)")
            else:
                failures.append(label)
                pct = (lm - nm) / nm * 100 if nm > 0 else 0
                print(f"  FAIL  {label:<25s}  {lm:>7.0f} MB >= {nm:>7.0f} MB  (+{pct:.0f}%)")

        # Return code checks
        for r in normal_results:
            if r["rc"] != 0:
                failures.append(f"Normal '{r['label']}'")
                print(f"  FAIL  Normal '{r['label']}' exit code {r['rc']}")
        for r in lowmem_results:
            if r["rc"] != 0:
                failures.append(f"Lowmemory '{r['label']}'")
                print(f"  FAIL  Lowmemory '{r['label']}' exit code {r['rc']}")

        print()
        if failures:
            print(f"  Result: {len(failures)} FAILED, {n_pass} passed")
        else:
            print(f"  Result: ALL {n_pass} CHECKS PASSED")

        print(f"{'='*60}")

    finally:
        if os.path.exists(BENCH_DIR):
            shutil.rmtree(BENCH_DIR)
            print("\nCleanup complete.")


if __name__ == "__main__":
    main()
