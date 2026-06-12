#!/bin/zsh
# fw_cache_list.sh — list cached firmware under ipsws/ with sizes.
#
# Read-only inventory of the firmware cache. For each downloaded IPSW it shows
# the archive size, the extracted *_Restore directory size (needed only during
# the create/restore pipeline, not for booting an existing VM), and the combined
# footprint — so you can see what a previous/failed run left behind and decide
# what to reclaim. Nothing is deleted.
#
# Run: make fw_cache_list

set -euo pipefail

SCRIPT_DIR="${0:a:h}"
IPSW_DIR="${IPSW_DIR:-${SCRIPT_DIR}/../ipsws}"
IPSW_DIR="${IPSW_DIR:A}"   # normalize (collapse ../, absolute) for clean output

if [[ ! -d "$IPSW_DIR" ]]; then
    echo "  (no firmware cache — $IPSW_DIR does not exist)"
    exit 0
fi

# Human-readable size of a path.
hsize() { du -sh "$1" 2>/dev/null | cut -f1; }

echo "Cached firmware in $IPSW_DIR:"
echo ""

# Each .ipsw, paired with its extracted dir (if the pipeline unpacked it).
for ipsw in "$IPSW_DIR"/*.ipsw(N); do
    base="${ipsw:t:r}"                 # filename without the .ipsw extension
    dir="$IPSW_DIR/$base"
    # cloudOS bases are hash-named; iPhone restores end in _Restore.
    case "$base" in
        *_Restore) label="iPhone restore" ;;
        *)         label="cloudOS base" ;;
    esac
    isize=$(hsize "$ipsw")
    if [[ -d "$dir" ]]; then
        dsize=$(hsize "$dir")
        tsize=$(du -sch "$ipsw" "$dir" 2>/dev/null | tail -1 | cut -f1)
    else
        dsize="(none)"
        tsize="$isize"
    fi
    echo "  $base  [$label]"
    echo "      ipsw $isize · extracted $dsize · total $tsize"
done

# Extracted dirs with no matching .ipsw — leftovers from a partial cleanup.
for dir in "$IPSW_DIR"/*(/N); do
    [[ -e "$dir.ipsw" ]] && continue
    echo "  ${dir:t}  [extracted only — no .ipsw]"
    echo "      extracted $(hsize "$dir")"
done

echo ""
echo "  Total $IPSW_DIR: $(hsize "$IPSW_DIR")"
echo ""
echo "  Reclaim one (keeps the shared cloudOS base):"
echo "      rm -rf \"$IPSW_DIR/<name>\" \"$IPSW_DIR/<name>.ipsw\""
