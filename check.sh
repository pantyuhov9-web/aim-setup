#!/bin/bash
# aim-setup: setup check for macOS, for students of A&I Mastery courses built on Claude Code.
# It answers one question: do Claude Code, Git-to-GitHub sync and Python scripts work here?
#
# Run:       curl -fsSL https://raw.githubusercontent.com/pantyuhov9-web/aim-setup/main/check.sh | bash
# Switches:  --json        also print the records as JSON
#            --push-test   create or reuse a private repo "aim-setup-check" and push to it
#
# Read-only: it installs nothing and leaves nothing behind. --push-test is the one exception.
# Runs on /bin/bash 3.2 (the bash that "curl | bash" reaches on macOS): no associative arrays.
# Everything is a function and the last line calls main, so a partial download runs nothing.
# Commands that may read standard input get </dev/null, so none can swallow a piped script.
# Test hooks (tests/run.sh only): AIM_SHIM_DIR, AIM_APPS_DIR, AIM_CHECK_LIB, AIM_PIP_TIMEOUT.

# The address moves to https://ai-mastery.xyz once that site redirects to this repo.
BASE_URL='https://raw.githubusercontent.com/pantyuhov9-web/aim-setup/main'
RUN_CMD="curl -fsSL $BASE_URL/check.sh | bash"
PUSH_CMD="curl -fsSL $BASE_URL/check.sh | bash -s -- --push-test"
TAB="$(printf '\t')"
NL='
'
N=0

# ---- records ---------------------------------------------------------------------------

rec() { # id group title status evidence [why] [fix]   fix = lines of "flag<TAB>command"
  R_ID[N]="$1"; R_GROUP[N]="$2"; R_TITLE[N]="$3"; R_STATUS[N]="$4"
  R_EVID[N]="$5"; R_WHY[N]="${6:-}"; R_FIX[N]="${7:-}"
  N=$((N + 1))
}

status_of() { # id -> its status, or nothing when the check has not run
  local i=0
  while [ "$i" -lt "$N" ]; do
    if [ "${R_ID[$i]}" = "$1" ]; then printf '%s' "${R_STATUS[$i]}"; return 0; fi
    i=$((i + 1))
  done
}

passed() { [ "$(status_of "$1")" = pass ]; }

# ---- helpers ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

with_timeout() { # seconds command...   macOS ships no "timeout" command
  local secs="$1" pid killer rc
  shift
  "$@" </dev/null &
  pid=$!
  # The watcher wakes every second, so it ends within a second of the command ending
  # and never outlives the check as a long sleep.
  (
    t=0
    while [ "$t" -lt "$secs" ]; do
      sleep 1
      kill -0 "$pid" 2>/dev/null || exit 0
      t=$((t + 1))
    done
    kill -TERM "$pid" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  killer=$!
  # The group redirect keeps bash's "Terminated" job notices out of the student's terminal.
  { wait "$pid"; rc=$?; kill -TERM "$killer" && wait "$killer"; } 2>/dev/null
  return "$rc"
}

digits() { # keep the leading digits of a version part: "14rc1" -> 14, "" -> 0
  local d
  d="$(printf '%s' "$1" | sed 's/[^0-9].*//')"
  printf '%s' "${d:-0}"
}

ver_ge() { # "3.12.1" "3.10" -> success when the first is at least the second (major.minor)
  local a1 a2 b1 b2 rest
  a1="$(digits "${1%%.*}")"; rest="${1#*.}"; a2="$(digits "${rest%%.*}")"
  b1="$(digits "${2%%.*}")"; rest="${2#*.}"; b2="$(digits "${rest%%.*}")"
  [ "$a1" -gt "$b1" ] && return 0
  [ "$a1" -eq "$b1" ] && [ "$a2" -ge "$b2" ] && return 0
  return 1
}

tilde() { # replace the home folder with ~ so a report never carries the user name
  case "$1" in
    "$HOME"/*) printf '%s' "~${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

json_esc() { # escape backslash and double quote; the strings here hold no control characters
  local s="$1" bs="\\" q='"'
  s=${s//"$bs"/$bs$bs}
  s=${s//"$q"/$bs$q}
  printf '%s' "$s"
}

# ---- report ----------------------------------------------------------------------------

mark() {
  case "$1" in
    pass) printf '[OK]' ;;
    fail) printf '[!!]' ;;
    warn) printf '[! ]' ;;
    info) printf '[i] ' ;;
    *) printf '[--]' ;;
  esac
}

flag_note() {
  case "$1" in
    click) printf '%s' "   (натисніть «Так» або «Встановити», коли система запитає)" ;;
    browser) printf '%s' "   (відкриється браузер)" ;;
    new-window) printf '%s' "   (після цього відкрийте нове вікно термінала)" ;;
    restart-app) printf '%s' "   (після цього перезапустіть Claude)" ;;
  esac
}

group_name() {
  case "$1" in
    system) printf '%s' "система" ;;
    claude) printf '%s' "Claude Code" ;;
    github) printf '%s' "GitHub" ;;
    *) printf '%s' "Python" ;;
  esac
}

print_report() {
  local i missing="" warns=0 g step=0 flag cmd how="запуск із термінала"
  [ "$DRIVER" = claude ] && how="запуск через Claude"
  printf '%s\n\n' "Перевірка компʼютера для курсу A&I Mastery (macOS, $how)"
  i=0
  while [ "$i" -lt "$N" ]; do
    printf '%s  %s: %s\n' "$(mark "${R_STATUS[$i]}")" "${R_TITLE[$i]}" "${R_EVID[$i]}"
    if [ "${R_STATUS[$i]}" = fail ]; then
      g="$(group_name "${R_GROUP[$i]}")"
      case ", $missing," in *", $g,"*) ;; *) missing="${missing:+$missing, }$g" ;; esac
    fi
    [ "${R_STATUS[$i]}" = warn ] && warns=$((warns + 1))
    i=$((i + 1))
  done

  printf '\n'
  if [ -n "$missing" ]; then
    printf '%s\n' "Не вистачає: $missing."
  elif [ "$warns" -gt 0 ]; then
    printf '%s\n' "Головне працює. Є зауваження, вони позначені [! ]."
  else
    printf '%s\n' "Усе потрібне працює."
  fi

  i=0
  while [ "$i" -lt "$N" ]; do
    if { [ "${R_STATUS[$i]}" = fail ] || [ "${R_STATUS[$i]}" = warn ]; } && [ -n "${R_WHY[$i]}" ]; then
      [ "$step" -eq 0 ] && printf '\n%s\n' "Як виправити (по одній команді, у цьому ж вікні):"
      step=$((step + 1))
      printf '\n%s. %s. %s\n' "$step" "${R_TITLE[$i]}" "${R_WHY[$i]}"
      if [ -n "${R_FIX[$i]}" ]; then
        while IFS="$TAB" read -r flag cmd; do
          [ -n "$cmd" ] || continue
          printf '   %s\n' "$cmd"
          [ "$flag" = "-" ] || printf '%s\n' "$(flag_note "$flag")"
        done <<EOF
${R_FIX[$i]}
EOF
      fi
    fi
    i=$((i + 1))
  done

  if [ "$step" -gt 0 ]; then
    printf '\n%s\n   %s\n' "Після виправлень запустіть перевірку ще раз:" "$RUN_CMD"
  fi

  printf '\n%s\n' "----- звіт для куратора -----"
  printf '%s\n' "aim-check macos $(date -u '+%Y-%m-%d' </dev/null) driver=$DRIVER"
  i=0
  while [ "$i" -lt "$N" ]; do
    printf '%s %s %s\n' "${R_ID[$i]}" "${R_STATUS[$i]}" "${R_EVID[$i]}"
    i=$((i + 1))
  done
  printf '%s\n' "----- кінець звіту -----"
}

print_json() {
  local i flag cmd first sep
  printf '\n%s\n[\n' "=== aim-check json ==="
  i=0
  while [ "$i" -lt "$N" ]; do
    printf '{"id":"%s","status":"%s","group":"%s","title":"%s","evidence":"%s","why":"%s","fix":[' \
      "${R_ID[$i]}" "${R_STATUS[$i]}" "${R_GROUP[$i]}" "$(json_esc "${R_TITLE[$i]}")" \
      "$(json_esc "${R_EVID[$i]}")" "$(json_esc "${R_WHY[$i]}")"
    first=1
    if [ -n "${R_FIX[$i]}" ]; then
      while IFS="$TAB" read -r flag cmd; do
        [ -n "$cmd" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        [ "$flag" = "-" ] && flag=""
        printf '{"cmd":"%s","needs":"%s"}' "$(json_esc "$cmd")" "$flag"
      done <<EOF
${R_FIX[$i]}
EOF
    fi
    sep=","
    [ "$i" -eq $((N - 1)) ] && sep=""
    printf ']}%s\n' "$sep"
    i=$((i + 1))
  done
  printf ']\n%s\n' "=== end json ==="
}

print_procedure() {
  cat <<EOF

=== порядок дій для Claude ===
1. Розкажи учневі простими словами, що працює і чого не вистачає.
2. Виправляй по одному, згори донизу: спершу пункти зі статусом fail, потім пункти warn, для яких є команда. Бери тільки команди з розділу «Як виправити». Перед кожною командою поясни одним реченням, що вона зробить.
3. Імʼя, пошту, натискання кнопок і вхід у браузері питай в учня. Не вигадуй їх.
4. Якщо команда не спрацювала двічі, зупинись і покажи учневі блок «звіт для куратора». Інших способів встановлення не шукай.
5. Після виправлень попроси учня закрити й знову відкрити програму або термінал і вставити той самий запит ще раз.
6. Коли жоден пункт не має статусу fail, запитай дозволу на пробну відправку і запусти: $PUSH_CMD
7. Якщо пробна відправка не пройшла, виконай команду з її пункту і запусти відправку ще раз.
8. Заверши одним реченням з підсумком.
=== кінець ===
EOF
}

# ---- main ------------------------------------------------------------------------------

main() {
  local a f i rc=0
  SHIM_DIR="${AIM_SHIM_DIR:-/usr/bin}"
  APPS_DIR="${AIM_APPS_DIR:-/Applications}"
  WANT_JSON=0; PUSH_TEST=0; DRIVER=terminal; NET_OK=1; CLT=0
  for a in "$@"; do
    case "$a" in
      --json) WANT_JSON=1 ;;
      --push-test) PUSH_TEST=1 ;;
    esac
  done
  if [ "${CLAUDECODE:-}" = "1" ]; then DRIVER=claude; WANT_JSON=1; fi

  TMP="$(mktemp -d 2>/dev/null </dev/null || mktemp -d -t aimcheck </dev/null)"
  trap 'rm -rf "$TMP"' EXIT

  # Each group of checks is one function; a group that is not defined is not run.
  for f in check_system check_claude check_git check_python; do
    if declare -F "$f" >/dev/null; then "$f"; fi
  done

  print_report
  [ "$WANT_JSON" -eq 1 ] && print_json
  [ "$DRIVER" = claude ] && print_procedure

  i=0
  while [ "$i" -lt "$N" ]; do
    [ "${R_STATUS[$i]}" = fail ] && rc=1
    i=$((i + 1))
  done
  return "$rc"
}

# AIM_CHECK_LIB=1 lets tests/run.sh load the functions without running the check.
[ "${AIM_CHECK_LIB:-}" = 1 ] || { main "$@"; exit $?; }
