#!/usr/bin/env zsh
# Prints the path to one of Sparkle's command-line tools (sign_update, generate_appcast, …)
# from the Sparkle package Xcode resolved for this project, resolving it first if needed.
#
# Usage: scripts/sparkle-tool.sh sign_update

set -euo pipefail
name="$1"
REPO_ROOT="${0:A:h:h}"
find_tool() {
    ls -d ~/Library/Developer/Xcode/DerivedData/Changeover-*/SourcePackages/artifacts/sparkle/Sparkle/bin/"$name" 2>/dev/null | head -1
}
tool="$(find_tool)"
if [[ -z "$tool" ]]; then
    xcodebuild -resolvePackageDependencies -project "$REPO_ROOT/Changeover.xcodeproj" -scheme Changeover >/dev/null
    tool="$(find_tool)"
fi
[[ -x "$tool" ]] || { print -u2 "error: Sparkle's $name not found"; exit 1; }
print -r -- "$tool"
