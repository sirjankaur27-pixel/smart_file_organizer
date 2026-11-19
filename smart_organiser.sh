#!/bin/bash
# ==========================================================
# smart_organiser.sh - Smart File Organizer (version 2)
#
# Usage:
#   bash smart_organiser.sh --dry-run  DIR   preview only
#   bash smart_organiser.sh --organise DIR   really organise DIR
#   bash smart_organiser.sh --undo           reverse the last run
# Option:
#   --no-rename   keep the original file names
#
# What it does (top-level files of DIR only):
#   1. Finds exact duplicates (size, then SHA-256) -> Duplicates/
#   2. Reads the real file type, fixes misnamed files
#   3. Sorts files into Documents/Images/Videos/Audio/Archives/Code/Others
#   4. Cleans names (lowercase, no spaces/special characters)
#   5. Journals every move so --undo can restore everything
# ==========================================================

JOURNAL="$HOME/.sfo_journal"
RENAME=1
MODE=""
DIR=""

usage() {
    echo "Usage: bash $0 --dry-run DIR | --organise DIR | --undo   [--no-rename]"
    exit 1
}

# ---------- helpers ----------

# extension of a file name in lowercase ("" if there is none)
ext_of() {
    local n="$1"
    if [[ "$n" == *.* && "$n" != .* ]]; then
        local e="${n##*.}"
        echo "${e,,}"
    fi
}

# category suggested by the file name's extension
ext_category() {
    case "$1" in
        pdf|doc|docx|txt|odt|rtf|md|xls|xlsx|ods|ppt|pptx|csv|log) echo "Documents" ;;
        jpg|jpeg|png|gif|bmp|svg|webp|tiff|ico)                    echo "Images" ;;
        mp4|mkv|avi|mov|webm|flv|wmv|m4v)                          echo "Videos" ;;
        mp3|wav|flac|aac|ogg|m4a|wma)                              echo "Audio" ;;
        zip|tar|gz|rar|7z|bz2|xz)                                  echo "Archives" ;;
        sh|py|c|cpp|h|java|js|html|css|json)                       echo "Code" ;;
        *) echo "" ;;
    esac
}

# category proven by the file's CONTENT (empty when the content is not conclusive)
mime_category() {
    local mime="$1" ext="$2"
    case "$ext" in                      # these can legitimately look like another type
        ogg|oga|ogv|webm|m4a|m4v|docx|xlsx|pptx|odt|ods|odp|jar|apk|epub) echo ""; return ;;
    esac
    case "$mime" in
        image/*)                         echo "Images" ;;
        video/*)                         echo "Videos" ;;
        audio/*)                         echo "Audio" ;;
        application/pdf)                 echo "Documents" ;;
        application/zip|application/gzip|application/x-tar|application/x-7z-compressed|application/x-bzip2|application/x-xz|application/vnd.rar)
                                         echo "Archives" ;;
        *) echo "" ;;
    esac
}

# the correct extension for a few common content types
expected_ext() {
    case "$1" in
        image/png)       echo "png" ;;
        image/jpeg)      echo "jpg" ;;
        image/gif)       echo "gif" ;;
        image/webp)      echo "webp" ;;
        application/pdf) echo "pdf" ;;
        audio/mpeg)      echo "mp3" ;;
        video/mp4)       echo "mp4" ;;
        application/zip) echo "zip" ;;
        *) echo "" ;;
    esac
}

# lowercase, spaces -> _, drop special characters
clean_name() {
    local name="$1" stem ext=""
    if [[ "$name" == *.* && "$name" != .* ]]; then
        stem="${name%.*}"
        ext=".$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
    else
        stem="$name"
    fi
    stem=$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9._-' | tr -s '_')
    [ -z "$stem" ] && stem="file"
    echo "${stem}${ext}"
}

declare -A PLANNED     # destinations already chosen in this run (needed for dry-run)

# never overwrite: add _1, _2 ... until the name is free
unique_dest() {
    local dest="$1" stem ext="" n=1 cand
    if [ ! -e "$dest" ] && [ -z "${PLANNED[$dest]}" ]; then echo "$dest"; return; fi
    if [[ "$(basename -- "$dest")" == *.* ]]; then
        stem="${dest%.*}"; ext=".${dest##*.}"
    else
        stem="$dest"
    fi
    cand="${stem}_${n}${ext}"
    while [ -e "$cand" ] || [ -n "${PLANNED[$cand]}" ]; do
        n=$((n+1)); cand="${stem}_${n}${ext}"
    done
    echo "$cand"
}

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

# ---------- main work ----------

organise() {
    local mode="$1" dir path base size mime ext mcat ecat exp cat newname dest tag
    local f total=0 dup_total=0 misnamed_total=0 renamed_total=0 dup_bytes=0 c
    declare -A count by_size is_dup dup_of
    local -a files=()

    dir="$(cd -- "$2" 2>/dev/null && pwd)" || { echo "Error: '$2' is not a directory"; exit 1; }

    # collect top-level, non-hidden files; shortest name first, so the
    # tidiest name is treated as the "original" when duplicates exist
    while IFS=$'\t' read -r -d '' _len path; do
        files+=("$path")
    done < <(
        find "$dir" -maxdepth 1 -type f -not -name '.*' -print0 |
        while IFS= read -r -d '' p; do printf '%s\t%s\0' "${#p}" "$p"; done |
        sort -z -t $'\t' -k1,1n -k2,2
    )

    # ---- pass 1: duplicate detection (size first, SHA-256 only when sizes match) ----
    for f in "${files[@]}"; do
        size=$(stat -c %s -- "$f")
        [ "$size" -eq 0 ] && continue                 # ignore empty files
        by_size[$size]+="$f"$'\n'
    done
    declare -A first_with_hash
    for size in "${!by_size[@]}"; do
        [ "$(printf '%s' "${by_size[$size]}" | grep -c .)" -gt 1 ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            h=$(sha256sum -- "$f" | awk '{print $1}')
            if [ -n "${first_with_hash[$h]}" ]; then
                is_dup["$f"]=1
                dup_of["$f"]="${first_with_hash[$h]}"
            else
                first_with_hash[$h]="$f"
            fi
        done < <(printf '%s' "${by_size[$size]}")
    done

    [ "$mode" = live ] && : > "$JOURNAL"

    echo "Scanning: $dir  (${#files[@]} files)"
    echo

    # ---- pass 2: classify, fix, rename, move ----
    for f in "${files[@]}"; do
        base=$(basename -- "$f")
        size=$(stat -c %s -- "$f")
        mime=$(file --brief --mime-type -- "$f")
        ext=$(ext_of "$base")
        mcat=$(mime_category "$mime" "$ext")
        ecat=$(ext_category "$ext")
        exp=$(expected_ext "$mime")
        tag=""

        # category: trust the content when it is conclusive, else the extension
        if   [ -n "$mcat" ]; then cat="$mcat"
        elif [ -n "$ecat" ]; then cat="$ecat"
        elif [[ "$mime" == text/* ]]; then cat="Documents"
        else cat="Others"
        fi

        newname="$base"

        # misnamed: content says one thing, name says another
        if [ -n "$mcat" ]; then
            wrong=0
            [ "$mcat" != "$ecat" ] && wrong=1
            if [ -n "$exp" ] && [ "$ext" != "$exp" ] && ! { [ "$exp" = jpg ] && [ "$ext" = jpeg ]; }; then
                wrong=1
            fi
            if [ "$wrong" -eq 1 ]; then
                misnamed_total=$((misnamed_total+1))
                tag="$tag [MISNAMED: really $mime]"
                if [ -n "$exp" ]; then
                    stem="$base"; [ -n "$ext" ] && stem="${base%.*}"
                    newname="$stem.$exp"
                fi
            fi
        fi

        if [ "$RENAME" -eq 1 ]; then
            cleaned=$(clean_name "$newname")
            [ "$cleaned" != "$base" ] && renamed_total=$((renamed_total+1))
            newname="$cleaned"
        fi

        # duplicates go to quarantine, everything else to its category
        if [ -n "${is_dup[$f]}" ]; then
            cat="Duplicates"
            tag="$tag [DUPLICATE of $(basename -- "${dup_of[$f]}")]"
            dup_total=$((dup_total+1))
            dup_bytes=$((dup_bytes+size))
        fi

        dest=$(unique_dest "$dir/$cat/$newname")
        PLANNED["$dest"]=1
        [ "$(basename -- "$dest")" != "$newname" ] && tag="$tag [NAME EXISTED -> $(basename -- "$dest")]"

        if [ "$mode" = dry ]; then
            echo "[DRY-RUN] $base -> $cat/$(basename -- "$dest")$tag"
        else
            mkdir -p -- "$dir/$cat"
            mv -n -- "$f" "$dest"
            printf '%s\t%s\n' "$f" "$dest" >> "$JOURNAL"
            echo "[MOVED] $base -> $cat/$(basename -- "$dest")$tag"
        fi
        count[$cat]=$(( ${count[$cat]:-0} + 1 ))
        total=$((total+1))
    done

    echo
    echo "=============== SUMMARY ==============="
    echo "Files processed   : $total"
    for c in $(printf '%s\n' "${!count[@]}" | sort); do
        printf '  %-12s: %s\n' "$c" "${count[$c]}"
    done
    echo "Duplicates found  : $dup_total  ($(human $dup_bytes) can be reclaimed)"
    echo "Misnamed fixed    : $misnamed_total"
    [ "$RENAME" -eq 1 ] && echo "Files renamed     : $renamed_total"
    echo "======================================="
    [ "$mode" = dry ] && echo "(dry run - nothing was changed)"
    [ "$mode" = live ] && echo "Run 'bash $0 --undo' to restore everything."
}

undo() {
    [ -s "$JOURNAL" ] || { echo "Nothing to undo."; exit 0; }
    local restored=0
    while IFS=$'\t' read -r src dest; do
        if [ -e "$dest" ]; then
            mkdir -p -- "$(dirname -- "$src")"
            if mv -n -- "$dest" "$src"; then
                echo "[RESTORED] $(basename -- "$src")"
                restored=$((restored+1))
            fi
            rmdir --ignore-fail-on-non-empty -- "$(dirname -- "$dest")" 2>/dev/null
        else
            echo "[MISSING] $dest (cannot restore)"
        fi
    done < <(tac "$JOURNAL")
    : > "$JOURNAL"
    echo "Undo complete: $restored file(s) restored."
}

# ---------- read the command line ----------
for arg in "$@"; do
    case "$arg" in
        --dry-run)   MODE=dry ;;
        --organise)  MODE=live ;;
        --undo)      MODE=undo ;;
        --no-rename) RENAME=0 ;;
        -*)          usage ;;
        *)           DIR="$arg" ;;
    esac
done

case "$MODE" in
    dry|live) [ -n "$DIR" ] || usage; organise "$MODE" "$DIR" ;;
    undo)     undo ;;
    *)        usage ;;
esac