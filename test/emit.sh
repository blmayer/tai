#!/bin/sh
# Transcript lines are appended once. The terminal keeps the scrollback.
set -eu
cd "$(dirname "$0")/.."
sh -n ./tai

for bad in 'tput smcup' 'tput rmcup' '1000h' '1006h' '1007h' build_screen render_plan hide_plan; do
	if grep -n -F -- "$bad" ./tai >/dev/null; then
		echo "FAIL still has $bad" >&2
		exit 1
	fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cache"
awk '
	/^append_raw\(\)/ { p = 1 }
	/^draw_live\(\)/ { p = 0 }
	p { print }
' ./tai > "$tmp/fns.sh"
sh -n "$tmp/fns.sh"
# shellcheck disable=SC1091
. "$tmp/fns.sh"

cache=$tmp/cache
state=$cache/state.json
raw=$cache/raw
raw_count=0
printed=0
: > "$raw"

die() {
	printf 'FAIL %s\n' "$1" >&2
	exit 1
}

printf '%s\n' '{"io":{"say":[{"d":0,"k":"U","t":"hello"},{"d":0,"k":"C","t":"read: a"}]}}' > "$state"
flush_say
[ "$raw_count" = 3 ] || die "flush count $raw_count"
grep -q '^Uhello$' "$raw" || die "missing user line"
grep -q '^Cread: a$' "$raw" || die "missing call"

emit_pending > "$tmp/out"
[ "$printed" = 3 ] || die "printed $printed"
grep -F -q "$(printf '\033[1mhello\033[m')" "$tmp/out" || die "user color"
grep -F -q "$(printf '\033[33mread: a\033[m')" "$tmp/out" || die "call color"
# The blank row between the two messages is a bare newline.
awk 'NR==2 && $0=="" { found=1 } END { exit !found }' "$tmp/out" || die "missing blank"

emit_pending > "$tmp/again"
[ ! -s "$tmp/again" ] || die "emitted twice"

printf '%s\n' '{"io":{"say":[{"d":0,"k":"T","t":"done"}]}}' > "$state"
flush_say
[ "$raw_count" = 5 ] || die "second flush $raw_count"
emit_pending > "$tmp/more"
[ "$printed" = 5 ] || die "printed after $printed"
[ "$(wc -l < "$tmp/more" | tr -d ' ')" = 2 ] || die "new rows $(wc -l < "$tmp/more" | tr -d ' ')"
grep -F -q "$(printf '\033[2mdone\033[m')" "$tmp/more" || die "dim result"
grep -F -q 'hello' "$tmp/more" && die "old line repeated"

rows=24
ilines=1
help=0
cur_line=0
fit_prompt
[ "$gap" = 1 ] || die "gap $gap"
[ "$plines" = 1 ] || die "plines $plines"

ilines=4
fit_prompt
[ "$gap" = 0 ] || die "multiline gap"
[ "$plines" = 4 ] || die "multiline plines $plines"

printf 'one\ntwo\nthree\nfour\nfive\n' > "$cache/help.txt"
rows=6
ilines=1
help=1
fit_prompt
[ "$gap" = 0 ] || die "help gap"
[ "$plines" = 1 ] || die "help plines"
[ "$help_rows" -le 4 ] || die "help rows $help_rows"
used=$((1 + gap + plines + help_rows))
[ "$used" -le "$rows" ] || die "live block $used"

printf 'ok\n'
