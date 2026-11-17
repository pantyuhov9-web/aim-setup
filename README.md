# aim-setup

A setup check for students of A&I Mastery courses that are built on Claude Code.
It answers one question: do Claude Code, Git-to-GitHub sync and Python scripts work on this computer?

## Run it

macOS, in Terminal:

    curl -fsSL https://raw.githubusercontent.com/pantyuhov9-web/aim-setup/main/check.sh | bash

Windows: in preparation.

The check is read-only. It installs nothing and leaves nothing behind. It prints what works,
what is missing, and the command that fixes each missing piece. The report is in Ukrainian.

| Switch | Effect |
|---|---|
| `--json` | Also prints the records as JSON between `=== aim-check json ===` and `=== end json ===` |
| `--push-test` | Creates or reuses a private repo `aim-setup-check` in your GitHub account and pushes one file to it. This is the only step that writes anywhere. |

Pass a switch through the pipe like this:

    curl -fsSL https://raw.githubusercontent.com/pantyuhov9-web/aim-setup/main/check.sh | bash -s -- --push-test

When Claude Code runs the check, the report also carries the JSON block and a short procedure
that tells Claude how to fix what failed. The checker knows Claude is running it because
Claude Code sets `CLAUDECODE=1` for the commands it starts.

## What it checks

| Id | Check |
|---|---|
| S1 | macOS 13 or later |
| S2 | Processor (information only) |
| S3 | 4 GB of memory or more |
| S5 | github.com, pypi.org and claude.ai answer |
| C1 | Claude Code is present: the terminal version, the desktop app or the VS Code extension |
| C2 | The `claude` command is found in the terminal |
| C3 | The terminal version is signed in |
| G1 | Git runs |
| G3 | Git has a name and an e-mail |
| G4 | GitHub CLI runs |
| G5 | GitHub CLI is signed in |
| G6 | Git uses that sign-in |
| G7 | A real push to GitHub works (only with `--push-test`) |
| P1 | Python runs |
| P2 | Python is 3.10 or later |
| P3 | A package installs into a fresh virtual environment |
| P4 | A script prints Ukrainian text and opens an HTTPS page |

The ids S4, S6, C4 and G2 belong to the Windows checker.

## The contract

Every check produces one record:

    {"id", "status", "group", "title", "evidence", "why", "fix": [{"cmd", "needs"}]}

- `status` is `pass`, `warn`, `fail`, `info` or `skip`. Only `fail` makes the check exit with code 1.
- `group` is `system`, `claude`, `github` or `python`.
- `needs` is empty, or one of `click`, `browser`, `new-window`, `restart-app`: what the person
  has to do around that command.
- In the printed report the marks are `[OK]` pass, `[!!]` fail, `[! ]` warn, `[i]` info, `[--]` skip.

## What it never does

- It never prints a token, an e-mail address or your user name.
- It never reads a stored credential. It looks at the names of Git's credential helpers only.
- It never installs anything. Fix commands are printed for you, or for Claude, to run.

## Develop

    /bin/bash tests/run.sh

The tests are hermetic: every external command is a stub, so they need no network and no
GitHub account. The checker must keep running on `/bin/bash` 3.2, the bash that ships with macOS.
