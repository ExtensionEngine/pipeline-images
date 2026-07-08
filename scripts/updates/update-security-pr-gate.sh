#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/updates/pr-helpers.sh
source "$SCRIPT_DIR/pr-helpers.sh"

BRANCH="$SECURITY_UPDATES_BRANCH"
DOCKER_HUB_API_URL="${DOCKER_HUB_API_URL:-https://hub.docker.com/v2/repositories}"
GATE_START='<!-- node-security-dependency-gate:start -->'
GATE_END='<!-- node-security-dependency-gate:end -->'

if (($# > 0)); then
  fail "Unexpected arguments: $*"
fi

security_files_from_pr() {
  gh pr view "$1" --json files --jq '.files[].path | select(test("^node/security/[0-9]+$"))'
}

node_version_from_pr_file() {
  local repository="$1" head_ref_oid="$2" path="$3" content version

  content="$(gh api -H 'Accept: application/vnd.github.raw+json' "repos/$repository/contents/$path?ref=$head_ref_oid")" ||
    fail "Unable to read $path at security PR head $head_ref_oid"
  version="$(awk -F= '$1 == "NODE_VERSION" { print $2; exit }' <<<"$content")"
  [[ -n "$version" ]] || fail "Missing NODE_VERSION in $path at security PR head $head_ref_oid"
  printf '%s\n' "$version"
}

required_tags_json() {
  local pr_json="$1" number repository head_ref_oid path node_version

  number="$(pr_number_from_json "$pr_json")"
  repository="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')" || fail "Unable to determine the GitHub repository"
  [[ -n "$repository" ]] || fail "GitHub repository name is empty"
  head_ref_oid="$(jq -r '.headRefOid' <<<"$pr_json")"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    node_version="$(node_version_from_pr_file "$repository" "$head_ref_oid" "$path")"
    jq -n --arg path "$path" --argjson major "${path##*/}" --arg nodeVersion "$node_version" \
      '{path: $path, major: $major, nodeVersion: $nodeVersion}'
  done < <(security_files_from_pr "$number") | jq -s '.'
}

docker_tag_statuses_json() {
  jq -c '.[]' | while IFS= read -r tag; do
    local path major node_version status
    path="$(jq -r '.path' <<<"$tag")"
    major="$(jq -r '.major' <<<"$tag")"
    node_version="$(jq -r '.nodeVersion' <<<"$tag")"
    status="$(curl -fsS -o /dev/null -w '%{http_code}' "$DOCKER_HUB_API_URL/studiondev/node-secrets/tags/$node_version" || true)"

    case "$status" in
    200) jq -n --arg path "$path" --argjson major "$major" --arg nodeVersion "$node_version" '{path: $path, major: $major, nodeVersion: $nodeVersion, available: true}' ;;
    404) jq -n --arg path "$path" --argjson major "$major" --arg nodeVersion "$node_version" '{path: $path, major: $major, nodeVersion: $nodeVersion, available: false}' ;;
    *) fail "Docker tag check failed (${status:-curl error}) for studiondev/node-secrets:$node_version" ;;
    esac
  done | jq -s '.'
}

dependency_section() {
  jq -r --arg start "$GATE_START" --arg end "$GATE_END" '
    ([.[] | select(.available == false)] | length) as $missing |
    [
      $start, "## Dependency Gate", "",
      "Status: **\(if $missing == 0 then "ready" else "blocked" end)**", "",
      "Required node-secrets image tags:", "",
      (.[] | "- `studiondev/node-secrets:\(.nodeVersion)`: \(if .available then "available" else "missing" end)"), "",
      (if $missing == 0 then "All required node-secrets images are published. This PR can be marked ready." else "Keep this PR draft/blocked until all required node-secrets images are published." end),
      $end
    ] | join("\n")'
}

upsert_dependency_section() {
  local body="$1" section="$2"

  # shellcheck disable=SC2016
  BODY="$body" SECTION="$section" node -e '
    const body = process.env.BODY.replace(/\n+$/, "");
    const section = process.env.SECTION.replace(/\n+$/, "");
    const pattern = /<!-- node-security-dependency-gate:start -->[\s\S]*<!-- node-security-dependency-gate:end -->/;
    process.stdout.write(`${pattern.test(body) ? body.replace(pattern, section) : `${body}\n\n${section}`}\n`);
  '
}

ensure_github_auth
pr_json="$(find_pr_json "$BRANCH" "$BASE_BRANCH")"
if [[ -z "$pr_json" ]]; then
  printf 'No open node-security PR found.\n'
  exit 0
fi

pr_json="$(refresh_pr_json "$(pr_number_from_json "$pr_json")")"
required_tags="$(required_tags_json "$pr_json")"
if [[ "$(jq 'length' <<<"$required_tags")" == "0" ]]; then
  printf 'Security PR has no node/security env file changes.\n'
  exit 0
fi

statuses="$(docker_tag_statuses_json <<<"$required_tags")"
body="$(jq -r '.body // ""' <<<"$pr_json")"
updated_body="$(upsert_dependency_section "$body" "$(dependency_section <<<"$statuses")")"
number="$(pr_number_from_json "$pr_json")"
missing_count="$(jq '[.[] | select(.available == false)] | length' <<<"$statuses")"
is_draft="$(jq -r '.isDraft' <<<"$pr_json")"
gh pr edit "$number" --body "$updated_body" >/dev/null

if [[ "$missing_count" == 0 ]]; then
  [[ "$is_draft" != true ]] || gh pr ready "$number" >/dev/null
  printf 'Security dependency gate: ready.\n'
else
  [[ "$is_draft" == true ]] || gh pr ready "$number" --undo >/dev/null
  printf 'Security dependency gate: blocked.\n'
fi
