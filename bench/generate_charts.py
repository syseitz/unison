#!/usr/bin/env python3
"""Generate comparison charts from benchmark JSON results.

Reads JSON files produced by bench_compare.py --json-output and creates
charts showing memory and time scaling across different data sizes.

Usage:
  python3 bench/generate_charts.py results_1000.json results_5000.json ... -o charts/
"""
import argparse
import json
import os
import sys

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
except ImportError:
    print("ERROR: matplotlib is required. Install with: pip install matplotlib")
    sys.exit(1)


def load_results(paths: list[str]) -> list[dict]:
    results = []
    for p in sorted(paths):
        with open(p) as f:
            data = json.load(f)
        results.append(data)
    results.sort(key=lambda d: d["num_files"])
    return results


PHASE_LABELS = {
    "Initial sync": "Initial sync",
    "SS1 (nothing changed)": "Steady state",
    "SS2 (nothing changed)": "Steady state 2",
    "Sync after modify": "After modify",
    "Sync after add": "After add",
    "Sync after delete": "After delete",
    "Re-initial sync": "Re-initial sync",
}

# Phases to show in detail charts (skip SS2 as it's redundant with SS1)
DETAIL_PHASES = [
    "Initial sync",
    "SS1 (nothing changed)",
    "Sync after modify",
    "Sync after add",
    "Sync after delete",
    "Re-initial sync",
]


def plot_overview(results: list[dict], out_dir: str) -> str:
    """Create overview chart: peak RSS across all sizes for initial sync + SS1."""
    sizes = [r["num_files"] for r in results]

    fig, (ax_mem, ax_time) = plt.subplots(1, 2, figsize=(12, 5))
    fig.suptitle("Unison: Normal vs Low-Memory Mode", fontsize=14, fontweight="bold")

    # Memory chart — initial sync
    normal_mem = [r["normal"][0]["rss_mb"] for r in results]
    lowmem_mem = [r["lowmemory"][0]["rss_mb"] for r in results]
    ax_mem.plot(sizes, normal_mem, "o-", color="#e74c3c", label="Normal", linewidth=2)
    ax_mem.plot(sizes, lowmem_mem, "s-", color="#2ecc71", label="Low-memory", linewidth=2)
    ax_mem.set_xlabel("Number of files")
    ax_mem.set_ylabel("Peak RSS (MB)")
    ax_mem.set_title("Memory Usage (Initial Sync)")
    ax_mem.legend()
    ax_mem.grid(True, alpha=0.3)
    ax_mem.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x/1000:.0f}k" if x >= 1000 else f"{x:.0f}"))

    # Time chart — initial sync
    normal_time = [r["normal"][0]["wall_s"] for r in results]
    lowmem_time = [r["lowmemory"][0]["wall_s"] for r in results]
    ax_time.plot(sizes, normal_time, "o-", color="#e74c3c", label="Normal", linewidth=2)
    ax_time.plot(sizes, lowmem_time, "s-", color="#2ecc71", label="Low-memory", linewidth=2)
    ax_time.set_xlabel("Number of files")
    ax_time.set_ylabel("Time (seconds)")
    ax_time.set_title("Sync Time (Initial Sync)")
    ax_time.legend()
    ax_time.grid(True, alpha=0.3)
    ax_time.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x/1000:.0f}k" if x >= 1000 else f"{x:.0f}"))

    plt.tight_layout()
    path = os.path.join(out_dir, "overview.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  Saved {path}")
    return path


def plot_phases(results: list[dict], out_dir: str) -> list[str]:
    """Create detailed per-phase charts."""
    sizes = [r["num_files"] for r in results]
    paths = []

    n_phases = len(DETAIL_PHASES)
    fig, axes = plt.subplots(2, n_phases, figsize=(4 * n_phases, 8))
    fig.suptitle("Unison Benchmark: All Phases", fontsize=14, fontweight="bold")

    for col, phase_key in enumerate(DETAIL_PHASES):
        phase_idx = next(
            i for i, p in enumerate(results[0]["normal"])
            if p["label"] == phase_key
        )
        short = PHASE_LABELS.get(phase_key, phase_key)

        # Memory row
        ax = axes[0, col]
        normal_mem = [r["normal"][phase_idx]["rss_mb"] for r in results]
        lowmem_mem = [r["lowmemory"][phase_idx]["rss_mb"] for r in results]
        ax.plot(sizes, normal_mem, "o-", color="#e74c3c", label="Normal", linewidth=1.5)
        ax.plot(sizes, lowmem_mem, "s-", color="#2ecc71", label="Low-mem", linewidth=1.5)
        ax.set_title(short, fontsize=10)
        if col == 0:
            ax.set_ylabel("Peak RSS (MB)")
        ax.grid(True, alpha=0.3)
        ax.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x/1000:.0f}k" if x >= 1000 else f"{x:.0f}"))
        if col == 0:
            ax.legend(fontsize=8)

        # Time row
        ax = axes[1, col]
        normal_time = [r["normal"][phase_idx]["wall_s"] for r in results]
        lowmem_time = [r["lowmemory"][phase_idx]["wall_s"] for r in results]
        ax.plot(sizes, normal_time, "o-", color="#e74c3c", label="Normal", linewidth=1.5)
        ax.plot(sizes, lowmem_time, "s-", color="#2ecc71", label="Low-mem", linewidth=1.5)
        if col == 0:
            ax.set_ylabel("Time (seconds)")
        ax.set_xlabel("Files")
        ax.grid(True, alpha=0.3)
        ax.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x/1000:.0f}k" if x >= 1000 else f"{x:.0f}"))

    plt.tight_layout()
    path = os.path.join(out_dir, "phases.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  Saved {path}")
    paths.append(path)
    return paths


def plot_memory_savings(results: list[dict], out_dir: str) -> str:
    """Bar chart showing memory savings percentage per phase."""
    sizes = [r["num_files"] for r in results]
    if len(sizes) < 2:
        return ""

    # Use the largest size for the bar chart
    r = results[-1]
    phases = []
    savings = []
    for nr, lr in zip(r["normal"], r["lowmemory"]):
        if nr["rss_mb"] > 0:
            pct = (nr["rss_mb"] - lr["rss_mb"]) / nr["rss_mb"] * 100
            short = PHASE_LABELS.get(nr["label"], nr["label"])
            phases.append(short)
            savings.append(pct)

    fig, ax = plt.subplots(figsize=(10, 5))
    colors = ["#2ecc71" if s > 0 else "#e74c3c" for s in savings]
    bars = ax.bar(phases, savings, color=colors, edgecolor="white", linewidth=0.5)
    ax.set_ylabel("Memory Savings (%)")
    ax.set_title(f"Memory Savings: Low-Memory vs Normal ({r['num_files']:,} files)")
    ax.axhline(y=0, color="black", linewidth=0.5)
    ax.grid(True, alpha=0.3, axis="y")

    for bar, val in zip(bars, savings):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 1,
                f"{val:.0f}%", ha="center", va="bottom", fontsize=9)

    plt.xticks(rotation=30, ha="right")
    plt.tight_layout()
    path = os.path.join(out_dir, "memory_savings.png")
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  Saved {path}")
    return path


def generate_summary_md(results: list[dict], chart_files: list[str], out_dir: str) -> str:
    """Generate a markdown summary with embedded chart references."""
    md = ["# Benchmark Results: Normal vs Low-Memory Mode\n"]
    md.append(f"Generated from {len(results)} data size(s): "
              + ", ".join(f"{r['num_files']:,}" for r in results) + " files\n")

    # Summary table for largest size
    r = results[-1]
    md.append(f"\n## Summary ({r['num_files']:,} files)\n")
    md.append("| Phase | Normal (MB) | Low-mem (MB) | Savings | Normal (s) | Low-mem (s) | Slowdown |")
    md.append("|-------|------------|-------------|---------|-----------|------------|----------|")
    for nr, lr in zip(r["normal"], r["lowmemory"]):
        mem_save = (nr["rss_mb"] - lr["rss_mb"]) / nr["rss_mb"] * 100 if nr["rss_mb"] > 0 else 0
        time_diff = (lr["wall_s"] - nr["wall_s"]) / nr["wall_s"] * 100 if nr["wall_s"] > 0 else 0
        short = PHASE_LABELS.get(nr["label"], nr["label"])
        md.append(f"| {short} | {nr['rss_mb']:.1f} | {lr['rss_mb']:.1f} | {mem_save:+.0f}% "
                  f"| {nr['wall_s']:.1f} | {lr['wall_s']:.1f} | {time_diff:+.0f}% |")

    md.append("\n## Charts\n")
    for cf in chart_files:
        name = os.path.basename(cf)
        md.append(f"![{name}]({name})\n")

    path = os.path.join(out_dir, "RESULTS.md")
    with open(path, "w") as f:
        f.write("\n".join(md))
    print(f"  Saved {path}")
    return path


def main():
    parser = argparse.ArgumentParser(description="Generate benchmark comparison charts")
    parser.add_argument("json_files", nargs="+", help="JSON result files from bench_compare.py")
    parser.add_argument("-o", "--output-dir", default="bench_results",
                        help="Output directory for charts (default: bench_results)")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    print(f"Loading {len(args.json_files)} result file(s)...")
    results = load_results(args.json_files)
    for r in results:
        print(f"  {r['num_files']:>8,} files  ({r.get('platform', '?')}, {r.get('timestamp', '?')})")

    print("\nGenerating charts...")
    chart_files = []
    chart_files.append(plot_overview(results, args.output_dir))
    chart_files.extend(plot_phases(results, args.output_dir))
    chart_files.append(plot_memory_savings(results, args.output_dir))

    generate_summary_md(results, chart_files, args.output_dir)
    print("\nDone!")


if __name__ == "__main__":
    main()
