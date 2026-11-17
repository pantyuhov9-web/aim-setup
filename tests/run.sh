#!/bin/bash
# Hermetic tests for check.sh. Every external command the checker calls is a stub in a
# temporary folder and PATH holds only that folder, so the tests never touch the network,
# GitHub, or the real tools of the machine they run on.
#
# Usage: /bin/bash tests/run.sh          exit 0 = every test passed

# The stub bodies are single-quoted on purpose: they must reach the stub files unexpanded.
# shellcheck disable=SC2016

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/check.sh"
PASSED=0
FAILED=0

# Real programs the checker and the stubs need; linked into the stub folder.
BASICS="bash cat grep sed tr head cut sleep date mktemp rm mkdir ls cp chmod dirname touch"

stub() { # name body   -> an executable $BIN/name
  printf '#!/bin/bash\n%s\n' "$2" > "$BIN/$1"
  chmod +x "$BIN/$1"
}

setup() { # a healthy machine: every check passes
  local t
  W="$(mktemp -d)"
  BIN="$W/bin"; HOME_DIR="$W/home/student"; APPS="$W/apps"
  mkdir -p "$BIN" "$HOME_DIR" "$APPS"
  for t in $BASICS; do ln -s "$(command -v "$t")" "$BIN/$t"; done

  stub sw_vers 'echo 15.3'
  stub uname 'echo arm64'
  stub sysctl 'echo 17179869184'
  stub curl 'if [ "${STUB_CURL_RC:-0}" -eq 0 ]; then
  case "$*" in *claude.ai*) echo "#!/bin/bash" ;; esac
fi
exit ${STUB_CURL_RC:-0}'
  stub xcode-select 'exit ${STUB_CLT_RC:-0}'
  stub git 'touch "'"$W"'/git-ran"
printf "%s\n" "$*" >> "'"$W"'/git-calls"
case "$1 $2 $3" in
  "--version "*) echo "git version 2.47.1" ;;
  "config --global user.name") echo "${STUB_GIT_NAME-Olena Test}" ;;
  "config --global user.email") echo "${STUB_GIT_EMAIL-olena@example.com}" ;;
  "config --get-all credential.https://github.com.helper") echo "${STUB_HELPER-!/opt/homebrew/bin/gh auth git-credential}" ;;
  "config --get-all credential.helper") echo "${STUB_ANY_HELPER-osxkeychain}" ;;
  "clone -q "*) printf "%s|%s\n" "${GIT_TERMINAL_PROMPT-unset}" "${GIT_ASKPASS-unset}" > "'"$W"'/git-clone-env"
    [ "${STUB_CLONE_RC:-0}" -eq 0 ] || exit "$STUB_CLONE_RC"
    mkdir -p "$4" ;;
  "push -q "*) exit ${STUB_PUSH_RC:-0} ;;
  "rev-parse HEAD "*) echo abc123 ;;
  "ls-remote origin "*) printf "abc123\trefs/heads/main\n" ;;
esac
exit 0'
  stub gh 'case "$1 $2" in
  "--version "*) echo "gh version 2.104.0 (2026-11-01)" ;;
  "auth status") exit ${STUB_GH_AUTH_RC:-0} ;;
  "api user") echo "student-login" ;;
  "repo view") exit ${STUB_REPO_VIEW_RC:-0} ;;
esac
exit 0'
  stub python3 'case "$1" in
  -c) echo "${STUB_PY_VERSION:-3.12.4}" ;;
  -m) if [ "$2" = venv ]; then mkdir -p "$3/bin"; cp "'"$BIN"'/venvpy" "$3/bin/python"; fi ;;
esac
exit 0'
  stub venvpy 'if [ "$1" = -m ]; then
  if [ "${STUB_PIP_HANGS:-0}" = 1 ]; then sleep 30; fi
  exit ${STUB_PIP_RC:-0}
fi
if [ "${STUB_SCRIPT_BROKEN:-0}" = 1 ]; then echo "UnicodeEncodeError"; exit 1; fi
echo "Привіт від Python"
echo "HTTPS 200"'
  stub claude 'case "$1 $2" in
  "--version "*) echo "2.1.300 (Claude Code)" ;;
  "auth status") exit ${STUB_CLAUDE_AUTH_RC:-0} ;;
esac
exit 0'
}

teardown() { rm -rf "$W"; }

run_check() { # VAR=value ... -- switches...   sets OUT and RC
  local e=() a=() x seen=0
  for x in "$@"; do
    if [ "$x" = "--" ]; then seen=1; continue; fi
    if [ "$seen" -eq 0 ]; then e[${#e[@]}]="$x"; else a[${#a[@]}]="$x"; fi
  done
  OUT="$(env -i PATH="$BIN" HOME="$HOME_DIR" AIM_SHIM_DIR="$W/shim" AIM_APPS_DIR="$APPS" \
    ${e[@]+"${e[@]}"} /bin/bash "$CHECK" ${a[@]+"${a[@]}"} 2>&1)"
  RC=$?
}

ok() { # description command...
  local d="$1"
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n' "$d"
  fi
}

has_status() { printf '%s\n' "$OUT" | grep -q "\"id\":\"$1\",\"status\":\"$2\""; }
contains() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
lacks() { ! contains "$1"; }
rc_is() { [ "$RC" -eq "$1" ]; }

# ---- tests -----------------------------------------------------------------------------

test_report_frame_is_always_printed() {
  setup
  run_check
  ok "frame: heading" contains "Перевірка компʼютера для курсу A&I Mastery"
  ok "frame: support block opens" contains "----- звіт для куратора -----"
  ok "frame: support block closes" contains "----- кінець звіту -----"
  ok "frame: names the system and the driver" contains "aim-check macos"
  teardown
}

test_json_switch_prints_the_block_in_terminal_mode() {
  setup
  run_check -- --json
  ok "json switch: block opens" contains "=== aim-check json ==="
  ok "json switch: block closes" contains "=== end json ==="
  ok "json switch: no procedure outside Claude" lacks "порядок дій для Claude"
  teardown
}

test_terminal_mode_has_no_procedure() {
  setup
  run_check
  ok "terminal mode: says who runs the check" contains "запуск із термінала"
  ok "terminal mode: no JSON block" lacks "=== aim-check json ==="
  ok "terminal mode: no procedure" lacks "порядок дій для Claude"
  teardown
}

test_claude_mode_adds_json_and_procedure() {
  setup
  run_check CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=claude-desktop
  ok "Claude mode: says who runs the check" contains "запуск через Claude"
  ok "Claude mode: JSON block without the switch" contains "=== aim-check json ==="
  ok "Claude mode: procedure printed" contains "=== порядок дій для Claude ==="
  ok "Claude mode: procedure carries the push-test command" contains "bash -s -- --push-test"
  teardown
}

test_timeout_helper_stops_a_hanging_command() {
  local started took
  started="$(date +%s)"
  OUT="$(AIM_CHECK_LIB=1 /bin/bash -c '. "$0"; with_timeout 1 sleep 20; echo "rc=$?"' "$CHECK" 2>&1)"
  took=$(( $(date +%s) - started ))
  ok "timeout: a 20-second command is stopped within 5 seconds" test "$took" -le 5
  ok "timeout: reports a failure code" lacks "rc=0"
  ok "timeout: prints no job notice" lacks "Terminated"
}

test_truncated_download_runs_nothing() {
  setup
  OUT="$(head -c 3000 "$CHECK" | env -i PATH="$BIN" HOME="$HOME_DIR" /bin/bash 2>/dev/null)"
  ok "truncated: prints no report" lacks "Перевірка"
  ok "truncated: ran no git" test ! -e "$W/git-ran"
  teardown
}

test_healthy_system() {
  setup
  run_check -- --json
  ok "system: S1 passes" has_status S1 pass
  ok "system: S2 is info" has_status S2 info
  ok "system: S3 passes" has_status S3 pass
  ok "system: S5 passes" has_status S5 pass
  ok "system: shows the version" contains "macOS 15.3"
  teardown
}

test_old_macos_fails() {
  setup
  stub sw_vers 'echo 12.7.6'
  run_check -- --json
  ok "old macOS: S1 fails" has_status S1 fail
  ok "old macOS: exit code 1" rc_is 1
  ok "old macOS: named as missing" contains "Не вистачає: система."
  teardown
}

test_low_memory_warns_without_failing() {
  setup
  stub sysctl 'echo 2147483648'
  run_check -- --json
  ok "low memory: S3 warns" has_status S3 warn
  ok "low memory: exit code stays 0" rc_is 0
  teardown
}

test_no_network_warns() {
  setup
  run_check STUB_CURL_RC=6 -- --json
  ok "no network: S5 warns" has_status S5 warn
  ok "no network: names the silent hosts" contains "немає відповіді від: github.com pypi.org claude.ai"
  teardown
}

test_unsupported_region_is_named() {
  setup
  stub curl 'case "$*" in *claude.ai*) echo "<html>App unavailable in region</html>" ;; esac
exit 0'
  run_check -- --json
  ok "region: S5 warns" has_status S5 warn
  ok "region: explains the VPN" contains "VPN"
  teardown
}

test_healthy_claude() {
  setup
  run_check -- --json
  ok "claude: C1 passes" has_status C1 pass
  ok "claude: C2 passes" has_status C2 pass
  ok "claude: C3 passes" has_status C3 pass
  teardown
}

test_no_claude_anywhere_fails() {
  setup
  rm "$BIN/claude"
  run_check -- --json
  ok "no Claude: C1 fails" has_status C1 fail
  ok "no Claude: C2 is info" has_status C2 info
  ok "no Claude: prints Anthropic's installer" contains "curl -fsSL https://claude.ai/install.sh | bash"
  teardown
}

test_desktop_app_alone_is_enough() {
  setup
  rm "$BIN/claude"
  mkdir -p "$APPS/Claude.app"
  run_check -- --json
  ok "desktop only: C1 passes" has_status C1 pass
  ok "desktop only: C2 is info, not a failure" has_status C2 info
  ok "desktop only: C3 is info, not a failure" has_status C3 info
  ok "desktop only: exit code 0" rc_is 0
  teardown
}

test_vscode_extension_alone_is_enough() {
  setup
  rm "$BIN/claude"
  mkdir -p "$HOME_DIR/.vscode/extensions/anthropic.claude-code-2.1.300"
  run_check -- --json
  ok "VS Code only: C1 passes" has_status C1 pass
  teardown
}

test_cli_installed_but_not_in_path() {
  setup
  rm "$BIN/claude"
  mkdir -p "$HOME_DIR/.local/bin"
  touch "$HOME_DIR/.local/bin/claude"
  run_check -- --json
  ok "PATH: C2 fails" has_status C2 fail
  ok "PATH: prints the zshrc fix" contains '>> ~/.zshrc'
  ok "PATH: asks for a new window" contains "відкрийте нове вікно термінала"
  teardown
}

test_claude_logged_out_warns() {
  setup
  run_check STUB_CLAUDE_AUTH_RC=1 -- --json
  ok "logged out: C3 warns" has_status C3 warn
  ok "logged out: exit code stays 0" rc_is 0
  teardown
}

test_claude_mode_passes_by_construction() {
  setup
  rm "$BIN/claude"
  run_check CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=claude-desktop
  ok "Claude mode: C1 passes by construction" has_status C1 pass
  ok "Claude mode: names the surface" contains "claude-desktop"
  teardown
}

test_healthy_git() {
  setup
  run_check -- --json
  for id in G1 G3 G4 G5 G6; do
    ok "git: $id passes" has_status "$id" pass
  done
  ok "git: G7 is skipped without the switch" has_status G7 skip
  teardown
}

test_missing_command_line_tools_never_runs_the_shim() {
  setup
  run_check AIM_SHIM_DIR="$BIN" STUB_CLT_RC=2 -- --json
  ok "no CLT: G1 fails" has_status G1 fail
  ok "no CLT: the git shim was never executed" test ! -e "$W/git-ran"
  ok "no CLT: prints the Apple installer" contains "xcode-select --install"
  ok "no CLT: G3 skipped" has_status G3 skip
  ok "no CLT: G6 skipped" has_status G6 skip
  teardown
}

test_git_identity_missing() {
  setup
  run_check STUB_GIT_NAME= -- --json
  ok "identity: G3 fails" has_status G3 fail
  ok "identity: prints the name command" contains 'git config --global user.name'
  ok "identity: prints the e-mail command" contains 'git config --global user.email'
  teardown
}

test_git_identity_left_as_the_sample_fails() {
  # The fix prints a sample name and a sample e-mail. Pasted as they are, they must not pass.
  setup
  run_check "STUB_GIT_NAME=Імʼя Прізвище" -- --json
  ok "sample name: G3 fails" has_status G3 fail
  ok "sample name: says it is the sample" contains "вказано зразок"
  teardown
  setup
  run_check STUB_GIT_EMAIL=you@example.com -- --json
  ok "sample e-mail: G3 fails" has_status G3 fail
  teardown
}

test_gh_missing_uses_homebrew_when_present() {
  setup
  rm "$BIN/gh"
  stub brew 'exit 0'
  run_check -- --json
  ok "gh missing + brew: G4 fails" has_status G4 fail
  ok "gh missing + brew: fix is brew" contains "brew install gh"
  ok "gh missing + brew: G5 skipped" has_status G5 skip
  teardown
}

test_gh_missing_without_homebrew_downloads_the_release() {
  setup
  rm "$BIN/gh"
  run_check -- --json
  ok "gh missing, no brew: fix downloads the release" contains "github.com/cli/cli/releases/latest"
  ok "gh missing, no brew: never installs Homebrew" lacks "Homebrew/install"
  teardown
}

test_gh_logged_out() {
  setup
  run_check STUB_GH_AUTH_RC=1 -- --json
  ok "gh logged out: G5 fails" has_status G5 fail
  ok "gh logged out: prints the browser login" contains "gh auth login --web --git-protocol https"
  ok "gh logged out: the same fix lets Git use that sign-in" contains '{"cmd":"gh auth setup-git","needs":""}'
  ok "gh logged out: G6 skipped" has_status G6 skip
  teardown
}

test_another_sign_in_route_is_a_warning_not_a_failure() {
  setup
  run_check STUB_HELPER= -- --json
  ok "other helper: G6 warns" has_status G6 warn
  ok "other helper: names the helper" contains "osxkeychain"
  ok "other helper: still offers setup-git" contains "gh auth setup-git"
  ok "other helper: exit code stays 0" rc_is 0
  ok "other helper: summary admits a remark" contains "Головне працює. Є зауваження"
  teardown
}

test_no_sign_in_route_at_all_fails() {
  setup
  run_check STUB_HELPER= STUB_ANY_HELPER= -- --json
  ok "no helper: G6 fails" has_status G6 fail
  ok "no helper: prints setup-git" contains "gh auth setup-git"
  ok "no helper: exit code 1" rc_is 1
  teardown
}

test_push_test_passes() {
  setup
  run_check -- --json --push-test
  ok "push test: G7 passes" has_status G7 pass
  ok "push test: exit code 0" rc_is 0
  teardown
}

test_push_test_runs_when_the_helper_is_only_a_warning() {
  setup
  run_check STUB_HELPER= -- --json --push-test
  ok "push with a warning: G7 passes" has_status G7 pass
  teardown
}

test_push_test_reports_a_refused_push() {
  setup
  run_check STUB_PUSH_RC=1 -- --json --push-test
  ok "push refused: G7 fails" has_status G7 fail
  ok "push refused: says so" contains "GitHub не прийняв відправку"
  ok "push refused: the fix switches Git to the GitHub CLI sign-in" contains '{"cmd":"gh auth setup-git","needs":""}'
  teardown
}

test_push_test_offers_the_fix_when_git_cannot_sign_in() {
  # A private repo needs a sign-in already at the clone, so that is where a Mac whose
  # Git has no GitHub sign-in stops.
  setup
  run_check STUB_CLONE_RC=128 -- --json --push-test
  ok "no sign-in at the clone: G7 fails" has_status G7 fail
  ok "no sign-in at the clone: says so" contains "не вдалося отримати сховище з GitHub"
  ok "no sign-in at the clone: the fix switches Git to the GitHub CLI sign-in" contains '{"cmd":"gh auth setup-git","needs":""}'
  teardown
}

test_push_test_never_asks_for_a_user_name() {
  # Without these two settings Git prints "Username for 'https://github.com':" in the
  # student's terminal, or opens an editor's pop-up, and waits.
  setup
  run_check GIT_ASKPASS=/usr/local/bin/some-askpass -- --json --push-test
  ok "no prompts: Git ran with terminal prompts off and no askpass program" test "$(cat "$W/git-clone-env" 2>/dev/null)" = "0|"
  teardown
}

test_push_test_commit_is_never_signed() {
  # A signing setup that asks for a passphrase would stop the check; the scratch commit
  # needs no signature.
  setup
  run_check -- --json --push-test
  ok "scratch commit: signing is switched off" grep -q -- "-c commit.gpgsign=false commit" "$W/git-calls"
  teardown
}

test_no_network_skips_github_sign_in() {
  setup
  run_check STUB_CURL_RC=6 -- --json
  ok "no network: G5 skipped" has_status G5 skip
  ok "no network: G5 says why" contains "потрібен інтернет"
  teardown
}

test_piped_script_is_not_eaten_by_children() {
  setup
  stub git 'cat >/dev/null
case "$1 $2 $3" in "--version "*) echo "git version 2.47.1" ;; esac
exit 0'
  OUT="$(env -i PATH="$BIN" HOME="$HOME_DIR" AIM_SHIM_DIR="$W/shim" AIM_APPS_DIR="$APPS" \
    /bin/bash -s -- --json < "$CHECK" 2>&1)"
  ok "piped: the report still ends with the support block" contains "----- кінець звіту -----"
  teardown
}

test_healthy_python() {
  setup
  run_check -- --json
  for id in P1 P2 P3 P4; do
    ok "python: $id passes" has_status "$id" pass
  done
  teardown
}

test_python_missing() {
  setup
  rm "$BIN/python3"
  run_check -- --json
  ok "no python: P1 fails" has_status P1 fail
  ok "no python: P2 skipped" has_status P2 skip
  ok "no python: P4 skipped" has_status P4 skip
  ok "no python, no brew: fix is uv" contains "astral.sh/uv/install.sh"
  teardown
}

test_python_too_old() {
  setup
  run_check STUB_PY_VERSION=3.9.6 -- --json
  ok "old python: P1 passes" has_status P1 pass
  ok "old python: P2 fails" has_status P2 fail
  ok "old python: P3 skipped" has_status P3 skip
  ok "old python: names the version" contains "3.9.6, потрібна 3.10 або новіша"
  teardown
}

test_pip_install_fails() {
  setup
  run_check STUB_PIP_RC=1 -- --json
  ok "pip: P3 fails" has_status P3 fail
  ok "pip: P4 skipped" has_status P4 skip
  teardown
}

test_slow_network_makes_packages_a_warning() {
  local started took
  setup
  started="$(date +%s)"
  run_check STUB_PIP_HANGS=1 AIM_PIP_TIMEOUT=1 -- --json
  took=$(( $(date +%s) - started ))
  ok "slow network: P3 warns" has_status P3 warn
  ok "slow network: P4 skipped" has_status P4 skip
  ok "slow network: exit code stays 0" rc_is 0
  ok "slow network: the hanging install was stopped" test "$took" -le 15
  teardown
}

test_script_cannot_print_ukrainian() {
  setup
  run_check STUB_SCRIPT_BROKEN=1 -- --json
  ok "script: P4 fails" has_status P4 fail
  teardown
}

test_no_network_skips_python_packages() {
  setup
  run_check STUB_CURL_RC=6 -- --json
  ok "no network: P3 skipped" has_status P3 skip
  ok "no network: P4 skipped" has_status P4 skip
  teardown
}

test_python_shim_counts_as_missing_without_command_line_tools() {
  setup
  run_check AIM_SHIM_DIR="$BIN" STUB_CLT_RC=2 -- --json
  ok "no CLT: the python shim counts as missing" has_status P1 fail
  ok "no CLT: P2 skipped" has_status P2 skip
  teardown
}

test_healthy_machine_passes() {
  setup
  run_check -- --json
  ok "healthy: exit code 0" rc_is 0
  for id in S1 S3 S5 C1 C2 C3 G1 G3 G4 G5 G6 P1 P2 P3 P4; do
    ok "healthy: $id passes" has_status "$id" pass
  done
  ok "healthy: S2 is info" has_status S2 info
  ok "healthy: G7 is skipped without the switch" has_status G7 skip
  ok "healthy: says everything works" contains "Усе потрібне працює."
  ok "healthy: no fix section" lacks "Як виправити"
  ok "healthy: support block present" contains "----- звіт для куратора -----"
  teardown
}

test_report_never_carries_the_user_name() {
  setup
  mkdir -p "$HOME_DIR/.local/bin"
  mv "$BIN/python3" "$HOME_DIR/.local/bin/python3"
  run_check PATH="$BIN:$HOME_DIR/.local/bin" -- --json --push-test
  # shellcheck disable=SC2088  # the report prints a literal tilde
  ok "privacy: python path shown with ~" contains "~/.local/bin/python3"
  ok "privacy: home folder name absent" lacks "student"
  ok "privacy: e-mail absent" lacks "olena@example.com"
  teardown
}

test_json_block_is_one_record_per_line() {
  setup
  run_check STUB_GH_AUTH_RC=1 -- --json
  ok "json: fix carries each command and its flag" contains '"fix":[{"cmd":"gh auth login --web --git-protocol https","needs":"browser"},{"cmd":"gh auth setup-git","needs":""}]'
  ok "json: closes" contains "=== end json ==="
  teardown
}

test_report_carries_no_shell_job_notices() {
  setup
  run_check -- --json
  ok "noise: no 'Terminated' notices from the timeout helper" lacks "Terminated"
  teardown
}

# ---- run every test --------------------------------------------------------------------

for t in $(declare -F | cut -d' ' -f3 | grep '^test_'); do "$t"; done

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
