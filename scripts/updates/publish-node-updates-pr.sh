#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/updates/pr-helpers.sh
source "$SCRIPT_DIR/pr-helpers.sh"

if (($# != 1)); then
  fail "Usage: $0 <secrets|security>"
fi

MODE="$1"
case "$MODE" in
secrets)
  BRANCH="$SECRETS_UPDATES_BRANCH"
  IMAGE_DIR="node/secrets/"
  IMAGE_NAME="node-secrets"
  DRAFT=false
  ;;
security)
  BRANCH="$SECURITY_UPDATES_BRANCH"
  IMAGE_DIR="node/security/"
  IMAGE_NAME="node-security"
  DRAFT=true
  ;;
*)
  fail "Unknown publisher mode: $MODE"
  ;;
esac

format_secrets_body() {
  local body_file="$1"

  jq -r -f <(
    cat <<'EOF'
def toolChanges(change):
  if (change.toolChanges | length) == 0 then
    "Infisical unchanged"
  else
    change.toolChanges
    | map("Infisical \(.current) -> \(.selected)")
    | join(", ")
  end;

[
  "## Summary", "",
  "Updates `node-secrets` env files for eligible even-major Node.js releases.", "",
  "## Changes", "",
  (if (.changes.secrets | length) > 0 then .changes.secrets[] | "- `\(.path)`: Node \(.currentNodeVersion // "new") -> \(.latestNodeVersion) (\(.classification)); \(toolChanges(.))" else "- No `node-secrets` changes." end),
  "", "## Skipped", "",
  ([.skipped[] | select(.image == "secrets") | "- Node \(.major) (\(.nodeVersion)): \(.reason)"] | if length > 0 then .[] else "- None" end),
  "", "## Merge Notes", "",
  "Squash-merge this PR so the existing image-change detector sees all env file changes in one final commit."
] | join("\n")
EOF
  ) "$DISCOVERY_REPORT_PATH" >"$body_file"
}

format_security_body() {
  local body_file="$1"
  local secrets_pr="$2"
  local dependency url

  url="$(jq -r '.url // empty' <<<"$secrets_pr")"
  if [[ -n "$url" ]]; then
    dependency="Depends on \`node-secrets\` PR $url."
  else
    dependency="Depends on the \`node-secrets\` update PR from branch \`$SECRETS_UPDATES_BRANCH\`."
  fi

  jq -r --arg dependency "$dependency" -f <(
    cat <<'EOF'
def toolChanges(change):
  if (change.toolChanges | length) == 0 then
    "security tools unchanged"
  else
    change.toolChanges
    | map("\(.variable) \(.current) -> \(.selected)")
    | join(", ")
  end;

[
  "## Summary", "",
  "Updates `node-security` env files for eligible even-major Node.js releases.", "",
  "## Dependency", "",
  $dependency,
  "Do not merge this PR until the matching `studiondev/node-secrets:<NODE_VERSION>` image tags are published.",
  "This PR is created as draft/blocked by default; the dependency gate updates readiness after checking the required image tags.",
  "", "## Changes", "",
  (if (.changes.security | length) > 0 then .changes.security[] | "- `\(.path)`: Node \(.currentNodeVersion // "new") -> \(.latestNodeVersion) (\(.classification)); \(toolChanges(.))" else "- No node-security changes." end),
  "", "## Skipped", "",
  ([.skipped[] | select(.image == "security") | "- Node \(.major) (\(.nodeVersion)): \(.reason)"] | if length > 0 then .[] else "- None" end),
  "", "## Merge Notes", "",
  "Squash-merge this PR so the existing image-change detector sees all env file changes in one final commit."
] | join("\n")
EOF
  ) "$DISCOVERY_REPORT_PATH" >"$body_file"
}

validate_report "$MODE"

if [[ "$(jq ".changes.$MODE | length" "$DISCOVERY_REPORT_PATH")" == "0" ]]; then
  printf 'No %s changes to publish.\n' "$IMAGE_NAME"
  exit 0
fi

paths=()
while IFS= read -r path; do
  paths+=("$path")
done < <(expected_paths "$MODE")
assert_paths_match_report "$MODE" "$IMAGE_NAME" "$IMAGE_DIR"
assert_only_paths "$IMAGE_DIR" "$IMAGE_NAME" "${paths[@]}"

body_file="$(mktemp)"
worktree="$(mktemp -d)"
rmdir "$worktree"
cleanup() {
  local status=$?
  trap - EXIT
  remove_publish_worktree "$worktree" || rm -rf "$worktree"
  rm -f "$body_file"
  exit "$status"
}
trap cleanup EXIT

ensure_git_identity
ensure_github_auth
if [[ "$MODE" == security ]]; then
  format_security_body "$body_file" "$(find_pr_json "$SECRETS_UPDATES_BRANCH" "$BASE_BRANCH")"
else
  format_secrets_body "$body_file"
fi

prepare_publish_worktree "$BRANCH" "$BASE_BRANCH" "$worktree"
for path in "${paths[@]}"; do
  mkdir -p "$worktree/$(dirname "$path")"
  cp "$path" "$worktree/$path"
done

git -C "$worktree" add "${paths[@]}"
staged=()
while IFS= read -r path; do
  staged+=("$path")
done < <(git -C "$worktree" diff --cached --name-only)
if ((${#staged[@]} > 0)); then
  assert_only_paths "$IMAGE_DIR" "$IMAGE_NAME" "${staged[@]}"
  title="$(update_message "$MODE" "$IMAGE_NAME" "${staged[@]}")"
  git -C "$worktree" commit -m "$title"
  push_branch "$BRANCH" "$worktree"
  create_or_update_pr "$BRANCH" "$BASE_BRANCH" "$title" "$body_file" "$DRAFT" >/dev/null
  printf 'Published %s update PR.\n' "$IMAGE_NAME"
  exit 0
fi

title="$(update_message "$MODE" "$IMAGE_NAME")"
existing="$(find_pr_json "$BRANCH" "$BASE_BRANCH")"
if [[ -n "$existing" ]]; then
  create_or_update_pr "$BRANCH" "$BASE_BRANCH" "$title" "$body_file" "$DRAFT" >/dev/null
  printf 'Refreshed existing %s update PR; no new commit was needed.\n' "$IMAGE_NAME"
else
  printf 'No new %s commit was needed and no existing PR was found.\n' "$IMAGE_NAME"
fi
