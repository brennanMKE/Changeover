#!/usr/bin/env bash
# capture-disc.sh — capture a makemkvcon robot-mode scan of the disc currently
# in the drive on the rip host, save it as a test fixture, and print a summary.
#
# Usage:  Tools/capture-disc.sh [slug]
#         slug defaults to a kebab-cased form of the mounted volume name.
#
# Produces, under ChangeoverTests/Fixtures/makemkvcon/:
#   <slug>-min0.txt      scan with --minlength=0   (every title)
#   <slug>-mindefault.txt scan with MakeMKV's default minimum title length
#
# Both are captured because MakeMKV assigns title indices AFTER applying the
# minimum-length filter, so the two scans can number the same title differently.
# A rip issued against an index from the wrong scan rips the wrong title and
# still exits 0. Diffing the two is the only way to see it.

set -euo pipefail

HOST="${CHANGEOVER_HOST:-joe}"
REMOTE_PATH="${CHANGEOVER_REMOTE_PATH:-/opt/homebrew/bin}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/ChangeoverTests/Fixtures/makemkvcon"

ssh_host() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

# --- identify the disc -------------------------------------------------------
VOLUME="$(ssh_host 'ls /Volumes' | grep -vxE 'Macintosh HD|Media|Batty|makemkv_v[0-9.]+' | head -1)"
if [[ -z "$VOLUME" ]]; then
  echo "No disc volume mounted on $HOST." >&2
  exit 1
fi

# BSD sed has no \+ in basic regex — use -E. Apostrophes and other punctuation in
# volume names (THE_GIRL_IN_THE_SPIDER'S_WEB) must not survive into a shell word.
SLUG="${1:-$(echo "$VOLUME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')}"
echo "disc:   $VOLUME"
echo "slug:   $SLUG"
mkdir -p "$FIXTURES"

# --- scan twice --------------------------------------------------------------
ssh_host "
  export PATH=$REMOTE_PATH:\$PATH
  d=~/changeover-fixtures/$SLUG
  mkdir -p \"\$d\" && cd \"\$d\"
  makemkvcon -r --cache=1 --minlength=0 info disc:0 > info-min0.txt 2>err-min0.txt
  echo \"min0:       exit=\$? lines=\$(wc -l < info-min0.txt)\"
  makemkvcon -r --cache=1              info disc:0 > info-mindefault.txt 2>err-mindefault.txt
  echo \"mindefault: exit=\$? lines=\$(wc -l < info-mindefault.txt)\"
"

scp -q -o BatchMode=yes \
  "$HOST:~/changeover-fixtures/$SLUG/info-min0.txt"        "$FIXTURES/$SLUG-min0.txt"
scp -q -o BatchMode=yes \
  "$HOST:~/changeover-fixtures/$SLUG/info-mindefault.txt"  "$FIXTURES/$SLUG-mindefault.txt"

# --- summarize ---------------------------------------------------------------
F="$FIXTURES/$SLUG-min0.txt"
attr() { grep "^TINFO:$1,$2," "$F" 2>/dev/null | sed 's/.*,"\(.*\)"$/\1/' | head -1; }

echo
echo "=== $(grep '^TCOUNT:' "$F") (at --minlength=0) ==="
printf "%-4s %-5s %-10s %-9s %s\n" idx chap duration size output
for t in $(grep -o '^TINFO:[0-9]*' "$F" | cut -d: -f2 | sort -un); do
  printf "%-4s %-5s %-10s %-9s %s\n" \
    "$t" "$(attr "$t" 8)" "$(attr "$t" 9)" "$(attr "$t" 10)" "$(attr "$t" 27)"
done

echo
echo "=== index stability: min0 vs default ==="
diff <(grep -c '^TINFO:[0-9]*,27,' "$F" || true) \
     <(grep -c '^TINFO:[0-9]*,27,' "$FIXTURES/$SLUG-mindefault.txt" || true) >/dev/null \
  && echo "same title count" \
  || echo "TITLE COUNT DIFFERS — check whether indices shifted"
paste -d'|' \
  <(grep '^TINFO:[0-9]*,27,' "$F" | sed 's/^TINFO:\([0-9]*\),27,.*,"\(.*\)"$/\1 \2/') \
  <(grep '^TINFO:[0-9]*,27,' "$FIXTURES/$SLUG-mindefault.txt" | sed 's/^TINFO:\([0-9]*\),27,.*,"\(.*\)"$/\1 \2/') \
  | column -t -s'|' | head -20

echo
echo "=== audio / subtitle streams on the longest title ==="
LONGEST="$(for t in $(grep -o '^TINFO:[0-9]*' "$F" | cut -d: -f2 | sort -un); do
             echo "$(grep "^TINFO:$t,11," "$F" | sed 's/.*,"\(.*\)"$/\1/') $t"; done | sort -rn | head -1 | cut -d' ' -f2)"
echo "(title $LONGEST)"
for s in $(grep -o "^SINFO:$LONGEST,[0-9]*" "$F" | cut -d, -f2 | sort -un); do
  sattr() { grep "^SINFO:$LONGEST,$s,$1," "$F" 2>/dev/null | sed 's/.*,"\(.*\)"$/\1/' | head -1; }
  printf "  s%-3s %-10s %-9s %-5s %-26s %s\n" \
    "$s" "$(sattr 1)" "$(sattr 5)" "$(sattr 3)" "$(sattr 30)" "$(sattr 13)"
done

echo
echo "=== MSG codes (exit status decides success; these only explain it) ==="
grep '^MSG:' "$F" | cut -d, -f1 | sort | uniq -c | sort -rn | head
echo
echo "fixtures: $FIXTURES/$SLUG-{min0,mindefault}.txt"
