#!/bin/bash
# aim-setup: setup check for macOS, for students of A&I Mastery courses built on Claude Code.
# It answers one question: do Claude Code, Git-to-GitHub sync and Python scripts work here?
#
# Run:       curl -fsSL https://ai-mastery.xyz/check.sh | bash
# Switches:  --json        also print the records as JSON
#            --push-test   create or reuse a private repo "aim-setup-check" and push to it
#
# Read-only: it installs nothing and leaves nothing behind. --push-test is the one exception.
# Runs on /bin/bash 3.2 (the bash that "curl | bash" reaches on macOS): no associative arrays.
# Everything is a function and the last line calls main, so a partial download runs nothing.
# Commands that may read standard input get </dev/null, so none can swallow a piped script.
# Test hooks (tests/run.sh only): AIM_SHIM_DIR, AIM_APPS_DIR, AIM_CHECK_LIB, AIM_PIP_TIMEOUT.

# ai-mastery.xyz answers each address with a redirect to the same file on the main branch of
# pantyuhov9-web/aim-setup, so the repo can move without changing the command a student pastes.
BASE_URL='https://ai-mastery.xyz'
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

settle() { # id evidence -> a later check proved this one: it becomes a pass with no fix
  local i=0
  while [ "$i" -lt "$N" ]; do
    if [ "${R_ID[$i]}" = "$1" ]; then
      R_STATUS[i]=pass; R_EVID[i]="$2"; R_WHY[i]=""; R_FIX[i]=""
      return 0
    fi
    i=$((i + 1))
  done
}

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

# ---- system ----------------------------------------------------------------------------

check_system() {
  local v major arch mem gb bad body region
  v="$(sw_vers -productVersion 2>/dev/null </dev/null)"
  major="$(digits "${v%%.*}")"
  if [ "$major" -ge 13 ]; then
    rec S1 system "Версія macOS" pass "macOS $v"
  else
    rec S1 system "Версія macOS" fail "macOS ${v:-невідома}, потрібна 13 або новіша" \
      "Claude Code працює на macOS 13 і новіших. Оновіть систему: меню Apple, «Системні параметри», «Оновлення ПЗ»."
  fi

  arch="$(uname -m 2>/dev/null)"
  rec S2 system "Процесор" info "${arch:-невідомий}"

  mem="$(digits "$(sysctl -n hw.memsize 2>/dev/null </dev/null)")"
  gb=$((mem / 1073741824))
  if [ "$mem" -ge 4294967296 ]; then
    rec S3 system "Оперативна памʼять" pass "$gb ГБ"
  else
    rec S3 system "Оперативна памʼять" warn "$gb ГБ, Claude Code потребує щонайменше 4 ГБ" \
      "На цьому компʼютері Claude Code працюватиме повільно."
  fi

  bad=""; region=0; NET_OK=1
  curl -fsS -o /dev/null --max-time 10 https://github.com </dev/null 2>/dev/null || bad="$bad github.com"
  curl -fsS -o /dev/null --max-time 10 https://pypi.org </dev/null 2>/dev/null || bad="$bad pypi.org"
  body="$(curl -fsSL --max-time 10 https://claude.ai/install.sh </dev/null 2>/dev/null | head -c 4000)"
  if [ -z "$body" ]; then
    bad="$bad claude.ai"
  elif printf '%s' "$body" | grep -q "App unavailable in region"; then
    region=1
  fi
  if [ "$region" -eq 1 ]; then
    rec S5 system "Інтернет" warn "claude.ai відповідає, що сервіс недоступний у цій країні" \
      "Claude не працює в цій країні або через цей VPN. Вимкніть VPN чи змініть у ньому країну і запустіть перевірку ще раз."
  elif [ -n "$bad" ]; then
    NET_OK=0
    rec S5 system "Інтернет" warn "немає відповіді від:$bad" \
      "Перевірте підключення до інтернету і запустіть перевірку ще раз."
  else
    rec S5 system "Інтернет" pass "github.com, pypi.org і claude.ai відповідають"
  fi
}

# ---- Claude Code -----------------------------------------------------------------------

check_claude() {
  local cli_cmd=0 cli_file=0 found="" ver
  have claude && cli_cmd=1
  if [ -e "$HOME/.local/bin/claude" ] || [ -L "$HOME/.local/bin/claude" ]; then cli_file=1; fi

  if [ "$DRIVER" = claude ]; then
    rec C1 claude "Claude Code" pass "працює (${CLAUDE_CODE_ENTRYPOINT:-claude})"
  else
    if [ "$cli_cmd" -eq 1 ] || [ "$cli_file" -eq 1 ]; then found="термінал"; fi
    if [ -d "$APPS_DIR/Claude.app" ] || [ -d "$HOME/Applications/Claude.app" ]; then
      found="${found:+$found, }застосунок"
    fi
    if ls -d "$HOME"/.vscode/extensions/anthropic.claude-code-* >/dev/null 2>&1; then
      found="${found:+$found, }VS Code"
    fi
    if [ -n "$found" ]; then
      rec C1 claude "Claude Code" pass "знайдено: $found"
    else
      rec C1 claude "Claude Code" fail "не знайдено" \
        "Встановіть Claude Code за кроком 0 з інструкції. Для термінала вставте цю команду." \
        "new-window${TAB}curl -fsSL https://claude.ai/install.sh | bash"
    fi
  fi

  if [ "$cli_cmd" -eq 1 ]; then
    ver="$(with_timeout 10 claude --version 2>/dev/null | head -1)"
    rec C2 claude "Команда claude в терміналі" pass "${ver:-знайдено}"
    if with_timeout 15 claude auth status >/dev/null 2>&1; then
      rec C3 claude "Вхід у Claude з термінала" pass "вхід виконано"
    else
      rec C3 claude "Вхід у Claude з термінала" warn "вхід не виконано" \
        "Наберіть claude у терміналі та увійдіть у свій обліковий запис у браузері." \
        "browser${TAB}claude"
    fi
  elif [ "$cli_file" -eq 1 ]; then
    rec C2 claude "Команда claude в терміналі" fail "Claude встановлено, але термінал не бачить команду" \
      "Термінал шукає програми у списку папок PATH. Команда додає туди папку з Claude." \
      "new-window${TAB}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    rec C3 claude "Вхід у Claude з термінала" skip "спершу потрібна команда claude"
  else
    rec C2 claude "Команда claude в терміналі" info "термінальну версію не встановлено; для застосунку і VS Code вона не потрібна"
    rec C3 claude "Вхід у Claude з термінала" info "без термінальної версії не перевіряється"
  fi
}

# ---- Git and GitHub --------------------------------------------------------------------

push_test() { # prints the repo name on success, a reason on failure; returns 2 when Git got no sign-in
  local login repo dir head remote
  # With no stored sign-in Git would print "Username for 'https://github.com':" in the
  # student's terminal, or open an editor's pop-up, and wait. These two settings make it
  # fail at once instead. push_test runs inside $(...), so the export ends with it.
  export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=
  login="$(with_timeout 20 gh api user -q .login 2>/dev/null)"
  [ -n "$login" ] || { printf '%s' "не вдалося дізнатися обліковий запис GitHub"; return 1; }
  repo="$login/aim-setup-check"
  if ! with_timeout 20 gh repo view "$repo" >/dev/null 2>&1; then
    with_timeout 30 gh repo create aim-setup-check --private \
      -d "Setup check for an A&I Mastery course. Safe to delete." >/dev/null 2>&1 \
      || { printf '%s' "не вдалося створити сховище aim-setup-check"; return 1; }
  fi
  dir="$TMP/push"
  # The repo is private, so the clone already needs Git's sign-in: a Mac where Git has
  # none stops here, not at the push.
  with_timeout 60 git clone -q "https://github.com/$repo.git" "$dir" >/dev/null 2>&1 \
    || { printf '%s' "не вдалося отримати сховище з GitHub"; return 2; }
  # The scratch commit needs no signature, and a signing setup could stop to ask for a passphrase.
  ( cd "$dir" && git checkout -q -B main </dev/null \
      && date -u '+%Y-%m-%dT%H:%M:%SZ' > check.txt \
      && git add check.txt </dev/null \
      && git -c commit.gpgsign=false commit -q -m "setup check" </dev/null ) >/dev/null 2>&1 \
    || { printf '%s' "не вдалося зберегти зміну"; return 1; }
  ( cd "$dir" && with_timeout 60 git push -q -u origin main ) >/dev/null 2>&1 \
    || { printf '%s' "GitHub не прийняв відправку"; return 2; }
  head="$(cd "$dir" && git rev-parse HEAD 2>/dev/null </dev/null)"
  remote="$(cd "$dir" && with_timeout 30 git ls-remote origin refs/heads/main 2>/dev/null | cut -f1)"
  [ -n "$head" ] && [ "$head" = "$remote" ] \
    || { printf '%s' "GitHub не показує відправлену зміну"; return 1; }
  printf '%s' "aim-setup-check"
}

check_git() {
  local gitp ver name email helper other fix out why
  local sample_name="Імʼя Прізвище" sample_email="you@example.com"
  CLT=0
  xcode-select -p >/dev/null 2>&1 </dev/null && CLT=1

  gitp="$(command -v git 2>/dev/null)"
  if [ -z "$gitp" ] || { [ "$gitp" = "$SHIM_DIR/git" ] && [ "$CLT" -eq 0 ]; }; then
    rec G1 github "Git" fail "не встановлено" \
      "Git на Mac входить до інструментів Apple. Команда відкриє вікно встановлення: натисніть «Встановити» і дочекайтеся завершення." \
      "click${TAB}xcode-select --install"
  else
    ver="$(git --version 2>/dev/null </dev/null | sed 's/^git version //')"
    rec G1 github "Git" pass "${ver:-знайдено}"
  fi

  if passed G1; then
    name="$(git config --global user.name 2>/dev/null </dev/null)"
    email="$(git config --global user.email 2>/dev/null </dev/null)"
    why="Git підписує кожне збереження іменем і поштою. Підставте в лапках свої; пошта та сама, що в обліковому записі GitHub."
    fix="-${TAB}git config --global user.name \"$sample_name\"${NL}-${TAB}git config --global user.email \"$sample_email\""
    if [ -z "$name" ] || [ -z "$email" ]; then
      rec G3 github "Імʼя та пошта в Git" fail "не вказано" "$why" "$fix"
    elif [ "$name" = "$sample_name" ] || [ "$email" = "$sample_email" ]; then
      # The two commands above were pasted without putting real values into the quotes.
      rec G3 github "Імʼя та пошта в Git" fail "вказано зразок з підказки, а не ваші дані" "$why" "$fix"
    else
      rec G3 github "Імʼя та пошта в Git" pass "вказано"
    fi
  else
    rec G3 github "Імʼя та пошта в Git" skip "спершу потрібен Git"
  fi

  if have gh; then
    ver="$(gh --version 2>/dev/null </dev/null | head -1 | sed -e 's/^gh version //' -e 's/ .*//')"
    rec G4 github "GitHub CLI" pass "${ver:-знайдено}"
  else
    if have brew; then
      fix="new-window${TAB}brew install gh"
    else
      fix="-${TAB}V=\$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest | sed 's#.*/v##'); A=\$(uname -m | sed 's/x86_64/amd64/'); curl -fsSL \"https://github.com/cli/cli/releases/download/v\$V/gh_\${V}_macOS_\$A.zip\" -o /tmp/gh.zip && unzip -qo /tmp/gh.zip -d /tmp/gh-unzip && mkdir -p ~/.local/bin && cp \"/tmp/gh-unzip/gh_\${V}_macOS_\$A/bin/gh\" ~/.local/bin/gh${NL}new-window${TAB}grep -q '.local/bin' ~/.zshrc 2>/dev/null || echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    fi
    rec G4 github "GitHub CLI" fail "не встановлено" \
      "GitHub CLI виконує вхід у GitHub через браузер, а Git потім користується цим входом." "$fix"
  fi

  if ! passed G4; then
    rec G5 github "Вхід у GitHub" skip "спершу потрібен GitHub CLI"
  elif [ "$NET_OK" -eq 0 ]; then
    rec G5 github "Вхід у GitHub" skip "потрібен інтернет"
  elif with_timeout 20 gh auth status >/dev/null 2>&1; then
    rec G5 github "Вхід у GitHub" pass "вхід виконано"
  else
    # Started by Claude, "gh auth login" has no terminal to ask in, so it signs in and leaves
    # Git unconnected. The second command connects Git in the same round.
    rec G5 github "Вхід у GitHub" fail "вхід не виконано" \
      "Перша команда покаже одноразовий код і відкриє GitHub у браузері: введіть код і підтвердьте вхід. Друга дозволить Git користуватися цим входом." \
      "browser${TAB}gh auth login --web --git-protocol https${NL}-${TAB}gh auth setup-git"
  fi

  # The check reads helper names only, never a stored credential. It cannot see whether a
  # helper other than GitHub CLI holds a GitHub sign-in, so that case is a warning and the
  # push test decides.
  if passed G1 && passed G5; then
    helper="$(cd "$TMP" && git config --get-all credential.https://github.com.helper 2>/dev/null </dev/null)"
    other="$(cd "$TMP" && git config --get-all credential.helper 2>/dev/null </dev/null | head -1)"
    case "$helper" in
      *"gh auth git-credential"*)
        rec G6 github "Git користується входом у GitHub" pass "через GitHub CLI" ;;
      *)
        if [ -n "$other" ]; then
          rec G6 github "Git користується входом у GitHub" warn \
            "Git має інший спосіб входу ($(tilde "$other")); перевірка не бачить, чи збережено в ньому вхід у GitHub" \
            "Якщо відправка на GitHub не спрацює, ця команда перемкне Git на вхід через GitHub CLI." \
            "-${TAB}gh auth setup-git"
        else
          rec G6 github "Git користується входом у GitHub" fail "не налаштовано" \
            "Після цієї команди Git відправляє зміни на GitHub без пароля." \
            "-${TAB}gh auth setup-git"
        fi ;;
    esac
  else
    rec G6 github "Git користується входом у GitHub" skip "спершу потрібні Git і вхід у GitHub"
  fi

  if [ "$PUSH_TEST" -eq 0 ]; then
    rec G7 github "Пробна відправка на GitHub" skip "вимкнено; вмикається ключем --push-test"
  elif passed G3 && passed G5 && [ "$(status_of G6)" != fail ]; then
    out="$(push_test)"
    case $? in
      0)
        rec G7 github "Пробна відправка на GitHub" pass "зміну відправлено у приватне сховище $out"
        # A push that went through proves the sign-in route that G6 could not see into.
        if [ "$(status_of G6)" = warn ]; then
          settle G6 "працює через $(tilde "$other"); пробна відправка це підтвердила"
        fi ;;
      2)
        rec G7 github "Пробна відправка на GitHub" fail "$out" \
          "Команда перемикає Git на вхід через GitHub CLI. Після неї запустіть перевірку з пробною відправкою ще раз." \
          "-${TAB}gh auth setup-git" ;;
      *)
        rec G7 github "Пробна відправка на GitHub" fail "$out" \
          "Запустіть перевірку ще раз. Якщо помилка повторюється, надішліть звіт кураторові." ;;
    esac
  else
    rec G7 github "Пробна відправка на GitHub" skip "спершу виправте пункти вище"
  fi
}

# ---- Python ----------------------------------------------------------------------------

skip_python_rest() { # reason, then the ids to skip
  local reason="$1" id title
  shift
  for id in "$@"; do
    case "$id" in
      P2) title="Версія Python" ;;
      P3) title="Встановлення бібліотек" ;;
      *) title="Запуск скрипта" ;;
    esac
    rec "$id" python "$title" skip "$reason"
  done
}

check_python() {
  local pyp ver fix venv out rc
  if have brew; then
    fix="new-window${TAB}brew install python"
  else
    fix="-${TAB}curl -LsSf https://astral.sh/uv/install.sh | sh${NL}new-window${TAB}~/.local/bin/uv python install --default"
  fi

  pyp="$(command -v python3 2>/dev/null)"
  if [ -z "$pyp" ] || { [ "$pyp" = "$SHIM_DIR/python3" ] && [ "$CLT" -eq 0 ]; }; then
    rec P1 python "Python" fail "не встановлено" "Python запускає скрипти з уроків." "$fix"
    skip_python_rest "спершу потрібен Python" P2 P3 P4
    return 0
  fi
  ver="$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null </dev/null)"
  if [ -z "$ver" ]; then
    rec P1 python "Python" fail "знайдено, але не запускається" "Python запускає скрипти з уроків." "$fix"
    skip_python_rest "спершу потрібен Python" P2 P3 P4
    return 0
  fi
  rec P1 python "Python" pass "$(tilde "$pyp")"

  if ver_ge "$ver" 3.10; then
    rec P2 python "Версія Python" pass "$ver"
  else
    rec P2 python "Версія Python" fail "$ver, потрібна 3.10 або новіша" \
      "Скрипти курсу розраховані на Python 3.10 і новіші." "$fix"
    skip_python_rest "спершу потрібен новіший Python" P3 P4
    return 0
  fi

  if [ "$NET_OK" -eq 0 ]; then
    skip_python_rest "потрібен інтернет" P3 P4
    return 0
  fi
  venv="$TMP/venv"
  if ! python3 -m venv "$venv" >/dev/null 2>&1 </dev/null; then
    rec P3 python "Встановлення бібліотек" fail "не вдалося створити окреме середовище" \
      "Запустіть перевірку ще раз. Якщо помилка повторюється, надішліть звіт кураторові."
    skip_python_rest "спершу мають встановлюватися бібліотеки" P4
    return 0
  fi
  with_timeout "${AIM_PIP_TIMEOUT:-120}" "$venv/bin/python" -m pip install --no-cache-dir --quiet \
    --disable-pip-version-check requests >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rec P3 python "Встановлення бібліотек" pass "бібліотека requests встановилася"
  elif [ "$rc" -eq 143 ]; then
    # 143 = stopped by the timeout: a slow network, not a broken Python.
    rec P3 python "Встановлення бібліотек" warn "встановлення не завершилося за відведений час" \
      "Інтернет працює повільно. Запустіть перевірку ще раз."
    skip_python_rest "спершу мають встановлюватися бібліотеки" P4
    return 0
  else
    rec P3 python "Встановлення бібліотек" fail "бібліотека requests не встановилася" \
      "Запустіть перевірку ще раз. Якщо помилка повторюється, надішліть звіт кураторові."
    skip_python_rest "спершу мають встановлюватися бібліотеки" P4
    return 0
  fi

  cat > "$TMP/t.py" <<'PY'
import requests
print("Привіт від Python")
print("HTTPS", requests.head("https://github.com", timeout=10, allow_redirects=True).status_code)
PY
  out="$(with_timeout 30 "$venv/bin/python" "$TMP/t.py" 2>/dev/null | cat)"
  case "$out" in
    *"Привіт від Python"*"HTTPS 200"*)
      rec P4 python "Запуск скрипта" pass "скрипт надрукував український текст і відкрив сторінку" ;;
    *)
      rec P4 python "Запуск скрипта" fail "скрипт не відпрацював" \
        "Запустіть перевірку ще раз. Якщо помилка повторюється, надішліть звіт кураторові." ;;
  esac
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
  local i missing="" warns=0 unchecked=0 g step=0 flag cmd how="запуск із термінала"
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
    # A check that was skipped proves nothing. The push test left switched off is the one
    # skip that is a choice, not a gap.
    if [ "${R_STATUS[$i]}" = skip ] && { [ "${R_ID[$i]}" != G7 ] || [ "$PUSH_TEST" -eq 1 ]; }; then
      unchecked=$((unchecked + 1))
    fi
    i=$((i + 1))
  done

  printf '\n'
  if [ -n "$missing" ]; then
    printf '%s\n' "Не вистачає: $missing."
  elif [ "$unchecked" -gt 0 ]; then
    printf '%s\n' "Не все вдалося перевірити. Пропущені пункти позначені [--]."
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
2. Виправляй по одному, згори донизу, тільки пункти зі статусом fail. Бери тільки команди з розділу «Як виправити». Перед кожною командою поясни одним реченням, що вона зробить. Пункти warn поясни учневі, їхніх команд не виконуй.
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
