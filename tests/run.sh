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
case "$1 $2 $3" in
  "--version "*) echo "git version 2.47.1" ;;
  "config --global user.name") echo "${STUB_GIT_NAME-Olena Test}" ;;
  "config --global user.email") echo "${STUB_GIT_EMAIL-olena@example.com}" ;;
  "config --get-all credential.https://github.com.helper") echo "${STUB_HELPER-!/opt/homebrew/bin/gh auth git-credential}" ;;
  "config --get-all credential.helper") echo "${STUB_ANY_HELPER-osxkeychain}" ;;
  "clone -q "*) mkdir -p "$4" ;;
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

# ---- run every test --------------------------------------------------------------------

for t in $(declare -F | cut -d' ' -f3 | grep '^test_'); do "$t"; done

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
