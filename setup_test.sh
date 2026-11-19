#!/bin/bash
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
PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
echo "$PNG" | base64 -d > photo.png
cp photo.png copy_of_photo.png
echo "$PNG" | base64 -d > disguised.txt; printf "x" >> disguised.txt
echo "same content" > dup1.txt
echo "same content" > dup2.txt
echo "holiday" > "My Holiday Pic.jpg"
echo "old data" > stale.txt
touch -d "120 days ago" stale.txt
head -c 5000000 /dev/zero > big_file.bin
mkdir -p subdir
echo "nested notes" > subdir/nested_notes.txt
echo "Test folder ready: $T"
