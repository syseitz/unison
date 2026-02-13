#!/bin/bash
# Quick SS1 benchmark for lowmemory mode
# Usage: ./bench/bench_ss1.sh [NUM_FILES]
set -e

NUM_FILES=${1:-5000}
UNISON="$(pwd)/_build/default/src/linktext.exe"
BENCH_DIR="/tmp/unison_bench_$$"
SRC="$BENCH_DIR/src"
DST="$BENCH_DIR/dst"
PROFILE_DIR="$BENCH_DIR/unison_profile"

echo "=== Unison SS1 Benchmark ==="
echo "Files: $NUM_FILES"
echo "Binary: $UNISON"
echo ""

cleanup() {
    rm -rf "$BENCH_DIR"
}
trap cleanup EXIT

# Create test data
echo "Creating $NUM_FILES test files..."
mkdir -p "$SRC" "$DST" "$PROFILE_DIR"
for i in $(seq 1 $NUM_FILES); do
    dir_num=$((i / 100))
    dir="$SRC/dir_$(printf '%03d' $dir_num)"
    mkdir -p "$dir"
    echo "content_$i" > "$dir/file_$(printf '%05d' $i).txt"
done
echo "Created $(find "$SRC" -type f | wc -l) files in $(find "$SRC" -type d | wc -l) dirs"

COMMON_ARGS="-batch -auto -silent -times -fastcheck true -confirmbigdel=false -logfile /dev/null -contactquietly"

run_sync() {
    local label="$1"
    shift
    echo -n "$label: "
    /usr/bin/time -l "$UNISON" "$SRC" "$DST" \
        -servercmd "$UNISON" \
        $COMMON_ARGS "$@" \
        -dumbtty 2>&1 | {
        while IFS= read -r line; do
            # Extract timing and memory from time output
            case "$line" in
                *"real"*) echo -n "time=${line##*real} " ;;
                *"maximum resident set size"*) echo -n "ram=$(( $(echo "$line" | tr -dc '0-9') / 1024 / 1024 ))MB " ;;
            esac
        done
        echo ""
    }
}

echo ""
echo "--- Normal Mode ---"
rm -rf "$HOME/.unison/ar"* "$HOME/.unison/fp"*

echo "Initial sync (normal):"
/usr/bin/time -l "$UNISON" "$SRC" "$DST" \
    -servercmd "$UNISON" $COMMON_ARGS -dumbtty 2>&1 | tail -5

echo ""
echo "SS1 (normal):"
/usr/bin/time -l "$UNISON" "$SRC" "$DST" \
    -servercmd "$UNISON" $COMMON_ARGS -dumbtty 2>&1 | tail -5

echo ""
echo "SS2 (normal):"
/usr/bin/time -l "$UNISON" "$SRC" "$DST" \
    -servercmd "$UNISON" $COMMON_ARGS -dumbtty 2>&1 | tail -5

# Reset for lowmemory test
rm -rf "$DST"/* "$HOME/.unison/ar"* "$HOME/.unison/fp"* "$HOME/.unison/sq"*
# Re-create DST
mkdir -p "$DST"

echo ""
echo "--- Low-Memory Mode ---"

echo "Initial sync (lowmemory):"
/usr/bin/time -l "$UNISON" "$SRC" "$DST" \
    -servercmd "$UNISON" $COMMON_ARGS -lowmemory -dumbtty 2>&1 | tail -5

echo ""
echo "SS1 (lowmemory):"
/usr/bin/time -l "$UNISON" "$SRC" "$DST" \
    -servercmd "$UNISON" $COMMON_ARGS -lowmemory -dumbtty 2>&1 | tail -5

echo ""
echo "SS2 (lowmemory):"
/usr/bin/time -l "$UNISON" "$SRC" "$DST" \
    -servercmd "$UNISON" $COMMON_ARGS -lowmemory -dumbtty 2>&1 | tail -5

echo ""
echo "=== Done ==="
