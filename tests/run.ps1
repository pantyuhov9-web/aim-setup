# Hermetic tests for check.ps1. Every external command the checker calls is a copy of the stub
# program built from tests/stub.cs, PATH holds only the stub folder and System32, and the home,
# local-application and Program Files folders point into a temporary tree, so the tests never
# touch the network, GitHub, or the real tools of the machine they run on.
#
# Usage: powershell -NoProfile -File tests\run.ps1        exit 0 = every test passed
#
# This file is saved with a byte-order mark on purpose: Windows PowerShell 5.1 reads a script
# file without one as the system code page, and these tests compare Ukrainian strings.
# check.ps1 itself must NOT have the mark, because it is fetched and run as a string; one of
# the tests below checks that.
#
# -Only <text> runs just the tests whose names contain that text, and every run leaves its
# captured report in aim-check-last.txt in the temporary folder, for reading while developing.

param([string]$Only = '')

$script:Root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$script:Check = Join-Path $script:Root 'check.ps1'
$script:StubSource = Join-Path $script:Root 'tests\stub.cs'
$script:PowerShellExe = Join-Path $PSHOME 'powershell.exe'
$script:Passed = 0
$script:Failed = 0
$script:Out = ''
$script:Rc = 0

# Every variable the checker reads is set for each run, so nothing leaks in from the machine
# the tests run on.
$script:ControlledKeys = @(
  'PATH', 'USERPROFILE', 'LOCALAPPDATA', 'TEMP', 'TMP',
  'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'GIT_TERMINAL_PROMPT', 'GIT_ASKPASS',
  'PYTHON_MANAGER_AUTOMATIC_INSTALL', 'AIM_STUB_LOG', 'AIM_CHECK_LIB', 'AIM_PIP_TIMEOUT',
  'AIM_TEST_BUILD', 'AIM_TEST_MEM', 'AIM_TEST_ARCH', 'AIM_TEST_NET', 'AIM_TEST_GITROOTS')

function Write-Ok { # description, condition
  param([string]$Description, [bool]$Condition)
  if ($Condition) {
    $script:Passed++
  } else {
    $script:Failed++
    Write-Host ('FAIL: ' + $Description)
  }
}

function Initialize-Stub { # compile the stub program once for the whole run
  $script:StubDir = Join-Path $env:TEMP ('aim-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $script:StubDir -Force | Out-Null
  $script:StubExe = Join-Path $script:StubDir 'stub.exe'
  Add-Type -TypeDefinition (Get-Content -LiteralPath $script:StubSource -Raw) `
    -OutputAssembly $script:StubExe -OutputType ConsoleApplication -ErrorAction Stop
}

function Set-Rules { # the lines of <tool>.exe.rules; see tests/stub.cs for the format
  param([string]$Tool, [string[]]$Lines)
  $path = Join-Path $script:Bin ($Tool + '.exe.rules')
  Set-Content -LiteralPath $path -Value $Lines -Encoding UTF8
}

function Add-Tool { # a copy of the stub program under a tool's name
  param([string]$Tool)
  Copy-Item -LiteralPath $script:StubExe -Destination (Join-Path $script:Bin ($Tool + '.exe')) -Force
}

function Remove-Tool {
  param([string]$Tool)
  Remove-Item -LiteralPath (Join-Path $script:Bin ($Tool + '.exe')) -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $script:Bin ($Tool + '.exe.rules')) -Force -ErrorAction SilentlyContinue
}

function New-Machine { # a healthy computer: every check passes
  $script:W = Join-Path $env:TEMP ('aim-run-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $script:Bin = Join-Path $script:W 'bin'
  $script:HomeDir = Join-Path $script:W 'home\student'
  $script:LocalApp = Join-Path $script:W 'home\student\AppData\Local'
  $script:ProgFiles = Join-Path $script:W 'pf'
  $script:ProgFiles86 = Join-Path $script:W 'pf86'
  $script:Log = Join-Path $script:W 'calls.log'
  foreach ($d in $script:Bin, $script:HomeDir, $script:LocalApp, $script:ProgFiles, $script:ProgFiles86,
                 (Join-Path $script:W 'temp'), (Join-Path $script:ProgFiles 'Git\bin')) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
  }
  Set-Content -LiteralPath (Join-Path $script:ProgFiles 'Git\bin\bash.exe') -Value 'stub' -Encoding ascii
  Set-Content -LiteralPath $script:Log -Value '' -Encoding UTF8

  foreach ($t in 'git', 'gh', 'claude', 'python', 'py', 'winget') { Add-Tool $t }

  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`tOlena Test",
    "config --global user.email`t0`tolena@example.com",
    "config --get-all credential.https://github.com.helper`t0`t!gh auth git-credential",
    "config --get-all credential.helper`t0`tmanager",
    "clone -q`t0`t@mkdir:5",
    "rev-parse HEAD`t0`tabc123",
    "ls-remote`t0`tabc123\trefs/heads/main",
    "*`t0`t")
  Set-Rules gh @(
    "--version`t0`tgh version 2.104.0 (2026-11-01)",
    "auth status`t0`t",
    "api user`t0`tstudent-login",
    "repo view`t0`t",
    "repo create`t0`t",
    "*`t0`t")
  Set-Rules claude @(
    "--version`t0`t2.1.300 (Claude Code)",
    "auth status`t0`t",
    "*`t0`t")
  Set-Rules python @(
    "ver.py`t0`taim-python 3.12.4",
    "-m venv`t0`t@mkvenv",
    "*`t0`t")
  Set-Rules py @(
    "ver.py`t0`taim-python 3.12.4",
    "-m venv`t0`t@mkvenv",
    "*`t0`t")
  Set-Rules winget @("*`t0`t")
  # Copied next to the virtual environment's python.exe by the @mkvenv action.
  Set-Content -LiteralPath (Join-Path $script:Bin 'venvpy.rules') -Encoding UTF8 -Value @(
    "-m pip install`t0`t",
    "t.py`t0`tПривіт від Python\nHTTPS 200",
    "*`t0`t")
}

function Remove-Machine {
  Remove-Item -LiteralPath $script:W -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-Check {
  # Runs the checker the way a student does: the file is read as UTF-8 and executed as a
  # scriptblock, in a child process whose whole environment this function controls.
  param([hashtable]$Environment = @{}, [string[]]$Switches = @())
  $saved = @{}
  foreach ($k in $script:ControlledKeys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
  $want = @{
    'PATH' = ($script:Bin + ';' + (Join-Path $env:SystemRoot 'System32'))
    'USERPROFILE' = $script:HomeDir
    'LOCALAPPDATA' = $script:LocalApp
    'AIM_TEST_GITROOTS' = ((Join-Path $script:ProgFiles 'Git') + ';' + (Join-Path $script:ProgFiles86 'Git'))
    'TEMP' = (Join-Path $script:W 'temp')
    'TMP' = (Join-Path $script:W 'temp')
    'AIM_STUB_LOG' = $script:Log
    'AIM_TEST_BUILD' = '26100'
    'AIM_TEST_MEM' = '17179869184'
    'AIM_TEST_NET' = 'ok'
  }
  foreach ($k in $Environment.Keys) { $want[$k] = $Environment[$k] }
  $outFile = Join-Path $script:W 'out.txt'
  $errFile = Join-Path $script:W 'err.txt'
  try {
    foreach ($k in $script:ControlledKeys) {
      $v = $null
      if ($want.ContainsKey($k)) { $v = $want[$k] }
      [Environment]::SetEnvironmentVariable($k, $v, 'Process')
    }
    $command = '& ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 ''' + $script:Check + ''')))'
    if ($Switches.Count -gt 0) { $command = $command + ' ' + ($Switches -join ' ') }
    $p = Start-Process -FilePath $script:PowerShellExe -NoNewWindow -PassThru `
      -ArgumentList @('-NoProfile', '-Command', ('"' + $command + '"')) `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $null = $p.Handle
    if ($p.WaitForExit(180000)) { $script:Rc = $p.ExitCode } else { try { $p.Kill() } catch { }; $script:Rc = 143 }
  } finally {
    foreach ($k in $script:ControlledKeys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
  }
  $script:Out = ''
  foreach ($f in $outFile, $errFile) {
    if (Test-Path -LiteralPath $f) { $script:Out += [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) }
  }
  [System.IO.File]::WriteAllText((Join-Path $env:TEMP 'aim-check-last.txt'), $script:Out,
    (New-Object System.Text.UTF8Encoding $false))
}

function Get-CallLog {
  if (Test-Path -LiteralPath $script:Log) { return [System.IO.File]::ReadAllText($script:Log, [System.Text.Encoding]::UTF8) }
  return ''
}

function Test-Status { # one record's status, read out of the JSON block
  param([string]$Id, [string]$Status)
  return $script:Out.Contains('"id":"' + $Id + '","status":"' + $Status + '"')
}

function Test-Text {
  param([string]$Text)
  return $script:Out.Contains($Text)
}

function Test-NoText {
  param([string]$Text)
  return (-not $script:Out.Contains($Text))
}

# ---- tests -----------------------------------------------------------------------------

function Test-AimReportFrameIsAlwaysPrinted {
  New-Machine
  Invoke-Check
  Write-Ok 'frame: heading' (Test-Text 'Перевірка компʼютера для курсу A&I Mastery')
  Write-Ok 'frame: names Windows' (Test-Text '(Windows, ')
  Write-Ok 'frame: support block opens' (Test-Text '----- звіт для куратора -----')
  Write-Ok 'frame: support block closes' (Test-Text '----- кінець звіту -----')
  Write-Ok 'frame: names the system and the driver' (Test-Text 'aim-check windows')
  Remove-Machine
}

function Test-AimSourceIsServableAsAString {
  # The student's command fetches this file and runs it as a string. A byte-order mark survives
  # that decode as U+FEFF, and both "iex" and [scriptblock]::Create then fail on the first token
  # ("The term '<mark>param' is not recognized"), so the mark must not be there. "exit" would
  # close the window the command was pasted into.
  $bytes = [System.IO.File]::ReadAllBytes($script:Check)
  $hasMark = ($bytes.Length -gt 2 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  Write-Ok 'source: no byte-order mark' (-not $hasMark)
  $text = [System.IO.File]::ReadAllText($script:Check, [System.Text.Encoding]::UTF8)
  Write-Ok 'source: never calls exit' ($text -notmatch '(?m)^\s*exit\b')
  Write-Ok 'source: sets the process result without exit' ($text.Contains('SetShouldExit'))
  Write-Ok 'source: the last line calls main' ($text.TrimEnd() -match 'Invoke-Main[^\r\n]*$')
}

function Test-AimSourceParsesAndStaysOnFiveOne {
  # The parser ships with Windows PowerShell, so this needs nothing installed. Running the whole
  # suite on 5.1 is the real compatibility proof; this catches the syntax that only looks fine.
  # check.ps1 is parsed from text decoded as UTF-8, the way it is run. ParseFile would read the
  # file as the system code page, mangle the Ukrainian strings and report dozens of errors that
  # are not there: that is the same trap the header warns about, and why nothing runs this file
  # with -File. tests\run.ps1 has the mark, so the file itself parses.
  $text = [System.IO.File]::ReadAllText($script:Check, [System.Text.Encoding]::UTF8)
  $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
  Write-Ok 'parses: check.ps1' (@($errors).Count -eq 0)
  $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'tests\run.ps1'), [ref]$null, [ref]$errors)
  Write-Ok 'parses: tests\run.ps1' (@($errors).Count -eq 0)
  Write-Ok 'five-one: no null-coalescing operator' ($text -notmatch '\?\?')
  Write-Ok 'five-one: no null-conditional operator' ($text -notmatch '\?\.|\?\[')
  Write-Ok 'five-one: no ternary operator' ($text -notmatch '\)\s*\?\s*[^\s]+\s*:\s')
  Write-Ok 'five-one: no pipeline chain operators' ($text -notmatch '&&|\|\|')
  Write-Ok 'five-one: no parallel loops' ($text -notmatch '-Parallel')
  Write-Ok 'five-one: no classes' ($text -notmatch '(?m)^\s*class\s')
}

function Test-AimRedirectedOutputIsUtf8 {
  New-Machine
  Invoke-Check
  $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:W 'out.txt'))
  # 0xD0 0x9F is "П" in UTF-8; a console code page without Cyrillic would give 0x3F.
  Write-Ok 'redirected: the report starts with UTF-8 Cyrillic' ($bytes[0] -eq 0xD0 -and $bytes[1] -eq 0x9F)
  Write-Ok 'redirected: no question marks in place of letters' (Test-NoText '??????')
  Remove-Machine
}

function Test-AimTerminalModeHasNoProcedure {
  New-Machine
  Invoke-Check
  Write-Ok 'terminal mode: says who runs the check' (Test-Text 'запуск із вікна термінала')
  Write-Ok 'terminal mode: no JSON block' (Test-NoText '=== aim-check json ===')
  Write-Ok 'terminal mode: no procedure' (Test-NoText 'порядок дій для Claude')
  Remove-Machine
}

function Test-AimJsonSwitchPrintsTheBlock {
  New-Machine
  Invoke-Check -Switches @('-Json')
  Write-Ok 'json switch: block opens' (Test-Text '=== aim-check json ===')
  Write-Ok 'json switch: block closes' (Test-Text '=== end json ===')
  Write-Ok 'json switch: no procedure outside Claude' (Test-NoText 'порядок дій для Claude')
  Remove-Machine
}

function Test-AimClaudeModeAddsJsonAndProcedure {
  New-Machine
  Invoke-Check -Environment @{ CLAUDECODE = '1'; CLAUDE_CODE_ENTRYPOINT = 'claude-desktop' }
  Write-Ok 'Claude mode: says who runs the check' (Test-Text 'запуск через Claude')
  Write-Ok 'Claude mode: JSON block without the switch' (Test-Text '=== aim-check json ===')
  Write-Ok 'Claude mode: procedure printed' (Test-Text '=== порядок дій для Claude ===')
  Write-Ok 'Claude mode: the procedure carries the push-test command' (Test-Text 'scriptblock]::Create((irm')
  Write-Ok 'Claude mode: the procedure fixes failures only' (Test-Text 'тільки пункти зі статусом fail')
  Write-Ok 'Claude mode: warnings are explained, their commands are not run' (Test-Text 'їхніх команд не виконуй')
  Remove-Machine
}

function Test-AimRecordOrderAndCount {
  New-Machine
  Invoke-Check -Switches @('-Json')
  $want = @('S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'C1', 'C2', 'C3', 'C4',
            'G1', 'G2', 'G3', 'G4', 'G5', 'G6', 'G7', 'P1', 'P2', 'P3', 'P4')
  $ids = @([regex]::Matches($script:Out, '"id":"([A-Z]\d)"') | ForEach-Object { $_.Groups[1].Value })
  Write-Ok 'records: twenty-one of them' ($ids.Count -eq 21)
  Write-Ok 'records: in the order continuous integration expects' (($ids -join ',') -eq ($want -join ','))
  Remove-Machine
}

function Test-AimSwitchesArriveThroughTheScriptblockForm {
  New-Machine
  Invoke-Check -Switches @('-Json', '-PushTest')
  Write-Ok 'switches: -PushTest switched the push test on' (Test-Status G7 'pass')
  Write-Ok 'switches: -Json printed the block' (Test-Text '=== end json ===')
  Remove-Machine
}

function Test-AimTruncatedDownloadRunsNothing {
  New-Machine
  $part = Join-Path $script:W 'part.ps1'
  $text = [System.IO.File]::ReadAllText($script:Check, [System.Text.Encoding]::UTF8)
  [System.IO.File]::WriteAllText($part, $text.Substring(0, 6000), (New-Object System.Text.UTF8Encoding $false))
  $saved = $script:Check
  $script:Check = $part
  Invoke-Check
  $script:Check = $saved
  Write-Ok 'truncated: prints no report' (Test-NoText 'Перевірка компʼютера')
  Write-Ok 'truncated: ran no git' ((Get-CallLog) -notmatch 'git\|')
  Remove-Machine
}

function Test-AimHealthySystem {
  New-Machine
  Invoke-Check -Switches @('-Json')
  Write-Ok 'system: S1 passes' (Test-Status S1 'pass')
  Write-Ok 'system: S2 passes' (Test-Status S2 'pass')
  Write-Ok 'system: S3 passes' (Test-Status S3 'pass')
  Write-Ok 'system: S4 passes' (Test-Status S4 'pass')
  Write-Ok 'system: S5 passes' (Test-Status S5 'pass')
  Write-Ok 'system: S6 is info' (Test-Status S6 'info')
  Write-Ok 'system: names the build' (Test-Text 'збірка 26100')
  Remove-Machine
}

function Test-AimOldWindowsFails {
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_BUILD = '17134' } -Switches @('-Json')
  Write-Ok 'old Windows: S1 fails' (Test-Status S1 'fail')
  Write-Ok 'old Windows: exit code 1' ($script:Rc -eq 1)
  Write-Ok 'old Windows: named as missing' (Test-Text 'Не вистачає: система.')
  Write-Ok 'old Windows: points at Windows Update' (Test-Text 'Windows Update')
  Remove-Machine
}

function Test-AimThirtyTwoBitWindowFails {
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_ARCH = 'proc32' } -Switches @('-Json')
  Write-Ok '32-bit window: S2 fails' (Test-Status S2 'fail')
  Write-Ok '32-bit window: names the window to open' (Test-Text '«Windows PowerShell (x86)»')
  Write-Ok '32-bit window: exit code 1' ($script:Rc -eq 1)
  Remove-Machine
}

function Test-AimThirtyTwoBitWindowsFails {
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_ARCH = 'os32' } -Switches @('-Json')
  Write-Ok '32-bit Windows: S2 fails' (Test-Status S2 'fail')
  Write-Ok '32-bit Windows: says the system is 32-bit' (Test-Text '32-розрядна Windows')
  Remove-Machine
}

function Test-AimLowMemoryWarnsWithoutFailing {
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_MEM = '2147483648' } -Switches @('-Json')
  Write-Ok 'low memory: S3 warns' (Test-Status S3 'warn')
  Write-Ok 'low memory: exit code stays 0' ($script:Rc -eq 0)
  Remove-Machine
}

function Test-AimCyrillicHomeFolderWarns {
  New-Machine
  $cyr = Join-Path $script:W 'home\Олена'
  New-Item -ItemType Directory -Path $cyr -Force | Out-Null
  Invoke-Check -Environment @{ USERPROFILE = $cyr } -Switches @('-Json')
  Write-Ok 'cyrillic home: S4 warns' (Test-Status S4 'warn')
  Write-Ok 'cyrillic home: names the cause' (Test-Text 'є кириличні літери')
  Write-Ok 'cyrillic home: the folder name itself is not printed' (Test-NoText 'Олена')
  Write-Ok 'cyrillic home: exit code stays 0' ($script:Rc -eq 0)
  Remove-Machine
}

function Test-AimSpaceInHomeFolderWarns {
  New-Machine
  $spaced = Join-Path $script:W 'home\Olena Test'
  New-Item -ItemType Directory -Path $spaced -Force | Out-Null
  Invoke-Check -Environment @{ USERPROFILE = $spaced } -Switches @('-Json')
  Write-Ok 'spaced home: S4 warns' (Test-Status S4 'warn')
  Write-Ok 'spaced home: names the cause' (Test-Text 'є пробіл')
  Remove-Machine
}

function Test-AimNoNetworkWarns {
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_NET = 'down:github.com,pypi.org,claude.ai' } -Switches @('-Json')
  Write-Ok 'no network: S5 warns' (Test-Status S5 'warn')
  Write-Ok 'no network: names the silent hosts' (Test-Text 'немає відповіді від: github.com pypi.org claude.ai')
  Write-Ok 'no network: exit code stays 0' ($script:Rc -eq 0)
  Remove-Machine
}

function Test-AimNoNetworkSummaryAdmitsTheGap {
  # Without a network nothing fails, but the GitHub sign-in and the Python packages were never
  # checked, and the summary must say so. It needs the checks that do the skipping, so it belongs
  # with the whole-machine tests and not with S5's own.
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_NET = 'down:github.com,pypi.org,claude.ai' } -Switches @('-Json')
  Write-Ok 'no network: the summary admits the gap' (Test-Text 'Не все вдалося перевірити. Пропущені пункти позначені [--].')
  Write-Ok 'no network: the summary does not claim that the main things work' (Test-NoText 'Головне працює')
  Remove-Machine
}

function Test-AimNoNetworkSkipsTheGitHubSignIn {
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_NET = 'down:github.com,pypi.org,claude.ai' } -Switches @('-Json')
  Write-Ok 'no network: G5 skipped' (Test-Status G5 'skip')
  Write-Ok 'no network: G5 says why' (Test-Text 'потрібен інтернет')
  Remove-Machine
}

function Test-AimNoNetworkSkipsPythonPackages {
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_NET = 'down:github.com,pypi.org,claude.ai' } -Switches @('-Json')
  Write-Ok 'no network: P3 skipped' (Test-Status P3 'skip')
  Write-Ok 'no network: P4 skipped' (Test-Status P4 'skip')
  Remove-Machine
}

function Test-AimUnsupportedRegionIsNamed {
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_NET = 'region' } -Switches @('-Json')
  Write-Ok 'region: S5 warns' (Test-Status S5 'warn')
  Write-Ok 'region: explains the VPN' (Test-Text 'VPN')
  Remove-Machine
}

function Test-AimWithoutWingetFixesPrintDownloadPages {
  New-Machine
  Remove-Tool winget
  Remove-Tool git
  Remove-Tool gh
  Remove-Tool python
  Remove-Tool py
  Invoke-Check -Switches @('-Json')
  Write-Ok 'no winget: S6 stays info' (Test-Status S6 'info')
  Write-Ok 'no winget: Git fix is the download page' (Test-Text 'https://git-scm.com/downloads/win')
  Write-Ok 'no winget: GitHub CLI fix is the releases page' (Test-Text 'https://github.com/cli/cli/releases/latest')
  Write-Ok 'no winget: Python fix is the downloads page' (Test-Text 'https://www.python.org/downloads/')
  Write-Ok 'no winget: no winget command is printed' (Test-NoText 'winget install')
  Write-Ok 'no winget: points at the Microsoft Store' (Test-Text 'Microsoft Store')
  Remove-Machine
}

function Test-AimHealthyClaude {
  New-Machine
  Invoke-Check -Switches @('-Json')
  Write-Ok 'claude: C1 passes' (Test-Status C1 'pass')
  Write-Ok 'claude: C2 passes' (Test-Status C2 'pass')
  Write-Ok 'claude: C3 passes' (Test-Status C3 'pass')
  Write-Ok 'claude: C4 passes' (Test-Status C4 'pass')
  Write-Ok 'claude: names the version it found' (Test-Text '2.1.300 (Claude Code)')
  Remove-Machine
}

function Test-AimNoClaudeAnywhereFails {
  New-Machine
  Remove-Tool claude
  Invoke-Check -Switches @('-Json')
  Write-Ok 'no Claude: C1 fails' (Test-Status C1 'fail')
  Write-Ok 'no Claude: C2 is info' (Test-Status C2 'info')
  Write-Ok 'no Claude: C4 is skipped' (Test-Status C4 'skip')
  Write-Ok "no Claude: prints Anthropic's installer" (Test-Text 'irm https://claude.ai/install.ps1 | iex')
  Write-Ok 'no Claude: exit code 1' ($script:Rc -eq 1)
  Remove-Machine
}

function Test-AimDesktopAppAloneIsEnough {
  New-Machine
  Remove-Tool claude
  New-Item -ItemType Directory -Path (Join-Path $script:LocalApp 'Microsoft\WindowsApps') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $script:LocalApp 'Microsoft\WindowsApps\claude-desktop.exe') -Value 'x' -Encoding ascii
  Invoke-Check -Switches @('-Json')
  Write-Ok 'desktop only: C1 passes' (Test-Status C1 'pass')
  Write-Ok 'desktop only: names the app' (Test-Text 'знайдено: застосунок')
  Write-Ok 'desktop only: C2 is info, not a failure' (Test-Status C2 'info')
  Write-Ok 'desktop only: C3 is info, not a failure' (Test-Status C3 'info')
  Write-Ok 'desktop only: exit code 0' ($script:Rc -eq 0)
  Remove-Machine
}

function Test-AimPackagedDesktopAppIsFound {
  # The Windows desktop app installs as a packaged app, with a folder under Packages.
  New-Machine
  Remove-Tool claude
  New-Item -ItemType Directory -Path (Join-Path $script:LocalApp 'Packages\Claude_pzs8sxrjxfjjc') -Force | Out-Null
  Invoke-Check -Switches @('-Json')
  Write-Ok 'packaged app: C1 passes' (Test-Status C1 'pass')
  Remove-Machine
}

function Test-AimVsCodeExtensionAloneIsEnough {
  New-Machine
  Remove-Tool claude
  New-Item -ItemType Directory -Path (Join-Path $script:HomeDir '.vscode\extensions\anthropic.claude-code-2.1.300-win32-x64') -Force | Out-Null
  Invoke-Check -Switches @('-Json')
  Write-Ok 'VS Code only: C1 passes' (Test-Status C1 'pass')
  Write-Ok 'VS Code only: names VS Code' (Test-Text 'знайдено: VS Code')
  Remove-Machine
}

function Test-AimCliInstalledButNotInPath {
  New-Machine
  Remove-Tool claude
  New-Item -ItemType Directory -Path (Join-Path $script:HomeDir '.local\bin') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $script:HomeDir '.local\bin\claude.exe') -Value 'x' -Encoding ascii
  Invoke-Check -Switches @('-Json')
  Write-Ok 'PATH: C2 fails' (Test-Status C2 'fail')
  Write-Ok 'PATH: C1 still passes' (Test-Status C1 'pass')
  Write-Ok 'PATH: C3 skipped' (Test-Status C3 'skip')
  Write-Ok 'PATH: prints the user-PATH command' (Test-Text "[Environment]::SetEnvironmentVariable('PATH'")
  Write-Ok 'PATH: changes the user list, not the system one' (Test-Text "'User')")
  Write-Ok 'PATH: never uses setx on PATH' (Test-NoText 'setx PATH')
  Write-Ok 'PATH: the command carries no shell variable any shell would eat' (Test-NoText '$env:USERPROFILE')
  Write-Ok 'PATH: asks for a new window' (Test-Text 'відкрийте нове вікно')
  Remove-Machine
}

function Test-AimClaudeLoggedOutWarns {
  New-Machine
  Set-Rules claude @("--version`t0`t2.1.300 (Claude Code)", "auth status`t1`t", "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'logged out: C3 warns' (Test-Status C3 'warn')
  Write-Ok 'logged out: exit code stays 0' ($script:Rc -eq 0)
  Remove-Machine
}

function Test-AimClaudeModePassesByConstruction {
  New-Machine
  Remove-Tool claude
  Invoke-Check -Environment @{ CLAUDECODE = '1'; CLAUDE_CODE_ENTRYPOINT = 'claude-vscode' }
  Write-Ok 'Claude mode: C1 passes by construction' (Test-Status C1 'pass')
  Write-Ok 'Claude mode: names the surface' (Test-Text 'claude-vscode')
  Remove-Machine
}

function Test-AimClaudeCommandShadowedByTheApp {
  New-Machine
  Remove-Tool claude
  $apps = Join-Path $script:LocalApp 'Microsoft\WindowsApps'
  New-Item -ItemType Directory -Path $apps -Force | Out-Null
  Copy-Item -LiteralPath $script:StubExe -Destination (Join-Path $apps 'claude.exe') -Force
  Set-Content -LiteralPath (Join-Path $apps 'claude.exe.rules') -Encoding UTF8 -Value @("*`t0`t")
  Invoke-Check -Environment @{ PATH = ($script:Bin + ';' + $apps + ';' + (Join-Path $env:SystemRoot 'System32')) } -Switches @('-Json')
  Write-Ok 'shadowed: C4 warns' (Test-Status C4 'warn')
  Write-Ok 'shadowed: says the command leads to the app' (Test-Text 'веде до застосунку')
  Write-Ok 'shadowed: asks for a restart of Claude' (Test-Text 'перезапустіть Claude')
  Write-Ok 'shadowed: exit code stays 0' ($script:Rc -eq 0)
  Remove-Machine
}

function Test-AimHealthyGit {
  New-Machine
  Invoke-Check -Switches @('-Json')
  foreach ($id in 'G1', 'G2', 'G3', 'G4', 'G5', 'G6') {
    Write-Ok ('git: ' + $id + ' passes') (Test-Status $id 'pass')
  }
  Write-Ok 'git: G7 is skipped without the switch' (Test-Status G7 'skip')
  Write-Ok 'git: names the Git version' (Test-Text '2.47.1')
  Remove-Machine
}

function Test-AimGitMissing {
  New-Machine
  Remove-Tool git
  Invoke-Check -Switches @('-Json')
  Write-Ok 'no git: G1 fails' (Test-Status G1 'fail')
  Write-Ok 'no git: prints the winget command' (Test-Text 'winget install --id Git.Git -e --source winget')
  Write-Ok 'no git: G2 skipped' (Test-Status G2 'skip')
  Write-Ok 'no git: G3 skipped' (Test-Status G3 'skip')
  Write-Ok 'no git: G6 skipped' (Test-Status G6 'skip')
  Write-Ok 'no git: G7 skipped' (Test-Status G7 'skip')
  Write-Ok 'no git: exit code 1' ($script:Rc -eq 1)
  Remove-Machine
}

function Test-AimGitBashMissingWarns {
  New-Machine
  Remove-Item -LiteralPath (Join-Path $script:ProgFiles 'Git\bin\bash.exe') -Force
  Invoke-Check -Switches @('-Json')
  Write-Ok 'no Git Bash: G2 warns' (Test-Status G2 'warn')
  Write-Ok 'no Git Bash: says PowerShell is used instead' (Test-Text 'через PowerShell')
  Write-Ok 'no Git Bash: exit code stays 0' ($script:Rc -eq 0)
  Remove-Machine
}

function Test-AimGitBashOutsideTheStandardFolder {
  New-Machine
  Remove-Item -LiteralPath (Join-Path $script:ProgFiles 'Git\bin\bash.exe') -Force
  Set-Content -LiteralPath (Join-Path $script:Bin 'bash.exe') -Value 'stub' -Encoding ascii
  Invoke-Check -Switches @('-Json')
  Write-Ok 'other Git Bash: G2 warns' (Test-Status G2 'warn')
  Write-Ok 'other Git Bash: names the setting' (Test-Text 'CLAUDE_CODE_GIT_BASH_PATH')
  Remove-Machine
}

function Test-AimGitIdentityMissing {
  New-Machine
  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`t",
    "config --global user.email`t0`tolena@example.com",
    "config --get-all credential.https://github.com.helper`t0`t!gh auth git-credential",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'identity: G3 fails' (Test-Status G3 'fail')
  Write-Ok 'identity: prints the name command' (Test-Text 'git config --global user.name "Імʼя Прізвище"')
  Write-Ok 'identity: prints the e-mail command' (Test-Text 'git config --global user.email "you@example.com"')
  Remove-Machine
}

function Test-AimGitIdentityLeftAsTheSampleFails {
  # The fix prints a sample name and a sample e-mail. Pasted as they are, they must not pass.
  New-Machine
  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`tІмʼя Прізвище",
    "config --global user.email`t0`tolena@example.com",
    "config --get-all credential.https://github.com.helper`t0`t!gh auth git-credential",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'sample name: G3 fails' (Test-Status G3 'fail')
  Write-Ok 'sample name: says it is the sample' (Test-Text 'вказано зразок')
  Remove-Machine
  New-Machine
  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`tOlena Test",
    "config --global user.email`t0`tyou@example.com",
    "config --get-all credential.https://github.com.helper`t0`t!gh auth git-credential",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'sample e-mail: G3 fails' (Test-Status G3 'fail')
  Remove-Machine
}

function Test-AimGitHubCliMissing {
  New-Machine
  Remove-Tool gh
  Invoke-Check -Switches @('-Json')
  Write-Ok 'no gh: G4 fails' (Test-Status G4 'fail')
  Write-Ok 'no gh: prints the winget command' (Test-Text 'winget install --id GitHub.cli --source winget')
  Write-Ok 'no gh: G5 skipped' (Test-Status G5 'skip')
  Write-Ok 'no gh: G6 skipped' (Test-Status G6 'skip')
  Write-Ok 'no gh: asks for a new window' (Test-Text 'відкрийте нове вікно')
  Remove-Machine
}

function Test-AimGitHubCliLoggedOut {
  New-Machine
  Set-Rules gh @(
    "--version`t0`tgh version 2.104.0 (2026-11-01)",
    "auth status`t1`t",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'gh logged out: G5 fails' (Test-Status G5 'fail')
  Write-Ok 'gh logged out: prints the browser login' (Test-Text 'gh auth login --web --git-protocol https')
  Write-Ok 'gh logged out: the same fix lets Git use that sign-in' (Test-Text '{"cmd":"gh auth setup-git","needs":""}')
  Write-Ok 'gh logged out: G6 skipped' (Test-Status G6 'skip')
  Remove-Machine
}

function Test-AimCredentialManagerIsASignInRoute {
  # Git Credential Manager ships with Git for Windows and holds the GitHub sign-in itself.
  New-Machine
  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`tOlena Test",
    "config --global user.email`t0`tolena@example.com",
    "config --get-all credential.https://github.com.helper`t0`t",
    "config --get-all credential.helper`t0`tmanager",
    "clone -q`t0`t@mkdir:5",
    "rev-parse HEAD`t0`tabc123",
    "ls-remote`t0`tabc123\trefs/heads/main",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'manager: G6 passes' (Test-Status G6 'pass')
  Write-Ok 'manager: names the route' (Test-Text 'через Git Credential Manager')
  Write-Ok 'manager: says everything works' (Test-Text 'Усе потрібне працює.')
  Remove-Machine
}

function Test-AimGitHubCliIsASignInRoute {
  New-Machine
  Invoke-Check -Switches @('-Json')
  Write-Ok 'gh helper: G6 passes' (Test-Status G6 'pass')
  Write-Ok 'gh helper: names the route' (Test-Text 'через GitHub CLI')
  Remove-Machine
}

function Test-AimAnotherSignInRouteIsAWarning {
  New-Machine
  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`tOlena Test",
    "config --global user.email`t0`tolena@example.com",
    "config --get-all credential.https://github.com.helper`t0`t",
    "config --get-all credential.helper`t0`twincred",
    "clone -q`t0`t@mkdir:5",
    "rev-parse HEAD`t0`tabc123",
    "ls-remote`t0`tabc123\trefs/heads/main",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'other helper: G6 warns' (Test-Status G6 'warn')
  Write-Ok 'other helper: names the helper' (Test-Text 'wincred')
  Write-Ok 'other helper: still offers setup-git' (Test-Text 'gh auth setup-git')
  Write-Ok 'other helper: exit code stays 0' ($script:Rc -eq 0)
  Write-Ok 'other helper: summary admits a remark' (Test-Text 'Головне працює. Є зауваження')
  Remove-Machine
}

function Test-AimNoSignInRouteAtAllFails {
  New-Machine
  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`tOlena Test",
    "config --global user.email`t0`tolena@example.com",
    "config --get-all credential`t0`t",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'no helper: G6 fails' (Test-Status G6 'fail')
  Write-Ok 'no helper: prints setup-git' (Test-Text 'gh auth setup-git')
  Write-Ok 'no helper: exit code 1' ($script:Rc -eq 1)
  Remove-Machine
}

function Test-AimPushTestPasses {
  New-Machine
  Invoke-Check -Switches @('-Json', '-PushTest')
  Write-Ok 'push test: G7 passes' (Test-Status G7 'pass')
  Write-Ok 'push test: names the private repo' (Test-Text 'приватне сховище aim-setup-check')
  Write-Ok 'push test: exit code 0' ($script:Rc -eq 0)
  Write-Ok 'push test: says everything works' (Test-Text 'Усе потрібне працює.')
  Write-Ok 'push test: no fix section' (Test-NoText 'Як виправити')
  Remove-Machine
}

function Test-AimPushTestSettlesAHelperWarning {
  New-Machine
  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`tOlena Test",
    "config --global user.email`t0`tolena@example.com",
    "config --get-all credential.https://github.com.helper`t0`t",
    "config --get-all credential.helper`t0`twincred",
    "clone -q`t0`t@mkdir:5",
    "rev-parse HEAD`t0`tabc123",
    "ls-remote`t0`tabc123\trefs/heads/main",
    "*`t0`t")
  Invoke-Check -Switches @('-Json', '-PushTest')
  Write-Ok 'push with a warning: G7 passes' (Test-Status G7 'pass')
  Write-Ok 'push with a warning: the passed push settles G6' (Test-Status G6 'pass')
  Write-Ok 'push with a warning: names the route that works' (Test-Text 'працює через wincred')
  Write-Ok 'push with a warning: says everything works' (Test-Text 'Усе потрібне працює.')
  Write-Ok 'push with a warning: no fix section' (Test-NoText 'Як виправити')
  Remove-Machine
}

function Test-AimPushTestReportsARefusedPush {
  New-Machine
  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`tOlena Test",
    "config --global user.email`t0`tolena@example.com",
    "config --get-all credential.https://github.com.helper`t0`t!gh auth git-credential",
    "clone -q`t0`t@mkdir:5",
    "push -q -u origin`t1`t",
    "rev-parse HEAD`t0`tabc123",
    "ls-remote`t0`tabc123\trefs/heads/main",
    "*`t0`t")
  Invoke-Check -Switches @('-Json', '-PushTest')
  Write-Ok 'push refused: G7 fails' (Test-Status G7 'fail')
  Write-Ok 'push refused: says so' (Test-Text 'GitHub не прийняв відправку')
  Write-Ok 'push refused: the fix switches Git to the GitHub CLI sign-in' (Test-Text '{"cmd":"gh auth setup-git","needs":""}')
  Remove-Machine
}

function Test-AimPushTestOffersTheFixWhenGitCannotSignIn {
  # A private repo needs a sign-in already at the clone, so that is where a PC whose Git has no
  # GitHub sign-in stops.
  New-Machine
  Set-Rules git @(
    "--version`t0`tgit version 2.47.1",
    "config --global user.name`t0`tOlena Test",
    "config --global user.email`t0`tolena@example.com",
    "config --get-all credential.https://github.com.helper`t0`t!gh auth git-credential",
    "clone -q`t128`t",
    "*`t0`t")
  Invoke-Check -Switches @('-Json', '-PushTest')
  Write-Ok 'no sign-in at the clone: G7 fails' (Test-Status G7 'fail')
  Write-Ok 'no sign-in at the clone: says so' (Test-Text 'не вдалося отримати сховище з GitHub')
  Write-Ok 'no sign-in at the clone: the fix switches Git to the GitHub CLI sign-in' (Test-Text '{"cmd":"gh auth setup-git","needs":""}')
  Remove-Machine
}

function Test-AimPushTestNeverAsksForAUserName {
  # Without these two settings Git prints "Username for 'https://github.com':" in the student's
  # window, or opens a pop-up, and waits.
  New-Machine
  Invoke-Check -Switches @('-Json', '-PushTest')
  $log = Get-CallLog
  $cloneLine = @($log -split "`n" | Where-Object { $_ -match '^git\|-c credential\.interactive=false clone' })
  Write-Ok 'no prompts: the clone ran with terminal prompts off' `
    ($cloneLine.Count -eq 1 -and $cloneLine[0] -match 'GIT_TERMINAL_PROMPT=0')
  Write-Ok 'no prompts: the clone told the credential manager not to ask' ($cloneLine.Count -eq 1)
  $pushLine = @($log -split "`n" | Where-Object { $_ -match 'credential\.interactive=false push' })
  Write-Ok 'no prompts: the push ran the same way' `
    ($pushLine.Count -eq 1 -and $pushLine[0] -match 'GIT_TERMINAL_PROMPT=0')
  Write-Ok 'no prompts: the setting is left off the other calls' `
    ((@($log -split "`n" | Where-Object { $_ -match '^git\|config' }) | Where-Object { $_ -match 'GIT_TERMINAL_PROMPT=0' }).Count -eq 0)
  Remove-Machine
}

function Test-AimPushTestCommitIsNeverSigned {
  # A signing setup that asks for a passphrase would stop the check; the scratch commit needs
  # no signature.
  New-Machine
  Invoke-Check -Switches @('-Json', '-PushTest')
  Write-Ok 'scratch commit: signing is switched off' ((Get-CallLog) -match '-c commit\.gpgsign=false commit')
  Remove-Machine
}

function Test-AimPushTestSkippedWhenEarlierChecksFail {
  New-Machine
  Set-Rules gh @("--version`t0`tgh version 2.104.0", "auth status`t1`t", "*`t0`t")
  Invoke-Check -Switches @('-Json', '-PushTest')
  Write-Ok 'push test: skipped while the sign-in is missing' (Test-Status G7 'skip')
  Write-Ok 'push test: says why' (Test-Text 'спершу виправте пункти вище')
  Write-Ok 'push test: no repo was created' ((Get-CallLog) -notmatch 'repo create')
  Remove-Machine
}

function Test-AimHealthyPython {
  New-Machine
  Invoke-Check -Switches @('-Json')
  foreach ($id in 'P1', 'P2', 'P3', 'P4') {
    Write-Ok ('python: ' + $id + ' passes') (Test-Status $id 'pass')
  }
  Write-Ok 'python: names the version' (Test-Text '3.12.4')
  Remove-Machine
}

function Test-AimPythonMissing {
  New-Machine
  Remove-Tool python
  Remove-Tool py
  Invoke-Check -Switches @('-Json')
  Write-Ok 'no python: P1 fails' (Test-Status P1 'fail')
  Write-Ok 'no python: P2 skipped' (Test-Status P2 'skip')
  Write-Ok 'no python: P3 skipped' (Test-Status P3 'skip')
  Write-Ok 'no python: P4 skipped' (Test-Status P4 'skip')
  Write-Ok 'no python: fix installs the install manager' (Test-Text 'winget install 9NQ7512CXL7T -e --accept-package-agreements --disable-interactivity')
  Write-Ok 'no python: fix then installs the default runtime' (Test-Text 'py install default')
  Remove-Machine
}

function Test-AimPythonFoundButBroken {
  New-Machine
  Set-Rules python @("*`t1`t")
  Set-Rules py @("*`t1`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'broken python: P1 fails' (Test-Status P1 'fail')
  Write-Ok 'broken python: says it was found' (Test-Text 'знайдено, але не запускається')
  Remove-Machine
}

function Test-AimPythonTooOld {
  New-Machine
  Set-Rules python @("ver.py`t0`taim-python 3.9.6", "-m venv`t0`t@mkvenv", "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'old python: P1 passes' (Test-Status P1 'pass')
  Write-Ok 'old python: P2 fails' (Test-Status P2 'fail')
  Write-Ok 'old python: P3 skipped' (Test-Status P3 'skip')
  Write-Ok 'old python: P4 skipped' (Test-Status P4 'skip')
  Write-Ok 'old python: names the version' (Test-Text '3.9.6, потрібна 3.10 або новіша')
  Remove-Machine
}

function Test-AimVirtualEnvironmentCannotBeCreated {
  New-Machine
  Set-Rules python @("ver.py`t0`taim-python 3.12.4", "-m venv`t1`t", "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'no venv: P3 fails' (Test-Status P3 'fail')
  Write-Ok 'no venv: says so' (Test-Text 'не вдалося створити окреме середовище')
  Write-Ok 'no venv: P4 skipped' (Test-Status P4 'skip')
  Remove-Machine
}

function Test-AimPipInstallFails {
  New-Machine
  Set-Content -LiteralPath (Join-Path $script:Bin 'venvpy.rules') -Encoding UTF8 -Value @(
    "-m pip install`t1`t",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'pip: P3 fails' (Test-Status P3 'fail')
  Write-Ok 'pip: P4 skipped' (Test-Status P4 'skip')
  Remove-Machine
}

function Test-AimSlowNetworkMakesPackagesAWarning {
  New-Machine
  Set-Content -LiteralPath (Join-Path $script:Bin 'venvpy.rules') -Encoding UTF8 -Value @(
    "-m pip install`t0`t@sleep:30 ",
    "*`t0`t")
  $started = Get-Date
  Invoke-Check -Environment @{ AIM_PIP_TIMEOUT = '2' } -Switches @('-Json')
  $took = ((Get-Date) - $started).TotalSeconds
  Write-Ok 'slow network: P3 warns' (Test-Status P3 'warn')
  Write-Ok 'slow network: P4 skipped' (Test-Status P4 'skip')
  Write-Ok 'slow network: the summary says not everything was checked' (Test-Text 'Не все вдалося перевірити.')
  Write-Ok 'slow network: exit code stays 0' ($script:Rc -eq 0)
  Write-Ok 'slow network: the hanging install was stopped' ($took -le 25)
  Remove-Machine
}

function Test-AimScriptCannotPrintUkrainian {
  New-Machine
  Set-Content -LiteralPath (Join-Path $script:Bin 'venvpy.rules') -Encoding UTF8 -Value @(
    "-m pip install`t0`t",
    "t.py`t1`tUnicodeEncodeError: 'charmap' codec can't encode characters",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'encoding: P4 fails' (Test-Status P4 'fail')
  Write-Ok 'encoding: says what went wrong' (Test-Text 'не зміг надрукувати український текст')
  Write-Ok 'encoding: the fix switches UTF-8 on' (Test-Text 'setx PYTHONUTF8 1')
  Remove-Machine
}

function Test-AimScriptFailsForAnotherReason {
  New-Machine
  Set-Content -LiteralPath (Join-Path $script:Bin 'venvpy.rules') -Encoding UTF8 -Value @(
    "-m pip install`t0`t",
    "t.py`t1`tTraceback",
    "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'script: P4 fails' (Test-Status P4 'fail')
  Write-Ok 'script: says the script did not work' (Test-Text 'скрипт не відпрацював')
  Remove-Machine
}

function Test-AimStoreAliasIsProbedAfterARealPython {
  # A command under WindowsApps is an app-execution alias; a dead one opens the Microsoft Store.
  New-Machine
  Remove-Tool python
  $apps = Join-Path $script:LocalApp 'Microsoft\WindowsApps'
  New-Item -ItemType Directory -Path $apps -Force | Out-Null
  Copy-Item -LiteralPath $script:StubExe -Destination (Join-Path $apps 'python.exe') -Force
  Set-Content -LiteralPath (Join-Path $apps 'python.exe.rules') -Encoding UTF8 -Value @("*`t0`t")
  Invoke-Check -Environment @{ PATH = ($apps + ';' + $script:Bin + ';' + (Join-Path $env:SystemRoot 'System32')) } -Switches @('-Json')
  Write-Ok 'alias: P1 passes through the real python launcher' (Test-Status P1 'pass')
  # One probe only, and it went to the launcher: the virtual environment's own python.exe logs
  # under the same name, so the probe line is what tells the two apart.
  $probes = @((Get-CallLog) -split "`n" | Where-Object { $_ -match 'ver\.py' })
  Write-Ok 'alias: the alias was never probed' ($probes.Count -eq 1 -and $probes[0] -match '^py\|')
  Remove-Machine
}

function Test-AimStoreAliasAloneFails {
  New-Machine
  Remove-Tool python
  Remove-Tool py
  $apps = Join-Path $script:LocalApp 'Microsoft\WindowsApps'
  New-Item -ItemType Directory -Path $apps -Force | Out-Null
  Copy-Item -LiteralPath $script:StubExe -Destination (Join-Path $apps 'python.exe') -Force
  Set-Content -LiteralPath (Join-Path $apps 'python.exe.rules') -Encoding UTF8 -Value @("*`t0`t")
  Invoke-Check -Environment @{ PATH = ($apps + ';' + $script:Bin + ';' + (Join-Path $env:SystemRoot 'System32')) } -Switches @('-Json')
  Write-Ok 'alias alone: P1 fails' (Test-Status P1 'fail')
  Write-Ok 'alias alone: says it was found but does not run' (Test-Text 'знайдено, але не запускається')
  Remove-Machine
}

function Test-AimPythonProbeNeverInstalls {
  New-Machine
  Invoke-Check -Switches @('-Json')
  $probe = @((Get-CallLog) -split "`n" | Where-Object { $_ -match '^python\|.*ver\.py' })
  Write-Ok 'probe: the install manager was told not to install' `
    ($probe.Count -eq 1 -and $probe[0] -match 'PYTHON_MANAGER_AUTOMATIC_INSTALL=0')
  Remove-Machine
}

function Test-AimCyrillicAndSpacedPathsStillRunPython {
  # A Ukrainian PC often has both: a user folder in Cyrillic and a temporary folder under it.
  # The checker writes its probe scripts and its virtual environment there.
  New-Machine
  $home2 = Join-Path $script:W 'home\Олена Петрівна'
  $temp2 = Join-Path $home2 'Temp тест'
  New-Item -ItemType Directory -Path $temp2 -Force | Out-Null
  Invoke-Check -Environment @{ USERPROFILE = $home2; TEMP = $temp2; TMP = $temp2 } -Switches @('-Json')
  Write-Ok 'cyrillic temp: P3 passes' (Test-Status P3 'pass')
  Write-Ok 'cyrillic temp: P4 passes' (Test-Status P4 'pass')
  Write-Ok 'cyrillic temp: S4 still warns about the folder name' (Test-Status S4 'warn')
  Write-Ok 'cyrillic temp: nothing is left behind' (@(Get-ChildItem -LiteralPath $temp2 -Force -ErrorAction SilentlyContinue).Count -eq 0)
  Remove-Machine
}

function Test-AimPushTestCreatesTheRepoWhenMissing {
  New-Machine
  Set-Rules gh @(
    "--version`t0`tgh version 2.104.0 (2026-11-01)",
    "auth status`t0`t",
    "api user`t0`tstudent-login",
    "repo view`t1`t",
    "repo create`t0`t",
    "*`t0`t")
  Invoke-Check -Switches @('-Json', '-PushTest')
  Write-Ok 'missing repo: it is created' ((Get-CallLog) -match 'repo create aim-setup-check --private')
  Write-Ok 'missing repo: it is created private' ((Get-CallLog) -match '--private')
  Write-Ok 'missing repo: G7 passes' (Test-Status G7 'pass')
  Remove-Machine
}

function Test-AimPushTestWithoutAnAccountName {
  New-Machine
  Set-Rules gh @(
    "--version`t0`tgh version 2.104.0 (2026-11-01)",
    "auth status`t0`t",
    "api user`t1`t",
    "*`t0`t")
  Invoke-Check -Switches @('-Json', '-PushTest')
  Write-Ok 'no account name: G7 fails' (Test-Status G7 'fail')
  Write-Ok 'no account name: says what it could not do' (Test-Text 'не вдалося дізнатися обліковий запис GitHub')
  Write-Ok 'no account name: no repo was created' ((Get-CallLog) -notmatch 'repo create')
  Remove-Machine
}

function Test-AimToolPresentButSilent {
  # A tool that answers nothing must still count as present: the report says so plainly instead
  # of telling the student to install what is already there.
  New-Machine
  Set-Rules gh @("auth status`t0`t", "api user`t0`tstudent-login", "repo view`t0`t", "*`t1`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'silent tool: G4 passes' (Test-Status G4 'pass')
  Write-Ok 'silent tool: says it was found' (Test-Text '"id":"G4","status":"pass","group":"github","title":"GitHub CLI","evidence":"знайдено"')
  Write-Ok 'silent tool: no install command is printed' (Test-NoText 'winget install --id GitHub.cli')
  Remove-Machine
}

function Test-AimAllThreeSurfacesAreNamed {
  New-Machine
  New-Item -ItemType Directory -Path (Join-Path $script:LocalApp 'Microsoft\WindowsApps') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $script:LocalApp 'Microsoft\WindowsApps\claude-desktop.exe') -Value 'x' -Encoding ascii
  New-Item -ItemType Directory -Path (Join-Path $script:HomeDir '.vscode\extensions\anthropic.claude-code-2.1.300-win32-x64') -Force | Out-Null
  Invoke-Check -Switches @('-Json')
  Write-Ok 'three surfaces: C1 names all of them' (Test-Text 'знайдено: термінал, застосунок, VS Code')
  Remove-Machine
}

function Test-AimHealthyMachinePasses {
  New-Machine
  Invoke-Check -Switches @('-Json')
  Write-Ok 'healthy: exit code 0' ($script:Rc -eq 0)
  foreach ($id in 'S1', 'S2', 'S3', 'S4', 'S5', 'C1', 'C2', 'C3', 'C4', 'G1', 'G2', 'G3', 'G4', 'G5', 'G6', 'P1', 'P2', 'P3', 'P4') {
    Write-Ok ('healthy: ' + $id + ' passes') (Test-Status $id 'pass')
  }
  Write-Ok 'healthy: S6 is info' (Test-Status S6 'info')
  Write-Ok 'healthy: G7 is skipped without the switch' (Test-Status G7 'skip')
  Write-Ok 'healthy: says everything works' (Test-Text 'Усе потрібне працює.')
  Write-Ok 'healthy: no fix section' (Test-NoText 'Як виправити')
  Write-Ok 'healthy: support block present' (Test-Text '----- звіт для куратора -----')
  Remove-Machine
}

function Test-AimReportNeverCarriesTheUserName {
  New-Machine
  New-Item -ItemType Directory -Path (Join-Path $script:HomeDir '.local\bin') -Force | Out-Null
  Copy-Item -LiteralPath $script:StubExe -Destination (Join-Path $script:HomeDir '.local\bin\python.exe') -Force
  Set-Content -LiteralPath (Join-Path $script:HomeDir '.local\bin\python.exe.rules') -Encoding UTF8 -Value @(
    "ver.py`t0`taim-python 3.12.4",
    "-m venv`t0`t@mkvenv",
    "*`t0`t")
  Copy-Item -LiteralPath (Join-Path $script:Bin 'venvpy.rules') -Destination (Join-Path $script:HomeDir '.local\bin\venvpy.rules') -Force
  Remove-Tool python
  Invoke-Check -Environment @{
    PATH = ((Join-Path $script:HomeDir '.local\bin') + ';' + $script:Bin + ';' + (Join-Path $env:SystemRoot 'System32'))
  } -Switches @('-Json', '-PushTest')
  Write-Ok 'privacy: the python path is shown with a tilde' (Test-Text '~\.local\bin\python.exe')
  Write-Ok 'privacy: the home folder name is absent' (Test-NoText 'student')
  Write-Ok 'privacy: the e-mail is absent' (Test-NoText 'olena@example.com')
  Write-Ok 'privacy: the GitHub login is absent' (Test-NoText 'student-login')
  Remove-Machine
}

function Test-AimJsonBlockShape {
  New-Machine
  Set-Rules gh @("--version`t0`tgh version 2.104.0", "auth status`t1`t", "*`t0`t")
  Invoke-Check -Switches @('-Json')
  Write-Ok 'json: fix carries each command and its flag' `
    (Test-Text '"fix":[{"cmd":"gh auth login --web --git-protocol https","needs":"browser"},{"cmd":"gh auth setup-git","needs":""}]')
  Write-Ok 'json: every key of the contract is present' (Test-Text '"id":"S1","status":"pass","group":"system","title":"')
  Write-Ok 'json: closes' (Test-Text '=== end json ===')
  Remove-Machine
}

function Test-AimTimeoutStopsAHangingCommand {
  New-Machine
  Set-Rules claude @("--version`t0`t@sleep:60 ", "*`t0`t")
  $started = Get-Date
  Invoke-Check -Switches @('-Json')
  $took = ((Get-Date) - $started).TotalSeconds
  Write-Ok 'timeout: a hanging command did not stop the run' (Test-Text '----- кінець звіту -----')
  Write-Ok 'timeout: the run ended well before the hang would have' ($took -le 40)
  Write-Ok 'timeout: the checks after it still ran' (Test-Status P4 'pass')
  Remove-Machine
}

function Test-AimNothingIsLeftBehind {
  New-Machine
  Invoke-Check -Switches @('-Json', '-PushTest')
  $leftovers = @(Get-ChildItem -LiteralPath (Join-Path $script:W 'temp') -Force -ErrorAction SilentlyContinue)
  Write-Ok 'no state: the temporary folder is empty afterwards' ($leftovers.Count -eq 0)
  Remove-Machine
}

# ---- run every test --------------------------------------------------------------------

Initialize-Stub
try {
  # Test-Aim is the prefix of this file's own tests: plain "Test-" would also match the
  # functions Windows ships in its own modules.
  foreach ($t in (Get-Command -CommandType Function -Name 'Test-Aim*' | Sort-Object Name)) {
    if ($Only -and $t.Name -notlike ('*' + $Only + '*')) { continue }
    & $t.Name
  }
} finally {
  Remove-Item -LiteralPath $script:StubDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ($script:Passed.ToString() + ' passed, ' + $script:Failed.ToString() + ' failed')
if ($script:Failed -gt 0) { $host.SetShouldExit(1) }
