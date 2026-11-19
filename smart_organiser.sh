#!/bin/bash
# ==========================================================
# smart_organiser.sh - Smart File Organizer (SFO) version 3
#
# USAGE
#   bash smart_organiser.sh --dry-run  DIR    preview, changes nothing
#   bash smart_organiser.sh --organise DIR    really organise DIR
#   bash smart_organiser.sh --undo            reverse the last --organise
#
# OPTIONS
#   --no-rename        keep original file names
#   --recursive        also organise files inside sub-folders
#   --date-folders     put files in Category/YYYY/MM/ by modified date
#   --archive-old      pack stale/large files into a .tar.gz archive
#   --stale-days N     a file is "stale" after N days   (default: config)
#   --large-mb N       a file is "large" from N MB      (default: config)
#   --help             show this text
#
# Settings live in ~/.sfo.conf (created on first run).
# ==========================================================

SFO_HOME="$HOME/.sfo"
CONFIG_FILE="$HOME/.sfo.conf"
JOURNAL="$SFO_HOME/undo/last_run.journal"
REPORT_DIR="$SFO_HOME/reports"
ARCHIVE_DIR="$SFO_HOME/archives"
LOG_FILE="$SFO_HOME/logs/activity.log"
CATEGORIES="Documents Images Videos Audio Archives Code Others Duplicates"

# built-in defaults (config file overrides them, command line overrides both)
STALE_DAYS=90
LARGE_MB=1
RENAME=1
DATE_FOLDERS=0
RECURSIVE=0
ARCHIVE_OLD=0

MODE=""
DIR=""

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

# ---------- MODULE 1: configuration ----------

load_config() {
    mkdir -p "$SFO_HOME"/{undo,reports,archives,logs}

    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << CONF
# Smart File Organizer settings.  Format: KEY=VALUE (no spaces around =)
# Files not modified for this many days are "stale"
STALE_DAYS=90
# Files at least this big (in MB) are "large"
LARGE_MB=1
# 1 = clean file names (lowercase, no spaces), 0 = keep names
RENAME=1
# 1 = use Category/YYYY/MM folders
DATE_FOLDERS=0
# 1 = also scan sub-folders
RECURSIVE=0
# 1 = pack stale/large files into a tar.gz archive
ARCHIVE_OLD=0
CONF
    fi

    # The file is READ line by line (never "sourced"), so it cannot run commands.
    local key val
    while IFS='=' read -r key val || [ -n "$key" ]; do
        key="${key//[[:space:]]/}"
        val="${val%%#*}"; val="${val//[[:space:]]/}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        case "$key" in
            STALE_DAYS|LARGE_MB)
                if [[ "$val" =~ ^[0-9]+$ ]]; then printf -v "$key" '%s' "$val"
                else echo "Warning: bad value for $key in $CONFIG_FILE (using default)"; fi ;;
            RENAME|DATE_FOLDERS|RECURSIVE|ARCHIVE_OLD)
                if [[ "$val" =~ ^[01]$ ]]; then printf -v "$key" '%s' "$val"
                else echo "Warning: bad value for $key in $CONFIG_FILE (using default)"; fi ;;
        esac
    done < "$CONFIG_FILE"
}

# ---------- MODULE 2: helpers (types, names) ----------

ext_of() {
    local n="$1"
    if [[ "$n" == *.* && "$n" != .* ]]; then
        local e="${n##*.}"
        echo "${e,,}"
    fi
}

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

# category proven by CONTENT; empty when content is not conclusive
mime_category() {
    local mime="$1" ext="$2"
    case "$ext" in
        ogg|oga|ogv|webm|m4a|m4v|docx|xlsx|pptx|odt|ods|odp|jar|apk|epub) echo ""; return ;;
    esac
    case "$mime" in
        image/*)         echo "Images" ;;
        video/*)         echo "Videos" ;;
        audio/*)         echo "Audio" ;;
        application/pdf) echo "Documents" ;;
        application/zip|application/gzip|application/x-tar|application/x-7z-compressed|application/x-bzip2|application/x-xz|application/vnd.rar)
                         echo "Archives" ;;
        *) echo "" ;;
    esac
}

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

declare -A PLANNED      # destinations chosen in this run (so dry-run sees collisions too)

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

log_line() { echo "$(date '+%F %T') | $*" >> "$LOG_FILE"; }

# ---------- MODULE 3: the organiser ----------

organise() {
    local mode="$1" dir path base size mime ext mcat ecat exp cat newname dest tag sub
    local f c h wrong stem cleaned mtime age_days stale large depthopt isdup shown
    local total=0 dup_total=0 mis_total=0 ren_total=0 dup_bytes=0
    local stale_total=0 large_total=0 arch_total=0 arch_bytes=0
    local w_before=0 w_after=0 fw
    local now limit_bytes
    local stale_list="" large_list="" dup_list="" mis_list=""
    declare -A count by_size is_dup dup_of first_with_hash
    local -a files=() arch_src=() arch_rel=()

    dir="$(cd -- "$2" 2>/dev/null && pwd)" || { echo "Error: '$2' is not a directory"; exit 1; }
    now=$(date +%s)
    limit_bytes=$((LARGE_MB * 1048576))

    # --- collect files (hidden files and our own category folders are skipped) ---
    depthopt="-maxdepth 1"; [ "$RECURSIVE" -eq 1 ] && depthopt=""
    local -a prune=(-name '.*')
    for c in $CATEGORIES; do prune+=(-o -path "$dir/$c"); done

    # shortest path first: the tidiest copy is kept as the "original" of a duplicate set
    while IFS=$'\t' read -r -d '' _len path; do
        files+=("$path")
    done < <(
        find "$dir" $depthopt -mindepth 1 \( "${prune[@]}" \) -prune -o -type f -print0 |
        while IFS= read -r -d '' p; do printf '%s\t%s\0' "${#p}" "$p"; done |
        sort -z -t $'\t' -k1,1n -k2,2
    )

    # --- pass 1: duplicates (compare size first, SHA-256 only when sizes match) ---
    for f in "${files[@]}"; do
        size=$(stat -c %s -- "$f")
        [ "$size" -eq 0 ] && continue
        by_size[$size]+="$f"$'\n'
    done
    for size in "${!by_size[@]}"; do
        [ "$(printf '%s' "${by_size[$size]}" | grep -c .)" -gt 1 ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            h=$(sha256sum -- "$f" | awk '{print $1}')
            if [ -n "${first_with_hash[$h]}" ]; then
                is_dup["$f"]=1; dup_of["$f"]="${first_with_hash[$h]}"
            else
                first_with_hash[$h]="$f"
            fi
        done < <(printf '%s' "${by_size[$size]}")
    done

    if [ "$mode" = live ]; then
        if [ -s "$JOURNAL" ]; then
            echo "Note: the previous run was never undone; its undo history is being replaced."
        fi
        : > "$JOURNAL"
        log_line "RUN START dir=$dir stale=$STALE_DAYS large=${LARGE_MB}MB archive=$ARCHIVE_OLD"
    fi

    echo "Scanning: $dir  (${#files[@]} files)"
    echo "Settings: stale >= ${STALE_DAYS} days, large >= ${LARGE_MB} MB, rename=$RENAME, recursive=$RECURSIVE, date-folders=$DATE_FOLDERS, archive-old=$ARCHIVE_OLD"
    echo

    # --- pass 2: classify, analyse, fix, move ---
    for f in "${files[@]}"; do
        base=$(basename -- "$f")
        size=$(stat -c %s -- "$f")
        mtime=$(stat -c %Y -- "$f")
        mime=$(file --brief --mime-type -- "$f")
        ext=$(ext_of "$base")
        mcat=$(mime_category "$mime" "$ext")
        ecat=$(ext_category "$ext")
        exp=$(expected_ext "$mime")
        tag=""; fw=0

        if   [ -n "$mcat" ]; then cat="$mcat"
        elif [ -n "$ecat" ]; then cat="$ecat"
        elif [[ "$mime" == text/* ]]; then cat="Documents"
        else cat="Others"
        fi

        newname="$base"

        # misnamed file (content disagrees with the extension)
        if [ -n "$mcat" ]; then
            wrong=0
            [ "$mcat" != "$ecat" ] && wrong=1
            if [ -n "$exp" ] && [ "$ext" != "$exp" ] && ! { [ "$exp" = jpg ] && [ "$ext" = jpeg ]; }; then wrong=1; fi
            if [ "$wrong" -eq 1 ]; then
                mis_total=$((mis_total+1)); fw=$((fw+3))
                tag="$tag [MISNAMED: really $mime]"
                mis_list+="$base (really $mime)"$'\n'
                if [ -n "$exp" ]; then
                    stem="$base"; [ -n "$ext" ] && stem="${base%.*}"
                    newname="$stem.$exp"
                fi
            fi
        fi

        # messy name
        cleaned=$(clean_name "$newname")
        [ "$cleaned" != "$base" ] && { ren_total=$((ren_total+1)); fw=$((fw+1)); }
        [ "$RENAME" -eq 1 ] && newname="$cleaned"

        # stale / large
        age_days=$(( (now - mtime) / 86400 ))
        stale=0; large=0
        if [ "$age_days" -ge "$STALE_DAYS" ]; then
            stale=1; stale_total=$((stale_total+1)); fw=$((fw+2))
            tag="$tag [STALE ${age_days}d]"; stale_list+="$base (${age_days} days old)"$'\n'
        fi
        if [ "$size" -ge "$limit_bytes" ]; then
            large=1; large_total=$((large_total+1)); fw=$((fw+2))
            tag="$tag [LARGE $(human "$size")]"; large_list+="$base ($(human "$size"))"$'\n'
        fi

        # duplicates go to quarantine
        isdup=0
        if [ -n "${is_dup[$f]}" ]; then
            isdup=1; cat="Duplicates"
            tag="$tag [DUPLICATE of $(basename -- "${dup_of[$f]}")]"
            dup_total=$((dup_total+1)); dup_bytes=$((dup_bytes+size)); fw=$((fw+3))
            dup_list+="$base  (copy of $(basename -- "${dup_of[$f]}"))"$'\n'
        fi

        w_before=$((w_before+fw))

        # stale/large (non-duplicate) files can be packed into one tar.gz instead
        if [ "$ARCHIVE_OLD" -eq 1 ] && [ "$isdup" -eq 0 ] && { [ "$stale" -eq 1 ] || [ "$large" -eq 1 ]; }; then
            arch_src+=("$f"); arch_rel+=("${f#/}")
            arch_total=$((arch_total+1)); arch_bytes=$((arch_bytes+size))
            if [ "$mode" = dry ]; then echo "[DRY-RUN] $base -> will be packed into a .tar.gz archive$tag"
            else echo "[QUEUED]  $base -> tar.gz archive$tag"; fi
            total=$((total+1))
            continue
        fi

        # what still needs attention after the run
        if [ "$isdup" -eq 0 ]; then
            [ "$stale" -eq 1 ] && w_after=$((w_after+2))
            [ "$large" -eq 1 ] && w_after=$((w_after+2))
            if [ "$RENAME" -eq 0 ] && [ "$cleaned" != "$base" ]; then w_after=$((w_after+1)); fi
        fi

        sub=""
        if [ "$DATE_FOLDERS" -eq 1 ] && [ "$isdup" -eq 0 ]; then sub="$(date -d "@$mtime" +%Y/%m)/"; fi

        dest=$(unique_dest "$dir/$cat/$sub$newname")
        PLANNED["$dest"]=1
        [ "$(basename -- "$dest")" != "$newname" ] && tag="$tag [NAME EXISTED -> $(basename -- "$dest")]"
        shown="$cat/$sub$(basename -- "$dest")"

        if [ "$mode" = dry ]; then
            echo "[DRY-RUN] $base -> $shown$tag"
        else
            mkdir -p -- "$(dirname -- "$dest")"
            mv -n -- "$f" "$dest"
            printf 'M\t%s\t%s\n' "$f" "$dest" >> "$JOURNAL"
            log_line "MOVED $f -> $dest"
            echo "[MOVED] $base -> $shown$tag"
        fi
        count[$cat]=$(( ${count[$cat]:-0} + 1 ))
        total=$((total+1))
    done

    # --- pack stale/large files into ONE tar.gz, then remove the originals ---
    local arch_file="" arch_size=0 i
    if [ "$arch_total" -gt 0 ] && [ "$mode" = live ]; then
        arch_file="$ARCHIVE_DIR/sfo_archive_$(date +%Y%m%d_%H%M%S).tar.gz"
        if printf '%s\0' "${arch_rel[@]}" | tar --null -czf "$arch_file" -C / -T - 2>/dev/null \
           && tar -tzf "$arch_file" > /dev/null 2>&1; then
            for i in "${!arch_src[@]}"; do
                rm -f -- "${arch_src[$i]}"
                printf 'A\t%s\t%s\t%s\n' "${arch_src[$i]}" "$arch_file" "${arch_rel[$i]}" >> "$JOURNAL"
                log_line "ARCHIVED ${arch_src[$i]} -> $arch_file"
                echo "[ARCHIVED] $(basename -- "${arch_src[$i]}") -> $(basename -- "$arch_file")"
            done
            arch_size=$(stat -c %s -- "$arch_file")
            count[Packed_tar_gz]=$arch_total
        else
            echo "ERROR: could not create the archive, so the originals were NOT removed."
            rm -f -- "$arch_file"; arch_file=""
        fi
    fi

    # --- health score ---
    local denom=$((4 * total)) hs_before=100 hs_after=100
    if [ "$denom" -gt 0 ]; then
        hs_before=$(( 100 - (100 * w_before / denom) )); [ "$hs_before" -lt 0 ] && hs_before=0
        hs_after=$(( 100 - (100 * w_after  / denom) ));  [ "$hs_after"  -lt 0 ] && hs_after=0
    fi
    local word="after"; [ "$mode" = dry ] && word="projected"

    echo
    echo "=============== SUMMARY ==============="
    echo "Files processed   : $total"
    for c in $(printf '%s\n' "${!count[@]}" | sort); do
        printf '  %-16s: %s\n' "${c//_/.}" "${count[$c]}"
    done
    echo "Duplicates        : $dup_total  ($(human $dup_bytes) can be reclaimed)"
    echo "Misnamed (fixed)  : $mis_total"
    echo "Messy names       : $ren_total$( [ "$RENAME" -eq 1 ] && echo ' (cleaned)' )"
    echo "Stale files       : $stale_total  (>= $STALE_DAYS days)"
    echo "Large files       : $large_total  (>= $LARGE_MB MB)"
    if [ "$ARCHIVE_OLD" -eq 1 ]; then
        if [ -n "$arch_file" ]; then
            echo "Archived          : $arch_total file(s), $(human $arch_bytes) -> $(human $arch_size)"
            echo "Archive file      : $arch_file"
        else
            echo "Archived          : $arch_total file(s) $( [ "$mode" = dry ] && echo '(would be packed)' )"
        fi
    elif [ $((stale_total + large_total)) -gt 0 ]; then
        echo "Tip: add --archive-old to pack stale/large files into a tar.gz"
    fi
    echo "Health score      : $hs_before/100  ->  $hs_after/100 ($word)"
    echo "======================================="

    if [ "$mode" = dry ]; then
        echo "(dry run - nothing was changed)"
        return
    fi

    # --- Markdown report ---
    local report="$REPORT_DIR/report_$(date +%Y%m%d_%H%M%S).md"
    {
        echo "# Smart File Organizer Report"
        echo
        echo "- **Date:** $(date)"
        echo "- **Folder:** $dir"
        echo "- **Settings:** stale >= $STALE_DAYS days, large >= $LARGE_MB MB, rename=$RENAME, recursive=$RECURSIVE, date-folders=$DATE_FOLDERS, archive-old=$ARCHIVE_OLD"
        echo
        echo "## Result"
        echo
        echo "| Item | Value |"
        echo "|---|---|"
        echo "| Files processed | $total |"
        echo "| Duplicates | $dup_total ($(human $dup_bytes) reclaimable) |"
        echo "| Misnamed files fixed | $mis_total |"
        echo "| Messy names | $ren_total |"
        echo "| Stale files | $stale_total |"
        echo "| Large files | $large_total |"
        [ -n "$arch_file" ] && echo "| Archived | $arch_total files, $(human $arch_bytes) to $(human $arch_size) |"
        echo "| **Health score** | **$hs_before/100 -> $hs_after/100** |"
        echo
        echo "## Files per category"
        echo
        for c in $(printf '%s\n' "${!count[@]}" | sort); do echo "- ${c//_/.}: ${count[$c]}"; done
        [ -n "$dup_list" ]   && { echo; echo "## Duplicates";  printf '%s' "$dup_list"   | sed 's/^/- /'; }
        [ -n "$mis_list" ]   && { echo; echo "## Misnamed";    printf '%s' "$mis_list"   | sed 's/^/- /'; }
        [ -n "$stale_list" ] && { echo; echo "## Stale files"; printf '%s' "$stale_list" | sed 's/^/- /'; }
        [ -n "$large_list" ] && { echo; echo "## Large files"; printf '%s' "$large_list" | sed 's/^/- /'; }
        echo
        echo "_Health score = 100 - 100 x (3 per duplicate + 3 per misnamed + 2 per stale + 2 per large + 1 per messy name) / (4 x files)._"
    } > "$report"
    echo "Report saved: $report"
    log_line "RUN END processed=$total"
    echo "Run 'bash $0 --undo' to restore everything."
}

# ---------- MODULE 4: undo ----------

undo() {
    [ -s "$JOURNAL" ] || { echo "Nothing to undo."; exit 0; }
    local kind a b c restored=0 failed=0 arch
    local -A used_archives=()

    while IFS=$'\t' read -r kind a b c; do
        case "$kind" in
            M)  # a = original path, b = where it was moved
                if [ -e "$b" ]; then
                    mkdir -p -- "$(dirname -- "$a")"
                    if mv -n -- "$b" "$a"; then
                        echo "[RESTORED] $(basename -- "$a")"; restored=$((restored+1))
                    else
                        echo "[SKIPPED]  $a already exists"; failed=$((failed+1))
                    fi
                    rmdir -p --ignore-fail-on-non-empty -- "$(dirname -- "$b")" 2>/dev/null
                else
                    echo "[MISSING]  $b (cannot restore)"; failed=$((failed+1))
                fi ;;
            A)  # a = original path, b = archive, c = member name inside archive
                used_archives["$b"]=1
                if [ -e "$a" ]; then
                    echo "[SKIPPED]  $a already exists"; failed=$((failed+1))
                elif [ -f "$b" ] && tar -xzf "$b" -C / "$c" 2>/dev/null; then
                    echo "[RESTORED] $(basename -- "$a") (from archive)"; restored=$((restored+1))
                else
                    echo "[MISSING]  $c not found in $b"; failed=$((failed+1))
                fi ;;
        esac
    done < <(tac "$JOURNAL")

    # the archive is only deleted when everything was restored
    if [ "$failed" -eq 0 ]; then
        for arch in "${!used_archives[@]}"; do rm -f -- "$arch"; done
    fi
    : > "$JOURNAL"
    log_line "UNDO restored=$restored failed=$failed"
    echo "Undo complete: $restored file(s) restored$( [ "$failed" -gt 0 ] && echo ", $failed problem(s)" )."
}

# ---------- command line ----------

load_config

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      MODE=dry ;;
        --organise)     MODE=live ;;
        --undo)         MODE=undo ;;
        --no-rename)    RENAME=0 ;;
        --recursive)    RECURSIVE=1 ;;
        --date-folders) DATE_FOLDERS=1 ;;
        --archive-old)  ARCHIVE_OLD=1 ;;
        --stale-days)   shift; [[ "$1" =~ ^[0-9]+$ ]] || { echo "--stale-days needs a number"; exit 1; }; STALE_DAYS="$1" ;;
        --large-mb)     shift; [[ "$1" =~ ^[0-9]+$ ]] || { echo "--large-mb needs a number"; exit 1; }; LARGE_MB="$1" ;;
        --help|-h)      usage 0 ;;
        -*)             echo "Unknown option: $1"; usage ;;
        *)              DIR="$1" ;;
    esac
    shift
done

case "$MODE" in
    dry|live) [ -n "$DIR" ] || usage; organise "$MODE" "$DIR" ;;
    undo)     undo ;;
    *)        usage ;;
esac
