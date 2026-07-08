#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC2034 # used by scripts that source this file
BASE_BRANCH="master"
# shellcheck disable=SC2034 # used by scripts that source this file
SECRETS_UPDATES_BRANCH="automation/node-secrets-updates"
# shellcheck disable=SC2034 # used by scripts that source this file
SECURITY_UPDATES_BRANCH="automation/node-security-updates"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

ensure_git_identity() {
  local name email

  name="$(git config user.name || true)"
  email="$(git config user.email || true)"

  if [[ -z "$name" || -z "$email" ]]; then
    fail "Git user.name and user.email must be configured."
  fi
}

ensure_github_auth() {
  gh auth status >/dev/null
}

require_discovery_report_path() {
  local value="${DISCOVERY_REPORT_PATH:-}"

  [[ -n "${value//[[:space:]]/}" ]] ||
    fail "DISCOVERY_REPORT_PATH is required"
}

validate_report() {
  local image="$1"

  require_discovery_report_path
  [[ -f "$DISCOVERY_REPORT_PATH" ]] || fail "Discovery report not found: $DISCOVERY_REPORT_PATH"

  jq -e --arg image "$image" '
    (.changes[$image] | type == "array") and (.skipped | type == "array")
  ' "$DISCOVERY_REPORT_PATH" >/dev/null || fail "Discovery report is missing changes.$image or skipped entries."
}

changed_paths() {
  local dir="$1"

  git status --porcelain -- "$dir" |
    while IFS= read -r line; do
      local path="${line:3}"
      printf '%s\n' "${path##* -> }"
    done |
    sed '/^$/d'
}

expected_paths() {
  local image="$1"

  jq -r --arg image "$image" '.changes[$image][].path' "$DISCOVERY_REPORT_PATH"
}

update_message() {
  local image_key="$1"
  local image_name="$2"
  local restrict_to_paths=false
  local included_paths_json

  shift 2

  if (($# > 0)); then
    restrict_to_paths=true
    included_paths_json="$(paths_json "$@")"
  else
    included_paths_json='[]'
  fi

  jq -er \
    --arg image "$image_key" \
    --arg imageName "$image_name" \
    --argjson restrictToPaths "$restrict_to_paths" \
    --argjson includedPaths "$included_paths_json" '
      .changes[$image]
      | if type == "array" then . else error("Discovery report is missing changes." + $image) end
      | if $restrictToPaths then
          map(select(.path as $path | $includedPaths | index($path)))
        else
          .
        end
      | map(
          .latestNodeVersion
          | if type == "string" and length > 0 then . else error("Missing latestNodeVersion for " + $image) end
        )
      | reduce .[] as $version ([]; if index($version) then . else . + [$version] end)
      | if length == 0 then error("No " + $imageName + " versions selected for update message") else . end
      | "feat: `\($imageName)` \(join(", "))"
    ' "$DISCOVERY_REPORT_PATH"
}

assert_paths_match_report() {
  local image="$1"
  local label="$2"
  local dir="$3"
  local tmp_dir expected actual

  tmp_dir="$(mktemp -d)"
  expected="$tmp_dir/expected"
  actual="$tmp_dir/actual"

  expected_paths "$image" | sort >"$expected"
  changed_paths "$dir" | sort >"$actual"

  if ! diff -u "$expected" "$actual" >/dev/null; then
    printf 'Discovery report does not match applied %s changes.\n' "$label" >&2
    printf 'Expected paths:\n' >&2
    sed 's/^/- /' "$expected" >&2
    printf 'Actual paths:\n' >&2
    sed 's/^/- /' "$actual" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi

  rm -rf "$tmp_dir"
}

assert_only_paths() {
  local dir="$1"
  local label="$2"
  shift 2
  local invalid=()

  for path in "$@"; do
    if [[ "$path" != "$dir"* ]]; then
      invalid+=("$path")
    fi
  done

  if ((${#invalid[@]} > 0)); then
    fail "$label PR contains invalid changes: ${invalid[*]}"
  fi
}

paths_json() {
  if (($# == 0)); then
    printf '[]\n'
    return
  fi

  printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0))'
}

remote_branch_oid() {
  local branch="$1"
  local output

  output="$(git ls-remote --heads origin "refs/heads/$branch")" ||
    fail "Unable to read remote branch origin/$branch"

  if [[ -n "$output" ]]; then
    printf '%s\n' "${output%%$'\t'*}"
  fi
}

prepare_publish_worktree() {
  local branch="$1"
  local base_branch="$2"
  local worktree="$3"

  git fetch origin "$base_branch"
  PUSH_LEASE_BRANCH="$branch"
  PUSH_LEASE_EXPECTED_SHA="$(remote_branch_oid "$branch")"
  git worktree add --force -B "$branch" "$worktree" "origin/$base_branch"
}

remove_publish_worktree() {
  local worktree="$1"

  [[ -n "$worktree" && -d "$worktree" ]] || return 0
  git worktree remove --force "$worktree"
}

PUSH_LEASE_BRANCH=""
PUSH_LEASE_EXPECTED_SHA=""

staged_paths() {
  git diff --cached --name-only
}

push_branch() {
  local branch="$1"
  local worktree="$2"

  [[ "$PUSH_LEASE_BRANCH" == "$branch" ]] ||
    fail "No push lease was established for branch: $branch"

  git -C "$worktree" push \
    "--force-with-lease=refs/heads/$branch:$PUSH_LEASE_EXPECTED_SHA" \
    origin "$branch:$branch"
}

find_pr_json() {
  local branch="$1"
  local base_branch="$2"

  gh pr list \
    --head "$branch" \
    --base "$base_branch" \
    --state open \
    --json number,url,isDraft,body,headRefOid \
    --jq '.[0] // empty'
}

pr_number_from_json() {
  jq -r '.number // empty' <<<"$1"
}

refresh_pr_json() {
  local number="$1"

  gh pr view "$number" --json number,url,isDraft,body,headRefOid
}

create_or_update_pr() {
  local branch="$1"
  local base_branch="$2"
  local title="$3"
  local body_file="$4"
  local draft="${5:-false}"
  local existing number pr action
  local -a create_args=()

  existing="$(find_pr_json "$branch" "$base_branch")"

  if [[ -n "$existing" ]]; then
    number="$(pr_number_from_json "$existing")"
    gh pr edit "$number" --title "$title" --body-file "$body_file" >/dev/null
    action="updated"
  else
    [[ "$draft" == "true" ]] && create_args+=(--draft)
    gh pr create \
      --title "$title" \
      --body-file "$body_file" \
      --base "$base_branch" \
      --head "$branch" \
      "${create_args[@]}" >/dev/null
    number="$(pr_number_from_json "$(find_pr_json "$branch" "$base_branch")")"
    action="created"
  fi

  pr="$(refresh_pr_json "$number")"
  if [[ "$draft" == "true" && "$(jq -r '.isDraft' <<<"$pr")" != "true" ]]; then
    gh pr ready "$number" --undo >/dev/null
    pr="$(refresh_pr_json "$number")"
  fi

  jq -c --arg action "$action" '. + {action: $action}' <<<"$pr"
}
