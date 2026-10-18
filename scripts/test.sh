#!/bin/sh
# Runs the unit tests. With full Xcode this is plain `swift test`.
# With only the Command Line Tools, Swift Testing lives in a side folder SwiftPM does not search, so point it there.
set -eu
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
if [ -d "$DEV/Library/Developer/Frameworks/Testing.framework" ] && [ "${DEV%CommandLineTools}" != "$DEV" ]; then
  F="$DEV/Library/Developer/Frameworks"
  L="$DEV/Library/Developer/usr/lib"
  exec swift test \
    -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
