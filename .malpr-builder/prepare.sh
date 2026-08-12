#!/usr/bin/env bash
set -euo pipefail

workspace="${GITHUB_WORKSPACE:?}"
metadata="$workspace/.malpr-builder/cases.tsv"
source_repo="$(<"$workspace/.malpr-builder/source_repo.txt")"
coderabbit_disable="$workspace/.malpr-builder/disable-coderabbit.yaml"
cache="$(mktemp -d)"
worktree_parent="$(mktemp -d)"
results="$workspace/.malpr-builder/prepared-results.tsv"

cleanup() {
  rm -rf -- "$cache" "$worktree_parent"
}
trap cleanup EXIT

git init --bare -q "$cache"
git -C "$cache" remote add upstream "https://github.com/$source_repo.git"
git -C "$cache" remote add target "https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY.git"
owner_id="$(gh api "users/$GITHUB_REPOSITORY_OWNER" --jq .id)"
git -C "$cache" config user.name "$GITHUB_REPOSITORY_OWNER"
git -C "$cache" config user.email "$owner_id+$GITHUB_REPOSITORY_OWNER@users.noreply.github.com"
: >"$results"

while IFS=$'\t' read -r public_case_id case_id base_ref diff_file; do
  [[ -n "$public_case_id" ]] || continue
  short_case_id="${public_case_id#*-}"
  base_branch="case/$short_case_id-base"
  head_branch="case/$short_case_id-head"
  upstream_ref="refs/malpr/upstream/$short_case_id"
  patch="$workspace/.malpr-inputs/$diff_file"
  worktree="$worktree_parent/$short_case_id"

  base_exists=false
  head_exists=false
  git -C "$cache" ls-remote --exit-code target "refs/heads/$base_branch" >/dev/null 2>&1 && base_exists=true
  git -C "$cache" ls-remote --exit-code target "refs/heads/$head_branch" >/dev/null 2>&1 && head_exists=true
  if [[ "$base_exists" == true && "$head_exists" == true ]]; then
    echo "case branch pair already exists; preserving and resuming: $public_case_id"
    continue
  elif [[ "$base_exists" == true || "$head_exists" == true ]]; then
    echo "incomplete case branch pair; refusing mutation: $public_case_id" >&2
    exit 4
  fi
  if [[ ! -f "$patch" ]]; then
    echo "missing fixed input patch: $patch" >&2
    exit 5
  fi

  git -C "$cache" fetch --no-tags --depth=1 upstream "$base_ref:$upstream_ref"
  git -C "$cache" worktree add --detach "$worktree" "$upstream_ref"

  if ! grep -q '^diff --git a/\.github/workflows/' "$patch"; then
    rm -rf -- "$worktree/.github/workflows"
  fi
  rm -f -- "$worktree/.coderabbit.yaml"
  cp -- "$coderabbit_disable" "$worktree/.coderabbit.yaml"
  git -C "$worktree" add -A

  base_tree="$(git -C "$worktree" write-tree)"
  base_commit="$(
    GIT_AUTHOR_DATE="2026-08-12T00:00:00Z" \
    GIT_COMMITTER_DATE="2026-08-12T00:00:00Z" \
      git -C "$worktree" commit-tree "$base_tree" -m "Case base."
  )"
  git -C "$worktree" checkout -q --detach "$base_commit"

  source_sha256="$(sha256sum "$patch" | awk '{print $1}')"
  source_patch_id="$(git patch-id --stable <"$patch" | awk 'NR == 1 {print $1}')"
  git -C "$worktree" apply --index --whitespace=nowarn "$patch"
  head_tree="$(git -C "$worktree" write-tree)"
  head_commit="$(
    GIT_AUTHOR_DATE="2026-08-12T00:00:00Z" \
    GIT_COMMITTER_DATE="2026-08-12T00:00:00Z" \
      git -C "$worktree" commit-tree "$head_tree" -p "$base_commit" -m "Case record."
  )"
  prepared_patch_id="$(git -C "$worktree" diff --binary "$base_commit" "$head_commit" | git patch-id --stable | awk 'NR == 1 {print $1}')"
  changed_files="$(git -C "$worktree" diff --name-only --no-renames "$base_commit" "$head_commit" | awk 'NF {n++} END {print n+0}')"

  if [[ -z "$source_patch_id" || "$source_patch_id" != "$prepared_patch_id" ]]; then
    echo "patch-id mismatch for $public_case_id: source=$source_patch_id prepared=$prepared_patch_id" >&2
    exit 6
  fi

  git -C "$cache" push target "$base_commit:refs/heads/$base_branch" "$head_commit:refs/heads/$head_branch"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$public_case_id" "$base_commit" "$head_commit" "$source_sha256" \
    "$prepared_patch_id" "$changed_files" "$base_ref" | tee -a "$results"

  git -C "$cache" worktree remove --force "$worktree"
done <"$metadata"

echo "Prepared all fixed CodeQL case branches."
