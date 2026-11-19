# Smart File Organizer (SFO)

A Bash tool that cleans a messy folder: it sorts files by their REAL type,
finds duplicates, fixes misnamed files, cleans names, flags stale/large files,
packs them into a tar.gz, writes a report with a health score, and can UNDO
everything.

## Quick start (Linux / WSL)
    bash setup_test.sh                       # make a messy test folder (~/sfo_test)
    bash smart_organiser.sh --dry-run  ~/sfo_test
    bash smart_organiser.sh --organise ~/sfo_test
    bash smart_organiser.sh --undo
    bash demo.sh                             # guided demo

## Options
| Option | Meaning |
|---|---|
| --dry-run DIR | preview only, nothing is changed |
| --organise DIR | really organise DIR |
| --undo | reverse the last --organise |
| --no-rename | keep original names |
| --recursive | include sub-folders |
| --date-folders | Category/YYYY/MM folders |
| --archive-old | pack stale/large files into ~/.sfo/archives/*.tar.gz |
| --stale-days N / --large-mb N | override thresholds |

## Settings
`~/.sfo.conf` is created on first run (STALE_DAYS, LARGE_MB, RENAME,
DATE_FOLDERS, RECURSIVE, ARCHIVE_OLD). It is read line by line, never
executed. Command-line options override it.

## Where things are stored (~/.sfo/)
- undo/last_run.journal : record of every move (used by --undo)
- reports/              : Markdown reports
- archives/             : tar.gz archives
- logs/activity.log     : activity log

## How it works
1. Duplicates: compare size first, then SHA-256 (sha256sum).
2. Type detection: `file --mime-type` reads file content, not just the name.
3. Misnamed: content disagrees with the extension -> corrected (disguised.txt -> .png).
4. Stale/Large: age (stat mtime) and size thresholds.
5. Archive: tar -czf, verified with tar -tzf before originals are removed.
6. Undo: journal read backwards; archived files are extracted back.
7. Health score = 100 - 100 x (3/duplicate + 3/misnamed + 2/stale + 2/large
   + 1/messy name) / (4 x files).

## Unix tools used
bash, find, stat, file, sha256sum, awk, sed, tr, sort, tar, gzip, mv, mkdir,
rmdir, date, numfmt, tac, grep.

## Limitations
- Only the LAST run can be undone.
- Duplicates are detected by exact content only.
- Uses GNU options (stat -c, date -d), so it targets Linux.
- In --recursive mode, folders named like a category (e.g. Documents) are skipped.
