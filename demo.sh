#!/bin/bash
# demo.sh - guided presentation of the Smart File Organizer
# Run:  bash demo.sh      (press Enter to move to the next step)
cd "$(dirname "$0")" || exit 1
T="$HOME/sfo_test"
step() { echo; echo "================ $1 ================"; read -r -p "Press Enter... " _; }

step "1. Create a messy test folder"
bash setup_test.sh > /dev/null
ls -1 "$T"

step "2. DRY RUN: preview, nothing is changed"
bash smart_organiser.sh --dry-run "$T" --recursive --archive-old
echo; echo "Files in folder (unchanged):"; ls -1 "$T" | wc -l

step "3. REAL RUN: organise, pack old/large files, write report"
bash smart_organiser.sh --organise "$T" --recursive --archive-old
echo; ls -R "$T" | head -50

step "4. Show the saved report and archive"
cat "$(ls -t "$HOME"/.sfo/reports/*.md | head -1)"
ls -lh "$HOME"/.sfo/archives/

step "5. UNDO: restore everything"
bash smart_organiser.sh --undo
echo; ls -1 "$T"
echo; echo "Demo finished."
