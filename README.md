# aim-setup

A setup check for students of A&I Mastery courses that are built on Claude Code.
It answers one question: do Claude Code, Git-to-GitHub sync and Python scripts work on this computer?

## Run it

macOS, in Terminal:

    curl -fsSL https://ai-mastery.xyz/check.sh | bash

Windows, in the window that Win+R and `cmd` opens (the same line works in PowerShell and in Git Bash):

    powershell -NoProfile -Command "irm https://ai-mastery.xyz/check.ps1 | iex"

Students get one of two guides, both in Ukrainian:

- [guide-simple.uk.md](guide-simple.uk.md), also as [guide-simple.uk.pdf](guide-simple.uk.pdf), is
  the short one: install Claude from its official page, paste one prompt, and Claude walks the
  student through everything that is missing.
- [guide.uk.md](guide.uk.md) is the full one. It installs Claude Code, Git and Python from their
  official pages first, then gives a prompt that asks Claude to check the computer in plain words.
  The checker is its fallback, in two forms: a prompt that has Claude run it, for when the first
  prompt did not work, and the commands above, for a terminal without Claude.

Each address on ai-mastery.xyz answers with a redirect to the same file on the `main` branch of
this repo, so the repo can move without changing a command.

The check is read-only. It installs nothing and leaves nothing behind. It prints what works,
what is missing, and the command that fixes each missing piece. The report is in Ukrainian.

| Switch | macOS | Windows | Effect |
|---|---|---|---|
| JSON | `--json` | `-Json` | Also prints the records as JSON between `=== aim-check json ===` and `=== end json ===` |
| Push test | `--push-test` | `-PushTest` | Creates or reuses a private repo `aim-setup-check` in your GitHub account and pushes one file to it. This is the only step that writes anywhere. |

Pass a switch through the pipe like this:

    curl -fsSL https://ai-mastery.xyz/check.sh | bash -s -- --push-test

    powershell -NoProfile -Command "& ([scriptblock]::Create((irm https://ai-mastery.xyz/check.ps1))) -PushTest"

On Windows the report is written as UTF-8 bytes whenever the output is redirected, because the
console code page of a Ukrainian PC often has no Cyrillic. To capture it to a file, redirect the
process — `powershell -NoProfile -Command "..." > report.txt` — and not a PowerShell pipeline.

`check.ps1` is made to be fetched and run as a string, and it is not a file to run: Windows
PowerShell 5.1 reads a script file without a byte-order mark as the system code page, which
mangles the Ukrainian text in it. The mark is not an option either — it survives the download as
one character and `iex` then fails on the first token. Tooling reads the file as UTF-8 text
instead; `tests\run.ps1` shows both forms.

When Claude Code runs the check, the report also carries the JSON block and a short procedure
that tells Claude how to fix what failed. The checker knows Claude is running it because
Claude Code sets `CLAUDECODE=1` for the commands it starts.

## What it checks

| Id | macOS | Windows |
|---|---|---|
| S1 | macOS 13 or later | Windows build 17763 or later |
| S2 | Processor (information only) | 64-bit Windows and a 64-bit window |
| S3 | 4 GB of memory or more | the same |
| S4 | — | the user folder's name is Latin letters and digits |
| S5 | github.com, pypi.org and claude.ai answer | the same |
| S6 | — | winget is present (information only) |
| C1 | Claude Code is present: the terminal version, the desktop app or the VS Code extension | the same |
| C2 | The `claude` command is found in the terminal | the same |
| C3 | The terminal version is signed in | the same |
| C4 | — | the `claude` command is not shadowed by the desktop app |
| G1 | Git runs | the same |
| G2 | — | Git Bash came with Git |
| G3 | Git has a name and an e-mail, and they are not the sample ones from the fix | the same |
| G4 | GitHub CLI runs | the same |
| G5 | GitHub CLI is signed in | the same |
| G6 | Git uses that sign-in | the same, and Git Credential Manager counts as a route |
| G7 | A real push to GitHub works (only with the push-test switch) | the same |
| P1 | Python runs | the same, and a Store alias is probed only after a real Python |
| P2 | Python is 3.10 or later | the same |
| P3 | A package installs into a fresh virtual environment | the same |
| P4 | A script prints Ukrainian text and opens an HTTPS page | the same |

The record order is the order of this table, skipping the dashes: seventeen records on macOS,
twenty-one on Windows.

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

    powershell -NoProfile -File tests\run.ps1

The tests are hermetic: every external command is a stub, so they need no network and no
GitHub account. `tests\run.ps1 -Only <text>` runs one group while working on it.

Continuous integration also runs PSScriptAnalyzer 1.25.0 with `tests\analyzer.psd1`, which says
which rule families do not apply here and why. To run it the same way locally:

    Invoke-ScriptAnalyzer -ScriptDefinition ([IO.File]::ReadAllText("$PWD\check.ps1", [Text.Encoding]::UTF8)) -Severity Error, Warning -Settings .\tests\analyzer.psd1

Two rules the checkers must keep. `check.sh` runs on `/bin/bash` 3.2, the bash that ships with
macOS: no associative arrays. `check.ps1` runs on Windows PowerShell 5.1, the version built into
Windows: no PowerShell 7 syntax, no `exit`, and the file carries no byte-order mark, because it
is fetched and run as a string. `tests\run.ps1` does carry one, since 5.1 reads a file without
it as the system code page and the tests compare Ukrainian strings.

The short guide's PDF is built from its Markdown file and never edited by hand:

    python3 make_pdf.py

It needs Chrome, which prints the page. With pypdf or PyMuPDF installed, the script reads the
PDF back and fails unless every line of the prompt can be copied out of it.
