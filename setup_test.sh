#!/bin/bash
# Recreates a messy test folder. Only ever touches ~/sfo_test.
T="$HOME/sfo_test"
rm -rf "$T"
mkdir -p "$T" && cd "$T" || exit 1

echo "meeting notes" > notes.txt
echo "report body"   > report.docx
echo "resume"        > resume.pdf
echo "fake audio"    > song.mp3
echo "fake video"    > clip.mp4
echo 'print("hi")'   > script.py
echo "fake zip"      > archive.zip
echo "no extension, plain text" > README_noext

# Real 1x1 PNG image
PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
echo "$PNG" | base64 -d > photo.png
cp photo.png copy_of_photo.png          # exact duplicate (for later)
echo "$PNG" | base64 -d > disguised.txt # PNG hidden as .txt (for later)

echo "same content" > dup1.txt
echo "same content" > dup2.txt           # duplicate text
echo "holiday" > "My Holiday Pic.jpg"    # name with spaces

echo "old data" > stale.txt
touch -d "120 days ago" stale.txt        # stale file (for later)
head -c 5000000 /dev/zero > big_file.bin # 5 MB large file (for later)

echo "Test folder ready: $T"
ls -la "$T"
