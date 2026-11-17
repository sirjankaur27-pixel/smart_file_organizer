#!/bin/bash
# smart_organiser.sh - Smart File Organizer (starter version)
# Usage: bash smart_organiser.sh --dry-run DIR | --organise DIR | --undo

JOURNAL="$HOME/.sfo_journal"

usage() {
    echo "Usage: $0 --dry-run DIR | --organise DIR | --undo"
    exit 1
}

# Decide the category: extension first, then file's real content type
category_of() {
    local name ext mime
    name=$(basename -- "$1")
    ext="${name##*.}"; ext="${ext,,}"
    [[ "$name" == *.* ]] || ext=""

    case "$ext" in
        pdf|doc|docx|txt|odt|md|xls|xlsx|ppt|pptx|csv) echo "Documents"; return ;;
        jpg|jpeg|png|gif|bmp|svg|webp)                 echo "Images";    return ;;
        mp4|mkv|avi|mov|webm)                          echo "Videos";    return ;;
        mp3|wav|flac|aac|ogg)                          echo "Audio";     return ;;
        zip|tar|gz|rar|7z|bz2)                         echo "Archives";  return ;;
        sh|py|c|cpp|java|js|html|css)                  echo "Code";      return ;;
    esac

    mime=$(file --brief --mime-type -- "$1")
    case "$mime" in
        image/*)            echo "Images" ;;
        video/*)            echo "Videos" ;;
        audio/*)            echo "Audio" ;;
        text/x-*|text/html) echo "Code" ;;
        text/*|application/pdf) echo "Documents" ;;
        application/zip|application/gzip|application/x-tar) echo "Archives" ;;
        *)                  echo "Others" ;;
    esac
}

# Never overwrite: add _1, _2 ... if the destination already exists
unique_dest() {
    local dest="$1" stem ext n=1 candidate
    if [ ! -e "$dest" ]; then echo "$dest"; return; fi
    if [[ "$(basename -- "$dest")" == *.* ]]; then
        stem="${dest%.*}"; ext=".${dest##*.}"
    else
        stem="$dest"; ext=""
    fi
    candidate="${stem}_${n}${ext}"
    while [ -e "$candidate" ]; do
        n=$((n+1)); candidate="${stem}_${n}${ext}"
    done
    echo "$candidate"
}

organise() {
    local mode="$1" dir="${2%/}" total=0 f category dest c
    declare -A count

    [ -d "$dir" ] || { echo "Error: '$dir' is not a directory"; exit 1; }
    [ "$mode" = live ] && : > "$JOURNAL"      # new journal for this run

    while IFS= read -r -d '' f; do
        category=$(category_of "$f")
        dest=$(unique_dest "$dir/$category/$(basename -- "$f")")

        if [ "$mode" = dry ]; then
            echo "[DRY-RUN] would move: $(basename -- "$f") -> $category/"
        else
            mkdir -p "$dir/$category"
            mv -- "$f" "$dest"
            printf '%s\t%s\n' "$f" "$dest" >> "$JOURNAL"   # record for undo
            echo "[MOVED] $(basename -- "$f") -> $category/"
        fi
        count[$category]=$(( ${count[$category]:-0} + 1 ))
        total=$((total+1))
    done < <(find "$dir" -maxdepth 1 -type f -not -name '.*' -print0)

    echo "=========== SUMMARY ==========="
    echo "Files processed: $total"
    for c in "${!count[@]}"; do echo "  $c: ${count[$c]}"; done
    [ "$mode" = dry ] && echo "(dry run - nothing was changed)"
}

undo() {
    [ -s "$JOURNAL" ] || { echo "Nothing to undo."; exit 0; }
    tac "$JOURNAL" | while IFS=$'\t' read -r src dest; do
        if [ -e "$dest" ]; then
            mkdir -p "$(dirname -- "$src")"
            mv -n -- "$dest" "$src" && echo "[RESTORED] $src"
            rmdir --ignore-fail-on-non-empty "$(dirname -- "$dest")" 2>/dev/null
        else
            echo "[MISSING] $dest (cannot restore)"
        fi
    done
    : > "$JOURNAL"
}

case "$1" in
    --dry-run)  [ -n "$2" ] || usage; organise dry  "$2" ;;
    --organise) [ -n "$2" ] || usage; organise live "$2" ;;
    --undo)     undo ;;
    *)          usage ;;
esac
