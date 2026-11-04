#!/bin/sh
# Offline safety test for the version threshold, repo guard and deletion plan.
set -eu
cd "$(dirname "$0")/.."
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT HUP INT TERM
cat >"$temp/gh" <<'GH'
#!/bin/sh
case "$*" in
  *"releases?per_page=100"*)
    printf '%s\n' v2.2.12 v2.2.21 v2.2.22 v2.2.23 v2.2.24 v2.3.0 v3.0.0 unrelated-tag;;
  *"git/matching-refs/tags"*)
    printf '%s\n' refs/tags/v2.2.8 refs/tags/v2.2.22 refs/tags/v2.2.23 refs/tags/v2.2.24 refs/tags/other;;
  *) echo "Unexpected GitHub request: $*" >&2; exit 1;;
esac
GH
chmod +x "$temp/gh"
PATH="$temp:$PATH" GITHUB_REPOSITORY=theonemule/LITEFW2 \
  bash tools/prune-old-releases.sh --dry-run >"$temp/output"
for older in v2.2.12 v2.2.21 v2.2.22 v2.2.8; do
  grep -Fq "$older" "$temp/output"
done
for newer in v2.2.23 v2.2.24 v2.3.0 v3.0.0 unrelated-tag; do
  if grep -E "^Pruning " "$temp/output" | grep -Fq "$newer"; then
    echo "Unexpected retention deletion candidate $newer" >&2
    exit 1
  fi
done
! PATH="$temp:$PATH" GITHUB_REPOSITORY=someone/else \
  bash tools/prune-old-releases.sh --dry-run >/dev/null 2>&1
echo 'PASS cleanup only considers versioned releases and orphan tags below v2.2.23'
