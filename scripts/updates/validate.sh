#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISCOVERY_SCRIPT="$SCRIPT_DIR/discover-node-updates.js"
PUBLISHER_SCRIPT="$SCRIPT_DIR/publish-node-updates-pr.sh"
UPDATE_SCRIPTS=(
  "$SCRIPT_DIR/pr-helpers.sh"
  "$PUBLISHER_SCRIPT"
  "$SCRIPT_DIR/update-security-pr-gate.sh"
  "$SCRIPT_DIR/validate.sh"
)

run_static_checks() {
  local script

  node --check "$DISCOVERY_SCRIPT"
  for script in "${UPDATE_SCRIPTS[@]}"; do
    bash -n "$script"
  done

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${UPDATE_SCRIPTS[@]}"
  fi
}

write_env_files() {
  local root="$1" major

  mkdir -p "$root/node/secrets" "$root/node/security"
  for major in 22 24; do
    cat >"$root/node/secrets/$major" <<EOF
NODE_VERSION=$major.1.0
INFISICAL_VERSION=0.20.0
IMAGE_TAGS=($major.1.0 $major)
EOF
    cat >"$root/node/security/$major" <<EOF
NODE_VERSION=$major.1.0
GITLEAKS_VERSION=v8.1.0
GRYPE_VERSION=v0.90.0
SEMGREP_VERSION=1.50.0
SYFT_VERSION=v0.90.0
TRIVY_VERSION=0.50.0
IMAGE_TAGS=($major.1.0 $major)
EOF
  done
}

write_release_index() {
  cat >"$1" <<'JSON'
[
  {"version":"v22.1.1"},
  {"version":"v24.2.0"},
  {"version":"v25.0.0"},
  {"version":"v26.0.0"}
]
JSON
}

write_mock_server() {
  cat >"$1" <<'NODE'
import { createServer } from "node:http";
import { writeFileSync } from "node:fs";

const portFile = process.argv[2];
const dockerTags = {
  "/repositories/infisical/cli/tags": ["0.20.1", "0.21.0", "1.0.0"],
  "/repositories/zricethezav/gitleaks/tags": ["v8.1.1", "v8.2.0", "v9.0.0"],
  "/repositories/anchore/grype/tags": ["v0.90.1", "v0.91.0", "v1.0.0"],
  "/repositories/anchore/syft/tags": ["v0.90.1", "v0.91.0", "v1.0.0"],
  "/repositories/aquasec/trivy/tags": ["0.50.1", "0.51.0", "1.0.0"],
};
const json = (res, status, body) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};
const server = createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");

  if (["22.1.1", "24.2.0", "26.0.0"].includes(url.pathname.split("/").at(-1)) &&
      url.pathname.startsWith("/repositories/cimg/node/tags/")) {
    json(res, 200, { name: url.pathname.split("/").at(-1) });
  } else if (dockerTags[url.pathname]) {
    json(res, 200, { results: dockerTags[url.pathname].map((name) => ({ name })), next: null });
  } else if (url.pathname === "/pypi/semgrep/json") {
    json(res, 200, { releases: {
      "1.50.1": [{ yanked: false }], "1.51.0": [{ yanked: false }], "2.0.0": [{ yanked: false }],
    }});
  } else {
    json(res, 404, { message: "not found", path: url.pathname });
  }
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
NODE
}

wait_for_file() {
  local path="$1" _

  for _ in {1..50}; do
    [[ -s "$path" ]] && return
    sleep 0.1
  done
  printf 'Timed out waiting for %s\n' "$path" >&2
  return 1
}

assert_json() {
  jq -e "$2" <<<"$1" >/dev/null
}

assert_env_value() {
  local file="$1" variable="$2" expected="$3" actual

  actual="$(awk -F= -v variable="$variable" '$1 == variable { print $2; exit }' "$file")"
  [[ "$actual" == "$expected" ]] || {
    printf 'Expected %s=%s in %s, got %s\n' "$variable" "$expected" "$file" "$actual" >&2
    exit 1
  }
}

expect_failure() {
  local description="$1" expected="$2" output
  shift 2

  if output="$("$@" 2>&1)"; then
    printf '%s unexpectedly succeeded\n' "$description" >&2
    return 1
  fi
  [[ "$output" == *"$expected"* ]] || {
    printf '%s did not report %q:\n%s\n' "$description" "$expected" "$output" >&2
    return 1
  }
}

# Fixture state is inherited by the synchronous discovery test callback.
# shellcheck disable=SC2030,SC2031
with_discovery_fixture() (
  local test="$1" tmp server_pid

  tmp="$(mktemp -d)"
  root="$tmp/repo"
  release_index="$tmp/release-index.json"
  report="$tmp/report.json"
  server_script="$tmp/mock-server.mjs"
  port_file="$tmp/port"
  trap '
    kill "${server_pid:-}" >/dev/null 2>&1 || true
    wait "${server_pid:-}" 2>/dev/null || true
    rm -rf "$tmp"
  ' EXIT

  mkdir -p "$root"
  write_env_files "$root"
  write_release_index "$release_index"
  write_mock_server "$server_script"
  node "$server_script" "$port_file" >/dev/null 2>&1 &
  server_pid=$!
  wait_for_file "$port_file"
  base_url="http://127.0.0.1:$(<"$port_file")"
  "$test"
)

# shellcheck disable=SC2031
run_discovery() (
  local mode="$1" setting
  shift
  cd "$root"
  export NODE_RELEASE_INDEX_PATH="$release_index"
  export NODE_RELEASE_INDEX_URL="$base_url/release-index"
  export DOCKER_HUB_API_URL="$base_url/repositories"
  export PYPI_API_URL="$base_url/pypi"
  export DISCOVERY_REPORT_PATH="$report"
  for setting in "$@"; do
    export "${setting?}"
  done
  "$DISCOVERY_SCRIPT" "$mode"
)

# shellcheck disable=SC2031
test_discovery_dry_run_and_apply() {
  local dry_run_output

  dry_run_output="$(run_discovery --dry-run)"
  [[ ! -e "$report" ]]
  assert_json "$dry_run_output" '.dryRun == true'
  assert_json "$dry_run_output" '.changes.secrets | length == 3'
  assert_json "$dry_run_output" '.changes.security | length == 3'
  assert_json "$dry_run_output" '.changes.secrets[] | select(.major == 22 and .classification == "patch")'
  assert_json "$dry_run_output" '.changes.secrets[] | select(.major == 24 and .classification == "minor")'
  assert_json "$dry_run_output" '.changes.secrets[] | select(.major == 26 and .classification == "new-major")'
  assert_json "$dry_run_output" '.changes.security[] | select(.major == 22) | .toolChanges[] | select(.variable == "SEMGREP_VERSION" and .selected == "1.50.1")'

  run_discovery --apply >/dev/null
  assert_json "$(<"$report")" '.dryRun == false'
  assert_env_value "$root/node/secrets/22" NODE_VERSION 22.1.1
  assert_env_value "$root/node/secrets/24" INFISICAL_VERSION 0.21.0
  assert_env_value "$root/node/secrets/26" NODE_VERSION 26.0.0
  assert_env_value "$root/node/security/22" SEMGREP_VERSION 1.50.1
  assert_env_value "$root/node/security/26" NODE_VERSION 26.0.0
}

# shellcheck disable=SC2031
test_discovery_write_failure() {
  expect_failure "Discovery report write failure" "EISDIR" \
    run_discovery --apply "DISCOVERY_REPORT_PATH=$tmp"
}

test_discovery_configuration() {
  # shellcheck disable=SC2016 # $1 and $2 are expanded by the child Bash process.
  expect_failure "Discovery without report path" "DISCOVERY_REPORT_PATH is required" \
    env -u DISCOVERY_REPORT_PATH bash -c 'cd "$1" && "$2" --apply' _ "$REPO_ROOT" "$DISCOVERY_SCRIPT"
}

write_publisher_report() {
  local mode="$1" path="$2" version="$3"

  jq -n --arg mode "$mode" --arg path "$path" --arg version "$version" '
    {dryRun: false, generatedAt: "2026-07-16T00:00:00Z", changes: {secrets: [], security: []}, skipped: []}
    | .changes[$mode] = [{path: $path, major: ($path | split("/") | last | tonumber), currentNodeVersion: "old", latestNodeVersion: $version, classification: "patch", toolChanges: []}]
  '
}

write_noop_report() {
  printf '%s\n' '{"dryRun":false,"generatedAt":"2026-07-16T00:00:00Z","changes":{"secrets":[],"security":[]},"skipped":[]}' >"$1"
}

run_publisher_configuration_and_noop_tests() (
  local tmp report mode output

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  report="$tmp/report.json"
  for mode in secrets security; do
    expect_failure "Publisher $mode without report path" "DISCOVERY_REPORT_PATH is required" \
      env -u DISCOVERY_REPORT_PATH "$PUBLISHER_SCRIPT" "$mode"
  done
  expect_failure "Publisher with an unknown mode" "Unknown publisher mode: invalid" \
    "$PUBLISHER_SCRIPT" invalid

  write_noop_report "$report"
  for mode in secrets security; do
    output="$(cd "$REPO_ROOT" && DISCOVERY_REPORT_PATH="$report" "$PUBLISHER_SCRIPT" "$mode")"
    [[ "$output" == "No node-$mode changes to publish." ]]
  done
)

run_publisher_tests() (
  local tmp report log mode path version output worktree

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  log="$tmp/commands.log"
  cat >"$tmp/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_COMMAND_LOG:?}"
args=("$@")
while [[ "${args[0]:-}" == -C ]]; do args=("${args[@]:2}"); done
case "${args[0]:-}" in
  config) [[ "${args[1]:-}" == user.name ]] && printf 'Test User\n' || printf 'test@example.com\n' ;;
  status) printf ' M %s\n' "${MOCK_CHANGED_PATH:?}" ;;
  ls-remote) printf 'expected-sha\trefs/heads/%s\n' "${MOCK_BRANCH:?}" ;;
  worktree)
    if [[ "${args[1]:-}" == add ]]; then
      printf '%s\n' "${args[5]:?}" >"${MOCK_WORKTREE_PATH:?}"
      mkdir -p "${args[5]:?}"
    else
      rm -rf "${args[3]:?}"
    fi
    ;;
  diff)
    if [[ "${MOCK_STAGED:-true}" == true ]]; then
      printf '%s\n' "${MOCK_CHANGED_PATH:?}"
    fi
    ;;
  fetch|add|commit|push) ;;
esac
SH
  cat >"$tmp/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_COMMAND_LOG:?}"
pr='{"number":42,"url":"https://example.test/pr/42","isDraft":false,"body":"","headRefOid":"test-sha"}'
case "$1 $2" in
  "auth status"|"pr ready") ;;
  "pr list") [[ "${MOCK_EXISTING_PR:-true}" == true ]] && printf '%s\n' "$pr" ;;
  "pr view") printf '%s\n' "$pr" ;;
  "pr edit")
    for ((index = 1; index <= $#; index++)); do
      [[ "${!index}" == --body-file ]] || continue
      next_index=$((index + 1))
      [[ -s "${!next_index}" ]]
    done
    ;;
  *) printf 'unexpected gh args: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$tmp/git" "$tmp/gh"

  for mode in secrets security; do
    case "$mode" in
      secrets) path=node/secrets/22; version=22.22.1 ;;
      security) path=node/security/24; version=24.14.0 ;;
    esac
    report="$tmp/$mode-report.json"
    write_publisher_report "$mode" "$path" "$version" >"$report"
    mkdir -p "$tmp/repo/$(dirname "$path")"
    printf 'NODE_VERSION=old\n' >"$tmp/repo/$path"
    : >"$log"
    output="$(
      cd "$tmp/repo"
      PATH="$tmp:$PATH" MOCK_COMMAND_LOG="$log" MOCK_CHANGED_PATH="$path" \
        MOCK_BRANCH="automation/node-$mode-updates" MOCK_WORKTREE_PATH="$tmp/worktree" \
        DISCOVERY_REPORT_PATH="$report" "$PUBLISHER_SCRIPT" "$mode"
    )"
    [[ "$output" == "Published node-$mode update PR." ]]
    grep -Fq "worktree add --force -B automation/node-$mode-updates" "$log"
    grep -Fq "push --force-with-lease=refs/heads/automation/node-$mode-updates:expected-sha origin automation/node-$mode-updates:automation/node-$mode-updates" "$log"
    grep -Fq "worktree remove --force" "$log"
    worktree="$(<"$tmp/worktree")"
    [[ ! -e "$worktree" ]]
    grep -Fq "pr edit 42 --title feat: \`node-$mode\` $version" "$log"
    if [[ "$mode" == security ]]; then
      grep -Fqx 'pr ready 42 --undo' "$log"
    fi
  done

  mode=secrets
  path=node/secrets/22
  version=22.22.1
  report="$tmp/refresh-report.json"
  write_publisher_report "$mode" "$path" "$version" >"$report"
  : >"$log"
  output="$(
    cd "$tmp/repo"
    PATH="$tmp:$PATH" MOCK_COMMAND_LOG="$log" MOCK_CHANGED_PATH="$path" \
      MOCK_BRANCH="automation/node-secrets-updates" MOCK_WORKTREE_PATH="$tmp/refresh-worktree" \
      MOCK_STAGED=false MOCK_EXISTING_PR=true DISCOVERY_REPORT_PATH="$report" \
      "$PUBLISHER_SCRIPT" "$mode"
  )"
  [[ "$output" == 'Refreshed existing node-secrets update PR; no new commit was needed.' ]]
  # shellcheck disable=SC2016 # Backticks are literal markdown in the expected PR title.
  grep -Fq 'pr edit 42 --title feat: `node-secrets` 22.22.1 --body-file' "$log"
  if grep -Fq 'commit -m' "$log"; then
    printf 'Publisher unexpectedly committed during a refresh.\n' >&2
    return 1
  fi
  if grep -Fq 'push --force-with-lease' "$log"; then
    printf 'Publisher unexpectedly pushed during a refresh.\n' >&2
    return 1
  fi
  worktree="$(<"$tmp/refresh-worktree")"
  [[ ! -e "$worktree" ]]

  : >"$log"
  cat >"$tmp/cp" <<'SH'
#!/usr/bin/env sh
printf 'simulated copy failure\n' >&2
exit 1
SH
  chmod +x "$tmp/cp"
  # shellcheck disable=SC2016 # The child Bash process expands its positional parameters and environment.
  expect_failure "Publisher copy failure" "simulated copy failure" bash -c '
    cd "$1"
    PATH="$2:$PATH" MOCK_COMMAND_LOG="$3" MOCK_CHANGED_PATH="$4" \
      MOCK_BRANCH=automation/node-secrets-updates MOCK_WORKTREE_PATH="$5" \
      DISCOVERY_REPORT_PATH="$6" "$7" secrets
  ' _ "$tmp/repo" "$tmp" "$log" "$path" "$tmp/failure-worktree" "$report" "$PUBLISHER_SCRIPT"
  grep -Fq 'worktree remove --force' "$log"
  worktree="$(<"$tmp/failure-worktree")"
  [[ ! -e "$worktree" ]]
)

# PATH mutation is isolated to this test subshell.
# shellcheck disable=SC2030,SC2031
run_gate_test() (
  local docker_status="$1" is_draft="$2" expected_text="$3" expected_ready_args="$4"
  local tmp output

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  printf 'Existing body\n' >"$tmp/pr-body.md"
  cat >"$tmp/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
log="${MOCK_GH_LOG:?}"; body_file="${MOCK_PR_BODY_FILE:?}"
body="$(jq -Rs . <"$body_file")"
pr="{\"number\":42,\"url\":\"https://example.test/pr/42\",\"isDraft\":${MOCK_PR_IS_DRAFT:?},\"body\":$body,\"headRefOid\":\"raw-content-sha\"}"
case "$1 $2" in
  "auth status") ;;
  "pr list") printf '%s\n' "$pr" ;;
  "pr view")
    if [[ " $* " == *" --json files "* ]]; then printf 'node/security/24\n'; else printf '%s\n' "$pr"; fi
    ;;
  "repo view") printf 'studiondev/pipeline-images\n' ;;
  "api -H") printf 'NODE_VERSION=24.14.0\nSEMGREP_VERSION=1.51.0\n' ;;
  "pr edit")
    [[ "$3" == 42 && "$4" == --body ]]
    printf '%s' "$5" >"$body_file"
    printf '%s\n' "$*" >>"$log"
    ;;
  "pr ready") printf '%s\n' "$*" >>"$log" ;;
  *) printf 'unexpected gh args: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  cat >"$tmp/curl" <<'SH'
#!/usr/bin/env sh
printf '%s' "${MOCK_DOCKER_STATUS:?}"
SH
  chmod +x "$tmp/gh" "$tmp/curl"

  run_gate() (
    cd "$REPO_ROOT"
    PATH="$tmp:$PATH" MOCK_GH_LOG="$tmp/gh.log" MOCK_PR_BODY_FILE="$tmp/pr-body.md" \
      MOCK_PR_IS_DRAFT="$is_draft" MOCK_DOCKER_STATUS="$docker_status" \
      "$SCRIPT_DIR/update-security-pr-gate.sh"
  )

  if [[ "$expected_text" == error ]]; then
    expect_failure "Gate error response" "Docker tag check failed (500)" run_gate
    return
  fi

  output="$(run_gate)"
  [[ "$output" == "Security dependency gate: $expected_text." ]]
  output="$(run_gate)"
  [[ "$output" == "Security dependency gate: $expected_text." ]]
  grep -Fqx "$expected_ready_args" "$tmp/gh.log"
  [[ "$(grep -Fxc '<!-- node-security-dependency-gate:start -->' "$tmp/pr-body.md")" == 1 ]]
  [[ "$(grep -Fxc '<!-- node-security-dependency-gate:end -->' "$tmp/pr-body.md")" == 1 ]]
  grep -Fqx 'Existing body' "$tmp/pr-body.md"
)

run_cli_diagnostic_test() {
  expect_failure "Discovery without arguments" "'--apply' or '--dry-run'" "$DISCOVERY_SCRIPT"
}

main() {
  run_static_checks
  with_discovery_fixture test_discovery_dry_run_and_apply
  with_discovery_fixture test_discovery_write_failure
  test_discovery_configuration
  run_cli_diagnostic_test
  run_publisher_configuration_and_noop_tests
  run_publisher_tests
  run_gate_test 200 true ready 'pr ready 42'
  run_gate_test 404 false blocked 'pr ready 42 --undo'
  run_gate_test 500 true error ''
  printf 'Update automation validation passed.\n'
}

main "$@"
