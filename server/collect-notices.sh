#!/bin/sh
# Run from server/ with the same GOOS, GOARCH and CGO_ENABLED as the binary.
set -eu
export LC_ALL=C
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
goroot=$(go env GOROOT)
go_license="$goroot/LICENSE"
# Homebrew places the Go license alongside libexec.
if [ ! -f "$go_license" ]; then go_license="$goroot/../LICENSE"; fi
printf 'Go runtime and standard library (%s)\n\n' "$(go env GOVERSION)"
cat "$go_license" "$goroot/PATENTS"

go list -deps -f '{{with .Module}}{{if not .Main}}{{.Path}}@{{.Version}} {{.Dir}}{{end}}{{end}}' ./cmd/voicedraft-sync > "$scratch/modules"
sort -u "$scratch/modules" > "$scratch/unique"
while read -r module dir; do
    [ -n "$module" ] || continue
    printf '\n\n%s\n' "$module"
    test -f "$dir/LICENSE"
    for notice in "$dir"/LICENSE* "$dir"/NOTICE* "$dir"/COPYING* "$dir"/PATENTS "$dir"/AUTHORS; do
        if [ -f "$notice" ]; then
            printf '\n%s\n' "${notice##*/}"
            cat "$notice"
        fi
    done
done < "$scratch/unique"

go list -deps -f '{{if .Standard}}{{.Dir}}{{end}}' ./cmd/voicedraft-sync > "$scratch/stdlib"
while IFS= read -r dir; do
    while [ -n "$dir" ] && [ "$dir" != "$goroot/src" ]; do
        for notice in "$dir"/LICENSE* "$dir"/PATENTS "$dir"/NOTICE*; do
            if [ -f "$notice" ]; then printf '%s\n' "$notice"; fi
        done
        dir=${dir%/*}
    done
done < "$scratch/stdlib" | sort -u > "$scratch/stdlib-notices"
while IFS= read -r notice; do
    printf '\n\nGo %s\n' "${notice#"$goroot"/}"
    cat "$notice"
done < "$scratch/stdlib-notices"
