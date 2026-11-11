#!/bin/bash
# Run on Ubuntu. Every required name in packages/apt.txt must be visible to
# apt. A line that starts with `?` is optional and may be absent.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
file=$root/packages/apt.txt
missing=()

while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n $line ]] || continue
    [[ $line == '?'* ]] && continue
    hit=$(apt-cache policy "$line" 2>/dev/null | awk '/Candidate:/ { print $2; exit }')
    if [[ -z $hit || $hit == '(none)' ]]; then
        missing+=("$line")
    fi
done < "$file"

if (( ${#missing[@]} )); then
    printf 'missing: %s\n' "${missing[*]}" >&2
    echo "packages/apt.txt names a package this Ubuntu does not have" >&2
    exit 1
fi

echo "apt manifest ok"
