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

function Test-AimUnsupportedRegionIsNamed {
  New-Machine
  Invoke-Check -Environment @{ AIM_TEST_NET = 'region' } -Switches @('-Json')
  Write-Ok 'region: S5 warns' (Test-Status S5 'warn')
  Write-Ok 'region: explains the VPN' (Test-Text 'VPN')
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
