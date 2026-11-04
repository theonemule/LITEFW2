#!/usr/bin/env bash
# Retain v2.2.23 onward; do not delete branches or rewrite commits.
set -euo pipefail
: "${GITHUB_REPOSITORY:?repository required}"
[[ "$GITHUB_REPOSITORY" == "theonemule/LITEFW2" ]] ||
  { echo 'Wrong repository; refusing cleanup' >&2; exit 1; }
[[ "${1:-}" == "" || "${1:-}" == "--dry-run" ]] ||
  { echo 'Usage: prune-old-releases.sh [--dry-run]' >&2; exit 2; }
dry_run=no
[[ "${1:-}" != "--dry-run" ]] || dry_run=yes
release_tag="v$(cat VERSION)"
[[ "$release_tag" =~ ^v2[.]2[.][0-9]+$ ]] || { echo 'Invalid current version' >&2; exit 1; }
if [[ "$dry_run" != yes ]]; then
  gh release view "$release_tag" --repo "$GITHUB_REPOSITORY" >/dev/null
fi
is_old(){
  local tag="$1" major minor patch
  [[ "$tag" =~ ^v([0-9]+)[.]([0-9]+)[.]([0-9]+)$ ]] || return 1
  major=$((10#${BASH_REMATCH[1]}))
  minor=$((10#${BASH_REMATCH[2]}))
  patch=$((10#${BASH_REMATCH[3]}))
  (( major < 2 || (major == 2 && (minor < 2 || (minor == 2 && patch < 23))) ))
}
while IFS= read -r tag; do
  [[ -n "$tag" ]] || continue
  is_old "$tag" || continue
  echo "Pruning obsolete LiteFW release $tag"
  if [[ "$dry_run" == no ]]; then
    gh release delete "$tag" --repo "$GITHUB_REPOSITORY" --cleanup-tag --yes
  fi
done < <(gh api --paginate --jq '.[].tag_name' \
  "repos/$GITHUB_REPOSITORY/releases?per_page=100")
while IFS= read -r ref; do
  tag=${ref#refs/tags/}
  is_old "$tag" || continue
  echo "Pruning orphan obsolete LiteFW tag $tag"
  if [[ "$dry_run" == no ]]; then
    gh api --method DELETE "repos/$GITHUB_REPOSITORY/git/refs/tags/$tag" >/dev/null
  fi
done < <(gh api --paginate --jq '.[].ref' \
  "repos/$GITHUB_REPOSITORY/git/matching-refs/tags")
echo 'LiteFW retention: v2.2.23 and newer preserved.'
