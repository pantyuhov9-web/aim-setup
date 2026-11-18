# aim-setup: setup check for Windows, for students of A&I Mastery courses built on Claude Code.
# It answers one question: do Claude Code, Git-to-GitHub sync and Python scripts work here?
#
# Run:       powershell -NoProfile -Command "irm https://ai-mastery.xyz/check.ps1 | iex"
# Switches:  -Json        also print the records as JSON
#            -PushTest    create or reuse a private repo "aim-setup-check" and push to it
#            Pass one through the pipe with the scriptblock form; see $script:PushCmd below.
#
# Read-only: it installs nothing and leaves nothing behind. -PushTest is the one exception.
# Runs on Windows PowerShell 5.1, the version built into Windows. No PowerShell 7 syntax.
# It never calls exit: pasted into an open window, exit would close it. The process result is
# set with $host.SetShouldExit, and only when the output is redirected, where nobody is reading.
# The source is UTF-8 without a byte-order mark, and it is always run as a string decoded as
# UTF-8 ("irm | iex", or scriptblock::Create of a UTF-8 read), never with -File: PowerShell 5.1
# reads a file without the mark as the system code page and would mangle the Ukrainian text.
# Redirected output is encoded in the console code page, which has no Cyrillic on many PCs, so
# the report is written as UTF-8 bytes to the process's own output stream whenever the output is
# redirected; see Write-Line. One consequence: to capture the report to a file, redirect the
# process ("powershell ... > report.txt" from a command window), not a PowerShell pipeline.
# Test hooks (tests/run.ps1 only): AIM_CHECK_LIB, AIM_PIP_TIMEOUT, AIM_TEST_BUILD, AIM_TEST_MEM,
# AIM_TEST_ARCH, AIM_TEST_NET, AIM_TEST_GITROOTS.

param([switch]$Json, [switch]$PushTest)

# ai-mastery.xyz answers each address with a redirect to the same file on the main branch of
# pantyuhov9-web/aim-setup, so the repo can move without changing the command a student pastes.
$script:BaseUrl = 'https://ai-mastery.xyz'
$script:RunCmd = 'powershell -NoProfile -Command "irm ' + $script:BaseUrl + '/check.ps1 | iex"'
$script:PushCmd = 'powershell -NoProfile -Command "& ([scriptblock]::Create((irm ' + $script:BaseUrl + '/check.ps1))) -PushTest"'

# ---- records ---------------------------------------------------------------------------

function Add-Record {
  # fix is an array of hashtables @{ cmd = '...'; needs = '' | 'click' | 'browser' | 'new-window' | 'restart-app' }
  param([string]$Id, [string]$Group, [string]$Title, [string]$Status,
        [string]$Evidence, [string]$Why = '', $Fix = @())
  $script:Records += [pscustomobject]@{
    id = $Id; group = $Group; title = $Title; status = $Status
    evidence = $Evidence; why = $Why; fix = @($Fix)
  }
}

function Get-RecordStatus { # id -> its status, or '' when the check has not run
  param([string]$Id)
  foreach ($r in $script:Records) { if ($r.id -eq $Id) { return $r.status } }
  return ''
}

function Test-RecordPass {
  param([string]$Id)
  return ((Get-RecordStatus $Id) -eq 'pass')
}

function Set-RecordSettled { # a later check proved this one: it becomes a pass with no fix
  param([string]$Id, [string]$Evidence)
  foreach ($r in $script:Records) {
    if ($r.id -eq $Id) { $r.status = 'pass'; $r.evidence = $Evidence; $r.why = ''; $r.fix = @() }
  }
}

# ---- helpers ---------------------------------------------------------------------------

function Get-AppPath { # the full path of an external program on PATH, or '' when there is none
  param([string]$Name)
  $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
  if ($c) { return @($c)[0].Source }
  return ''
}

function Test-Have {
  param([string]$Name)
  return ((Get-AppPath $Name) -ne '')
}

function Get-OutputText { # decode a captured stream: UTF-8 when it is valid, the ANSI page otherwise
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -eq 0) { return '' }
  try {
    $strict = New-Object System.Text.UTF8Encoding $false, $true
    return $strict.GetString($bytes)
  } catch {
    return [System.Text.Encoding]::Default.GetString($bytes)
  }
}

function Invoke-Program {
  # Runs an external program with a timeout and returns @{ Code; Out; TimedOut }.
  # Output goes to files, so a program that fills a pipe buffer cannot deadlock the check.
  # Code 143 means the timeout stopped it, the number the macOS checker reports for the same case.
  param([string]$File, [string[]]$Arguments = @(), [int]$TimeoutSec = 10, [hashtable]$SetEnv = @{})
  $stem = Join-Path $script:Tmp ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $outFile = $stem + '.out'
  $errFile = $stem + '.err'
  $saved = @{}
  foreach ($k in $SetEnv.Keys) {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
    [Environment]::SetEnvironmentVariable($k, $SetEnv[$k], 'Process')
  }
  $result = @{ Code = 1; Out = ''; TimedOut = $false }
  try {
    $quoted = @()
    foreach ($a in $Arguments) {
      if ($a -match '[ "]') { $quoted += '"' + ($a -replace '"', '\"') + '"' } else { $quoted += $a }
    }
    $start = @{
      FilePath = $File; NoNewWindow = $true; PassThru = $true
      RedirectStandardOutput = $outFile; RedirectStandardError = $errFile
    }
    if ($quoted.Count -gt 0) { $start['ArgumentList'] = $quoted }
    $p = Start-Process @start -ErrorAction Stop
    # Reading .Handle once caches it. Without this, Start-Process -PassThru gives back an
    # object whose ExitCode is empty after the program ends, and every check that reads an
    # exit code would treat a success as a failure.
    $null = $p.Handle
    if ($p.WaitForExit($TimeoutSec * 1000)) {
      $result.Code = $p.ExitCode
    } else {
      $result.TimedOut = $true
      $result.Code = 143
      try { $p.Kill() } catch { }
      try { $p.WaitForExit(5000) | Out-Null } catch { }
    }
    $result.Out = (Get-OutputText $outFile) + (Get-OutputText $errFile)
  } catch {
    $result.Code = 127
    $result.Out = ''
  } finally {
    foreach ($k in $SetEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
  return $result
}

function Get-FirstLine {
  param([string]$Text)
  if (-not $Text) { return '' }
  # @() keeps a single line an array: in PowerShell 5.1 a one-element pipeline result is a
  # plain string, and indexing it would give one character.
  $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
  if ($lines.Count -gt 0) { return ([string]$lines[0]).Trim() }
  return ''
}

function Get-VersionDigits { # keep the leading digits of a version part: "14rc1" -> 14, "" -> 0
  param([string]$Part)
  $m = [regex]::Match([string]$Part, '^\d+')
  if ($m.Success) { return [int]$m.Value }
  return 0
}

function Test-VersionAtLeast { # major.minor comparison: "3.12.1" is at least "3.10"
  param([string]$Have, [string]$Want)
  $h = ([string]$Have).Split('.')
  $w = ([string]$Want).Split('.')
  $h1 = Get-VersionDigits $h[0]; $h2 = 0; if ($h.Count -gt 1) { $h2 = Get-VersionDigits $h[1] }
  $w1 = Get-VersionDigits $w[0]; $w2 = 0; if ($w.Count -gt 1) { $w2 = Get-VersionDigits $w[1] }
  if ($h1 -gt $w1) { return $true }
  if ($h1 -eq $w1 -and $h2 -ge $w2) { return $true }
  return $false
}

function Get-TildePath { # replace the home folder with ~ so a report never carries the user name
  param([string]$Path)
  $home1 = [string]$env:USERPROFILE
  if ($Path -and $home1 -and $Path.StartsWith($home1, [StringComparison]::OrdinalIgnoreCase)) {
    return '~' + $Path.Substring($home1.Length)
  }
  return $Path
}

function ConvertTo-JsonString { # escape backslash and double quote; the strings here hold no control characters
  param([string]$Text)
  return ([string]$Text).Replace('\', '\\').Replace('"', '\"')
}

function New-Fix {
  param([string]$Cmd, [string]$Needs = '')
  return @{ cmd = $Cmd; needs = $Needs }
}

function Test-Reachable {
  # One HTTPS request. Returns @{ Ok; Body }. AIM_TEST_NET lets the tests answer without a network:
  # "down:github.com,pypi.org" silences those hosts, "region" answers as an unsupported country.
  param([string]$Url, [int]$TimeoutSec = 10)
  $hook = [string]$env:AIM_TEST_NET
  if ($hook) {
    if ($hook -eq 'region' -and $Url -like '*claude.ai*') {
      return @{ Ok = $true; Body = '<html>App unavailable in region</html>' }
    }
    if ($hook -like 'down:*') {
      foreach ($h in ($hook.Substring(5) -split ',')) {
        if ($h -and $Url -like ('*' + $h.Trim() + '*')) { return @{ Ok = $false; Body = '' } }
      }
    }
    return @{ Ok = $true; Body = '#!/bin/bash' }
  }
  try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    $body = ''
    if ($r.Content) { $body = [string]$r.Content }
    if ($body.Length -gt 4000) { $body = $body.Substring(0, 4000) }
    return @{ Ok = $true; Body = $body }
  } catch {
    return @{ Ok = $false; Body = '' }
  }
}

# ---- system ----------------------------------------------------------------------------

function Invoke-SystemChecks {
  $build = Get-VersionDigits $env:AIM_TEST_BUILD
  if ($build -eq 0) { $build = [Environment]::OSVersion.Version.Build }
  if ($build -ge 17763) {
    Add-Record S1 system 'Версія Windows' pass ('Windows, збірка ' + $build)
  } else {
    Add-Record S1 system 'Версія Windows' fail ('збірка ' + $build + ', потрібна 17763 або новіша') `
      'Claude Code працює на Windows 10 версії 1809 і новіших. Оновіть систему: «Параметри», «Windows Update».'
  }

  $osIs64 = [Environment]::Is64BitOperatingSystem
  $procIs64 = [Environment]::Is64BitProcess
  if ($env:AIM_TEST_ARCH -eq 'os32') { $osIs64 = $false; $procIs64 = $false }
  if ($env:AIM_TEST_ARCH -eq 'proc32') { $procIs64 = $false }
  if (-not $osIs64) {
    Add-Record S2 system 'Розрядність' fail '32-розрядна Windows' `
      'Claude Code працює лише на 64-розрядній Windows. Цей компʼютер потребує заміни або перевстановлення системи.'
  } elseif (-not $procIs64) {
    Add-Record S2 system 'Розрядність' fail 'відкрито 32-розрядне вікно PowerShell' `
      'Ви відкрили «Windows PowerShell (x86)». Claude Code у ньому не працює. Закрийте це вікно, відкрийте «Windows PowerShell» без позначки (x86) і запустіть перевірку ще раз.'
  } else {
    Add-Record S2 system 'Розрядність' pass '64-розрядна Windows, 64-розрядне вікно'
  }

  $mem = 0
  if ($env:AIM_TEST_MEM) {
    $mem = [double]$env:AIM_TEST_MEM
  } else {
    try { $mem = [double](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { $mem = 0 }
  }
  $gb = [math]::Floor($mem / 1073741824)
  if ($mem -ge 4294967296) {
    Add-Record S3 system 'Оперативна памʼять' pass ($gb.ToString() + ' ГБ')
  } else {
    Add-Record S3 system 'Оперативна памʼять' warn ($gb.ToString() + ' ГБ, Claude Code потребує щонайменше 4 ГБ') `
      'На цьому компʼютері Claude Code працюватиме повільно.'
  }

  # The evidence names what is wrong with the path, never the path itself: it holds the user name.
  $profile1 = [string]$env:USERPROFILE
  $leaf = ''
  if ($profile1) { $leaf = Split-Path $profile1 -Leaf }
  if ($leaf -match '^[A-Za-z0-9._-]+$') {
    Add-Record S4 system 'Шлях до вашої папки' pass 'лише латинські літери й цифри'
  } else {
    $what = 'є символи, відмінні від латинських літер і цифр'
    if ($leaf -match '\s') { $what = 'є пробіл' }
    if ($leaf -match '[Ѐ-ӿ]') { $what = 'є кириличні літери' }
    Add-Record S4 system 'Шлях до вашої папки' warn ('у назві папки користувача ' + $what) `
      'Claude Code і деякі його розширення збиваються на таких шляхах: губиться історія сесій, частина розширень не запускається. Автоматичного виправлення немає. Якщо щось почне ламатися, напишіть кураторові: робочий обхід — новий користувач Windows з латинською назвою.'
  }

  $bad = @()
  $region = $false
  $script:NetOk = $true
  foreach ($h in 'https://github.com', 'https://pypi.org') {
    if (-not (Test-Reachable $h).Ok) { $bad += ($h -replace '^https://', '') }
  }
  $claude = Test-Reachable 'https://claude.ai/install.ps1'
  if (-not $claude.Ok -or -not $claude.Body) {
    $bad += 'claude.ai'
  } elseif ($claude.Body -match 'App unavailable in region') {
    $region = $true
  }
  if ($region) {
    Add-Record S5 system 'Інтернет' warn 'claude.ai відповідає, що сервіс недоступний у цій країні' `
      'Claude не працює в цій країні або через цей VPN. Вимкніть VPN чи змініть у ньому країну і запустіть перевірку ще раз.'
  } elseif ($bad.Count -gt 0) {
    $script:NetOk = $false
    Add-Record S5 system 'Інтернет' warn ('немає відповіді від: ' + ($bad -join ' ')) `
      'Перевірте підключення до інтернету і запустіть перевірку ще раз.'
  } else {
    Add-Record S5 system 'Інтернет' pass 'github.com, pypi.org і claude.ai відповідають'
  }

  $script:HasWinget = Test-Have 'winget'
  if ($script:HasWinget) {
    Add-Record S6 system 'winget' info 'знайдено: встановлення програм піде через нього'
  } else {
    Add-Record S6 system 'winget' info 'не знайдено: виправлення покажуть сторінки для завантаження' `
      'winget входить до «Установника програм» з Microsoft Store. Оновіть його в Store, щоб встановлювати програми однією командою.'
  }
}

# ---- Claude Code -----------------------------------------------------------------------

function Test-ClaudeDesktop {
  # The Windows desktop app ships as a packaged app: a folder under LOCALAPPDATA\Packages and an
  # alias in WindowsApps. A classic install under LOCALAPPDATA\Programs is checked as well.
  $local = [string]$env:LOCALAPPDATA
  if (-not $local) { return $false }
  if (Test-Path -LiteralPath (Join-Path $local 'Microsoft\WindowsApps\claude-desktop.exe')) { return $true }
  if (Get-ChildItem -LiteralPath (Join-Path $local 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue) { return $true }
  if (Get-ChildItem -LiteralPath (Join-Path $local 'Programs') -Directory -Filter 'claude*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Claude.exe') }) { return $true }
  return $false
}

function Invoke-ClaudeChecks {
  $cliPath = Get-AppPath 'claude'
  $cliFile = Join-Path ([string]$env:USERPROFILE) '.local\bin\claude.exe'
  $hasFile = Test-Path -LiteralPath $cliFile
  $installFix = New-Fix 'powershell -NoProfile -Command "irm https://claude.ai/install.ps1 | iex"' 'new-window'

  if ($script:Driver -eq 'claude') {
    $surface = [string]$env:CLAUDE_CODE_ENTRYPOINT
    if (-not $surface) { $surface = 'claude' }
    Add-Record C1 claude 'Claude Code' pass ('працює (' + $surface + ')')
  } else {
    $found = @()
    if ($cliPath -or $hasFile) { $found += 'термінал' }
    if (Test-ClaudeDesktop) { $found += 'застосунок' }
    if (Get-ChildItem -LiteralPath (Join-Path ([string]$env:USERPROFILE) '.vscode\extensions') -Directory `
          -Filter 'anthropic.claude-code-*' -ErrorAction SilentlyContinue) { $found += 'VS Code' }
    if ($found.Count -gt 0) {
      Add-Record C1 claude 'Claude Code' pass ('знайдено: ' + ($found -join ', '))
    } else {
      Add-Record C1 claude 'Claude Code' fail 'не знайдено' `
        'Встановіть Claude Code за кроком 0 з інструкції. Для термінала вставте цю команду.' @($installFix)
    }
  }

  if ($cliPath) {
    $v = Invoke-Program -File $cliPath -Arguments @('--version') -TimeoutSec 10
    $ver = Get-FirstLine $v.Out
    if (-not $ver) { $ver = 'знайдено' }
    Add-Record C2 claude 'Команда claude в терміналі' pass $ver
    $a = Invoke-Program -File $cliPath -Arguments @('auth', 'status') -TimeoutSec 15
    if ($a.Code -eq 0) {
      Add-Record C3 claude 'Вхід у Claude з термінала' pass 'вхід виконано'
    } else {
      Add-Record C3 claude 'Вхід у Claude з термінала' warn 'вхід не виконано' `
        'Наберіть claude у вікні термінала та увійдіть у свій обліковий запис у браузері.' `
        @((New-Fix 'claude' 'browser'))
    }
  } elseif ($hasFile) {
    # Anthropic's own fix, in one line that runs unchanged in CMD, PowerShell and Git Bash:
    # no $ and no % token, so no shell expands anything before PowerShell sees it.
    Add-Record C2 claude 'Команда claude в терміналі' fail 'Claude встановлено, але вікно не бачить команду' `
      'Windows шукає програми у списку папок PATH. Команда додає туди папку з Claude; вона змінює лише ваш список, не системний.' `
      @((New-Fix 'powershell -NoProfile -Command "[Environment]::SetEnvironmentVariable(''PATH'', [Environment]::GetEnvironmentVariable(''PATH'', ''User'') + '';'' + [Environment]::GetFolderPath(''UserProfile'') + ''\.local\bin'', ''User'')"' 'new-window'))
    Add-Record C3 claude 'Вхід у Claude з термінала' skip 'спершу потрібна команда claude'
  } else {
    Add-Record C2 claude 'Команда claude в терміналі' info 'термінальну версію не встановлено; для застосунку і VS Code вона не потрібна'
    Add-Record C3 claude 'Вхід у Claude з термінала' info 'без термінальної версії не перевіряється'
  }

  if (-not $cliPath) {
    Add-Record C4 claude 'Команда claude не перекрита' skip 'спершу потрібна команда claude'
  } elseif ($cliPath -match '(?i)\\WindowsApps\\') {
    Add-Record C4 claude 'Команда claude не перекрита' warn 'команда claude веде до застосунку, а не до Claude Code' `
      'Старі версії застосунку Claude реєстрували свій claude.exe так, що він перекриває Claude Code. Оновіть застосунок Claude до останньої версії.' `
      @((New-Fix 'winget upgrade --id Anthropic.Claude -e' 'restart-app'))
  } else {
    Add-Record C4 claude 'Команда claude не перекрита' pass 'команда claude веде до Claude Code'
  }
}

# ---- Git and GitHub --------------------------------------------------------------------

function Invoke-PushTest {
  # Returns @{ Code; Reason }. Code 0 = pushed, 2 = Git got no sign-in, 1 = anything else.
  # With no stored sign-in Git would print "Username for 'https://github.com':" and wait, or
  # Git Credential Manager would open a window. GIT_TERMINAL_PROMPT=0 stops the first, and the
  # manager's own documented setting stops the second, so the step fails at once instead.
  # An empty GIT_ASKPASS, which the macOS checker exports, cannot be passed here: Windows
  # deletes a variable that is set to an empty string.
  $noPrompt = @{ GIT_TERMINAL_PROMPT = '0' }
  $quiet = @('-c', 'credential.interactive=false')
  $u = Invoke-Program -File $script:GhPath -Arguments @('api', 'user', '-q', '.login') -TimeoutSec 20
  $login = Get-FirstLine $u.Out
  if ($u.Code -ne 0 -or -not $login) { return @{ Code = 1; Reason = 'не вдалося дізнатися обліковий запис GitHub' } }
  $repo = $login + '/aim-setup-check'
  $view = Invoke-Program -File $script:GhPath -Arguments @('repo', 'view', $repo) -TimeoutSec 20
  if ($view.Code -ne 0) {
    $create = Invoke-Program -File $script:GhPath -TimeoutSec 30 -Arguments @(
      'repo', 'create', 'aim-setup-check', '--private', '-d', 'Setup check for an A&I Mastery course. Safe to delete.')
    if ($create.Code -ne 0) { return @{ Code = 1; Reason = 'не вдалося створити сховище aim-setup-check' } }
  }
  $dir = Join-Path $script:Tmp 'push'
  # The repo is private, so the clone already needs Git's sign-in: a PC where Git has none stops
  # here, not at the push.
  $clone = Invoke-Program -File $script:GitPath -TimeoutSec 60 -SetEnv $noPrompt `
    -Arguments ($quiet + @('clone', '-q', ('https://github.com/' + $repo + '.git'), $dir))
  if ($clone.Code -ne 0) { return @{ Code = 2; Reason = 'не вдалося отримати сховище з GitHub' } }
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  Set-Content -LiteralPath (Join-Path $dir 'check.txt') -Value $stamp -Encoding ascii
  $gitDir = @('-C', $dir)
  $branch = Invoke-Program -File $script:GitPath -Arguments ($gitDir + @('checkout', '-q', '-B', 'main')) -TimeoutSec 20
  $add = Invoke-Program -File $script:GitPath -Arguments ($gitDir + @('add', 'check.txt')) -TimeoutSec 20
  # The scratch commit needs no signature, and a signing setup could stop to ask for a passphrase.
  $commit = Invoke-Program -File $script:GitPath -TimeoutSec 30 `
    -Arguments ($gitDir + @('-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'setup-check'))
  if ($branch.Code -ne 0 -or $add.Code -ne 0 -or $commit.Code -ne 0) {
    return @{ Code = 1; Reason = 'не вдалося зберегти зміну' }
  }
  $push = Invoke-Program -File $script:GitPath -TimeoutSec 60 -SetEnv $noPrompt `
    -Arguments ($gitDir + $quiet + @('push', '-q', '-u', 'origin', 'main'))
  if ($push.Code -ne 0) { return @{ Code = 2; Reason = 'GitHub не прийняв відправку' } }
  $head = Get-FirstLine (Invoke-Program -File $script:GitPath -Arguments ($gitDir + @('rev-parse', 'HEAD')) -TimeoutSec 20).Out
  $ls = Invoke-Program -File $script:GitPath -TimeoutSec 30 -SetEnv $noPrompt `
    -Arguments ($gitDir + $quiet + @('ls-remote', 'origin', 'refs/heads/main'))
  $remote = (Get-FirstLine $ls.Out) -split '\s+' | Select-Object -First 1
  if (-not $head -or $head -ne $remote) { return @{ Code = 1; Reason = 'GitHub не показує відправлену зміну' } }
  return @{ Code = 0; Reason = 'aim-setup-check' }
}

function Invoke-GitChecks {
  $sampleName = 'Імʼя Прізвище'
  $sampleEmail = 'you@example.com'
  $script:GitPath = Get-AppPath 'git'
  $script:GhPath = Get-AppPath 'gh'

  if ($script:GitPath) {
    $v = Invoke-Program -File $script:GitPath -Arguments @('--version') -TimeoutSec 10
    $ver = (Get-FirstLine $v.Out) -replace '^git version ', ''
    if (-not $ver) { $ver = 'знайдено' }
    Add-Record G1 github 'Git' pass $ver
  } else {
    if ($script:HasWinget) {
      $fix = @((New-Fix 'winget install --id Git.Git -e --source winget' 'click'))
      $why = 'Git зберігає історію ваших файлів і надсилає її на GitHub. Під час встановлення Windows запитає дозвіл.'
    } else {
      $fix = @((New-Fix 'https://git-scm.com/downloads/win' 'browser'))
      $why = 'Git зберігає історію ваших файлів і надсилає її на GitHub. winget не знайдено, тому відкрийте сторінку, завантажте Git для Windows і встановіть його, нічого не змінюючи у вікнах установника.'
    }
    Add-Record G1 github 'Git' fail 'не встановлено' $why $fix
  }

  # Claude Code runs shell commands through Git Bash when it finds one, and through PowerShell
  # otherwise. It looks in the two default install folders, then next to the git on PATH.
  if (Test-RecordPass G1) {
    # The two folders Claude Code looks in first. Windows gives every new process its own
    # ProgramFiles values, so these cannot be pointed elsewhere from outside: the tests pass
    # the folders to look in through AIM_TEST_GITROOTS instead.
    $roots = @((Join-Path ([string]$env:ProgramFiles) 'Git'), (Join-Path ([string]${env:ProgramFiles(x86)}) 'Git'))
    if ($env:AIM_TEST_GITROOTS) { $roots = @($env:AIM_TEST_GITROOTS -split ';') }
    $bash = ''
    $standard = $true
    foreach ($r in $roots) {
      if (-not $r) { continue }
      $p = Join-Path $r 'bin\bash.exe'
      if (Test-Path -LiteralPath $p) { $bash = $p; break }
    }
    if (-not $bash) {
      $root = Split-Path (Split-Path $script:GitPath -Parent) -Parent
      $candidate = Join-Path $root 'bin\bash.exe'
      if (Test-Path -LiteralPath $candidate) { $bash = $candidate; $standard = $false }
    }
    if ($bash -and $standard) {
      Add-Record G2 github 'Git Bash' pass 'знайдено у стандартній папці Git'
    } elseif ($bash) {
      Add-Record G2 github 'Git Bash' warn ('знайдено не у стандартній папці: ' + (Get-TildePath $bash)) `
        ('Claude Code шукає Git Bash у «Program Files». Щоб він узяв ваш, допишіть у файл ~\.claude\settings.json: "env": { "CLAUDE_CODE_GIT_BASH_PATH": "' + ((Get-TildePath $bash) -replace '\\', '\\') + '" } — і перезапустіть Claude. Без цього Claude Code виконує команди через PowerShell, і це теж працює.')
    } else {
      if ($script:HasWinget) {
        $fix = @((New-Fix 'winget install --id Git.Git -e --source winget' 'click'))
      } else {
        $fix = @((New-Fix 'https://git-scm.com/downloads/win' 'browser'))
      }
      Add-Record G2 github 'Git Bash' warn 'не знайдено разом з Git' `
        'Git Bash входить до Git для Windows. Без нього Claude Code виконує команди через PowerShell — це працює, але частина скриптів з уроків розрахована на Bash. Перевстановіть Git для Windows, не змінюючи нічого у вікнах установника.' $fix
    }
  } else {
    Add-Record G2 github 'Git Bash' skip 'спершу потрібен Git'
  }

  if (Test-RecordPass G1) {
    $name = Get-FirstLine (Invoke-Program -File $script:GitPath -Arguments @('config', '--global', 'user.name') -TimeoutSec 10).Out
    $email = Get-FirstLine (Invoke-Program -File $script:GitPath -Arguments @('config', '--global', 'user.email') -TimeoutSec 10).Out
    $why = 'Git підписує кожне збереження іменем і поштою. Підставте в лапках свої; пошта та сама, що в обліковому записі GitHub.'
    $fix = @(
      (New-Fix ('git config --global user.name "' + $sampleName + '"')),
      (New-Fix ('git config --global user.email "' + $sampleEmail + '"')))
    if (-not $name -or -not $email) {
      Add-Record G3 github 'Імʼя та пошта в Git' fail 'не вказано' $why $fix
    } elseif ($name -eq $sampleName -or $email -eq $sampleEmail) {
      # The two commands above were pasted without putting real values into the quotes.
      Add-Record G3 github 'Імʼя та пошта в Git' fail 'вказано зразок з підказки, а не ваші дані' $why $fix
    } else {
      Add-Record G3 github 'Імʼя та пошта в Git' pass 'вказано'
    }
  } else {
    Add-Record G3 github 'Імʼя та пошта в Git' skip 'спершу потрібен Git'
  }

  if ($script:GhPath) {
    $v = Invoke-Program -File $script:GhPath -Arguments @('--version') -TimeoutSec 10
    $ver = ((Get-FirstLine $v.Out) -replace '^gh version ', '') -replace ' .*$', ''
    if (-not $ver) { $ver = 'знайдено' }
    Add-Record G4 github 'GitHub CLI' pass $ver
  } else {
    if ($script:HasWinget) {
      $fix = @((New-Fix 'winget install --id GitHub.cli --source winget' 'new-window'))
      $why = 'GitHub CLI виконує вхід у GitHub через браузер, а Git потім користується цим входом. Після встановлення відкрийте нове вікно.'
    } else {
      $fix = @((New-Fix 'https://github.com/cli/cli/releases/latest' 'browser'))
      $why = 'GitHub CLI виконує вхід у GitHub через браузер, а Git потім користується цим входом. winget не знайдено, тому завантажте зі сторінки файл із назвою, що закінчується на windows_amd64.msi, і встановіть його.'
    }
    Add-Record G4 github 'GitHub CLI' fail 'не встановлено' $why $fix
  }

  if (-not (Test-RecordPass G4)) {
    Add-Record G5 github 'Вхід у GitHub' skip 'спершу потрібен GitHub CLI'
  } elseif (-not $script:NetOk) {
    Add-Record G5 github 'Вхід у GitHub' skip 'потрібен інтернет'
  } elseif ((Invoke-Program -File $script:GhPath -Arguments @('auth', 'status') -TimeoutSec 20).Code -eq 0) {
    Add-Record G5 github 'Вхід у GitHub' pass 'вхід виконано'
  } else {
    # Started by Claude, "gh auth login" has no window to ask in, so it signs in and leaves Git
    # unconnected. The second command connects Git in the same round.
    Add-Record G5 github 'Вхід у GitHub' fail 'вхід не виконано' `
      'Перша команда покаже одноразовий код і відкриє GitHub у браузері: введіть код і підтвердьте вхід. Друга дозволить Git користуватися цим входом.' `
      @((New-Fix 'gh auth login --web --git-protocol https' 'browser'), (New-Fix 'gh auth setup-git'))
  }

  # The check reads helper names only, never a stored credential. Git Credential Manager ships
  # with Git for Windows and is a sign-in route of its own, so it passes; any other helper is a
  # warning the push test settles.
  $otherHelper = ''
  if ((Test-RecordPass G1) -and (Test-RecordPass G5)) {
    $hostHelper = (Invoke-Program -File $script:GitPath -TimeoutSec 10 `
      -Arguments @('config', '--get-all', 'credential.https://github.com.helper')).Out
    $anyHelper = (Invoke-Program -File $script:GitPath -TimeoutSec 10 `
      -Arguments @('config', '--get-all', 'credential.helper')).Out
    $all = [string]$hostHelper + "`n" + [string]$anyHelper
    $otherHelper = Get-FirstLine $anyHelper
    if ($all -match 'gh auth git-credential') {
      Add-Record G6 github 'Git користується входом у GitHub' pass 'через GitHub CLI'
    } elseif ($all -match '(?im)^\s*manager(-core)?\s*$' -or $all -match '(?i)git-credential-manager') {
      Add-Record G6 github 'Git користується входом у GitHub' pass 'через Git Credential Manager'
    } elseif ($otherHelper) {
      Add-Record G6 github 'Git користується входом у GitHub' warn `
        ('Git має інший спосіб входу (' + (Get-TildePath $otherHelper) + '); перевірка не бачить, чи збережено в ньому вхід у GitHub') `
        'Якщо відправка на GitHub не спрацює, ця команда перемкне Git на вхід через GitHub CLI.' `
        @((New-Fix 'gh auth setup-git'))
    } else {
      Add-Record G6 github 'Git користується входом у GitHub' fail 'не налаштовано' `
        'Після цієї команди Git відправляє зміни на GitHub без пароля.' `
        @((New-Fix 'gh auth setup-git'))
    }
  } else {
    Add-Record G6 github 'Git користується входом у GitHub' skip 'спершу потрібні Git і вхід у GitHub'
  }

  if (-not $script:PushTest) {
    Add-Record G7 github 'Пробна відправка на GitHub' skip 'вимкнено; вмикається ключем -PushTest'
  } elseif ((Test-RecordPass G3) -and (Test-RecordPass G5) -and ((Get-RecordStatus G6) -ne 'fail')) {
    $r = Invoke-PushTest
    if ($r.Code -eq 0) {
      Add-Record G7 github 'Пробна відправка на GitHub' pass ('зміну відправлено у приватне сховище ' + $r.Reason)
      # A push that went through proves the sign-in route that G6 could not see into.
      if ((Get-RecordStatus G6) -eq 'warn') {
        Set-RecordSettled G6 ('працює через ' + (Get-TildePath $otherHelper) + '; пробна відправка це підтвердила')
      }
    } elseif ($r.Code -eq 2) {
      Add-Record G7 github 'Пробна відправка на GitHub' fail $r.Reason `
        'Команда перемикає Git на вхід через GitHub CLI. Після неї запустіть перевірку з пробною відправкою ще раз.' `
        @((New-Fix 'gh auth setup-git'))
    } else {
      Add-Record G7 github 'Пробна відправка на GitHub' fail $r.Reason `
        'Запустіть перевірку ще раз. Якщо помилка повторюється, надішліть звіт кураторові.'
    }
  } else {
    Add-Record G7 github 'Пробна відправка на GitHub' skip 'спершу виправте пункти вище'
  }
}

# ---- Python ----------------------------------------------------------------------------

function Add-SkippedPython {
  param([string]$Reason, [string[]]$Ids)
  foreach ($id in $Ids) {
    $title = 'Запуск скрипта'
    if ($id -eq 'P2') { $title = 'Версія Python' }
    if ($id -eq 'P3') { $title = 'Встановлення бібліотек' }
    Add-Record $id python $title skip $Reason
  }
}

function Invoke-PythonChecks {
  if ($script:HasWinget) {
    $fix = @(
      (New-Fix 'winget install 9NQ7512CXL7T -e --accept-package-agreements --disable-interactivity' 'new-window'),
      (New-Fix 'py install default' 'new-window'))
  } else {
    $fix = @((New-Fix 'https://www.python.org/downloads/' 'browser'))
  }
  $why = 'Python запускає скрипти з уроків.'

  # A command under WindowsApps is a Windows app-execution alias. A dead alias opens the
  # Microsoft Store instead of running Python, so a real Python is always probed first.
  $candidates = @()
  foreach ($n in 'python', 'py') {
    $p = Get-AppPath $n
    if ($p) { $candidates += [pscustomobject]@{ Path = $p; Alias = ($p -match '(?i)\\WindowsApps\\') } }
  }
  $candidates = @(@($candidates | Where-Object { -not $_.Alias }) + @($candidates | Where-Object { $_.Alias }))

  $probe = Join-Path $script:Tmp 'ver.py'
  Set-Content -LiteralPath $probe -Encoding ascii -Value @(
    'import sys',
    'print("aim-python %d.%d.%d" % sys.version_info[:3])')
  $found = ''
  $ver = ''
  foreach ($c in $candidates) {
    # The install manager installs a runtime on demand when one is missing; its own setting
    # turns that off, so a probe can never install Python.
    $r = Invoke-Program -File $c.Path -Arguments @($probe) -TimeoutSec 30 `
      -SetEnv @{ PYTHON_MANAGER_AUTOMATIC_INSTALL = '0' }
    $m = [regex]::Match([string]$r.Out, 'aim-python (\d+\.\d+\.\d+)')
    if ($m.Success) { $found = $c.Path; $ver = $m.Groups[1].Value; break }
  }

  if (-not $candidates -or -not $found) {
    $evidence = 'не встановлено'
    if ($candidates.Count -gt 0) { $evidence = 'знайдено, але не запускається' }
    Add-Record P1 python 'Python' fail $evidence $why $fix
    Add-SkippedPython 'спершу потрібен Python' @('P2', 'P3', 'P4')
    return
  }
  Add-Record P1 python 'Python' pass (Get-TildePath $found)

  if (Test-VersionAtLeast $ver '3.10') {
    Add-Record P2 python 'Версія Python' pass $ver
  } else {
    Add-Record P2 python 'Версія Python' fail ($ver + ', потрібна 3.10 або новіша') `
      'Скрипти курсу розраховані на Python 3.10 і новіші.' $fix
    Add-SkippedPython 'спершу потрібен новіший Python' @('P3', 'P4')
    return
  }

  if (-not $script:NetOk) {
    Add-SkippedPython 'потрібен інтернет' @('P3', 'P4')
    return
  }
  $venv = Join-Path $script:Tmp 'venv'
  $mk = Invoke-Program -File $found -Arguments @('-m', 'venv', $venv) -TimeoutSec 120
  $venvPy = Join-Path $venv 'Scripts\python.exe'
  if ($mk.Code -ne 0 -or -not (Test-Path -LiteralPath $venvPy)) {
    Add-Record P3 python 'Встановлення бібліотек' fail 'не вдалося створити окреме середовище' `
      'Запустіть перевірку ще раз. Якщо помилка повторюється, надішліть звіт кураторові.'
    Add-SkippedPython 'спершу мають встановлюватися бібліотеки' @('P4')
    return
  }
  $pipTimeout = 120
  if ($env:AIM_PIP_TIMEOUT) { $pipTimeout = [int]$env:AIM_PIP_TIMEOUT }
  $pip = Invoke-Program -File $venvPy -TimeoutSec $pipTimeout `
    -Arguments @('-m', 'pip', 'install', '--no-cache-dir', '--quiet', '--disable-pip-version-check', 'requests')
  if ($pip.TimedOut) {
    Add-Record P3 python 'Встановлення бібліотек' warn 'встановлення не завершилося за відведений час' `
      'Інтернет працює повільно. Запустіть перевірку ще раз.'
    Add-SkippedPython 'спершу мають встановлюватися бібліотеки' @('P4')
    return
  }
  if ($pip.Code -ne 0) {
    Add-Record P3 python 'Встановлення бібліотек' fail 'бібліотека requests не встановилася' `
      'Запустіть перевірку ще раз. Якщо помилка повторюється, надішліть звіт кураторові.'
    Add-SkippedPython 'спершу мають встановлюватися бібліотеки' @('P4')
    return
  }
  Add-Record P3 python 'Встановлення бібліотек' pass 'бібліотека requests встановилася'

  # The script is UTF-8 on purpose: it must print Ukrainian through a pipe, the thing that
  # breaks on an old console code page. Its output is decoded as UTF-8 first, then as the
  # ANSI page, so a working Python passes whichever encoding it chose.
  $script1 = Join-Path $script:Tmp 't.py'
  Set-Content -LiteralPath $script1 -Encoding utf8 -Value @(
    'import requests',
    'print("Привіт від Python")',
    'print("HTTPS", requests.head("https://github.com", timeout=10, allow_redirects=True).status_code)')
  $run = Invoke-Program -File $venvPy -Arguments @($script1) -TimeoutSec 30
  if ($run.Out -match 'Привіт від Python' -and $run.Out -match 'HTTPS 200') {
    Add-Record P4 python 'Запуск скрипта' pass 'скрипт надрукував український текст і відкрив сторінку'
  } elseif ($run.Out -match 'UnicodeEncodeError') {
    Add-Record P4 python 'Запуск скрипта' fail 'скрипт не зміг надрукувати український текст' `
      'Ваш Python друкує в старому кодуванні. Команда вмикає UTF-8 для всіх запусків Python.' `
      @((New-Fix 'setx PYTHONUTF8 1' 'new-window'))
  } else {
    Add-Record P4 python 'Запуск скрипта' fail 'скрипт не відпрацював' `
      'Запустіть перевірку ще раз. Якщо помилка повторюється, надішліть звіт кураторові.'
  }
}

# ---- report ----------------------------------------------------------------------------

function Write-Line {
  # Every printed line goes through here. In a window PowerShell writes to the console with the
  # Unicode console call, and Ukrainian text arrives intact whatever the code page is. Once the
  # output is redirected, PowerShell encodes it with the console code page instead, and a page
  # such as IBM437 has no Cyrillic: the text would arrive as question marks. Setting
  # [Console]::OutputEncoding here does not help, because PowerShell has already built the
  # writer it uses (measured on Windows PowerShell 5.1). Writing UTF-8 bytes straight to the
  # standard output stream is exact, so that is what the redirected path does.
  param([string]$Text = '')
  if ($null -ne $script:Out) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text + "`r`n")
    $script:Out.Write($bytes, 0, $bytes.Length)
  } else {
    Write-Output $Text
  }
}

function Get-Mark {
  param([string]$Status)
  switch ($Status) {
    'pass' { return '[OK]' }
    'fail' { return '[!!]' }
    'warn' { return '[! ]' }
    'info' { return '[i] ' }
    default { return '[--]' }
  }
}

function Get-FlagNote {
  param([string]$Needs)
  switch ($Needs) {
    'click' { return '   (натисніть «Так» або «Встановити», коли система запитає)' }
    'browser' { return '   (відкриється браузер)' }
    'new-window' { return '   (після цього відкрийте нове вікно)' }
    'restart-app' { return '   (після цього перезапустіть Claude)' }
    default { return '' }
  }
}

function Get-GroupName {
  param([string]$Group)
  switch ($Group) {
    'system' { return 'система' }
    'claude' { return 'Claude Code' }
    'github' { return 'GitHub' }
    default { return 'Python' }
  }
}

function Write-Report {
  $how = 'запуск із вікна термінала'
  if ($script:Driver -eq 'claude') { $how = 'запуск через Claude' }
  Write-Line ('Перевірка компʼютера для курсу A&I Mastery (Windows, ' + $how + ')')
  Write-Line ''
  $missing = @()
  $warns = 0
  $unchecked = 0
  foreach ($r in $script:Records) {
    Write-Line ((Get-Mark $r.status) + '  ' + $r.title + ': ' + $r.evidence)
    if ($r.status -eq 'fail') {
      $g = Get-GroupName $r.group
      if ($missing -notcontains $g) { $missing += $g }
    }
    if ($r.status -eq 'warn') { $warns++ }
    # A check that was skipped proves nothing. The push test left switched off is the one skip
    # that is a choice, not a gap.
    if ($r.status -eq 'skip' -and ($r.id -ne 'G7' -or $script:PushTest)) { $unchecked++ }
  }

  Write-Line ''
  if ($missing.Count -gt 0) {
    Write-Line ('Не вистачає: ' + ($missing -join ', ') + '.')
  } elseif ($unchecked -gt 0) {
    Write-Line 'Не все вдалося перевірити. Пропущені пункти позначені [--].'
  } elseif ($warns -gt 0) {
    Write-Line 'Головне працює. Є зауваження, вони позначені [! ].'
  } else {
    Write-Line 'Усе потрібне працює.'
  }

  $step = 0
  foreach ($r in $script:Records) {
    if (($r.status -eq 'fail' -or $r.status -eq 'warn') -and $r.why) {
      if ($step -eq 0) {
        Write-Line ''
        Write-Line 'Як виправити (по одній команді, у цьому ж вікні):'
      }
      $step++
      Write-Line ''
      Write-Line ($step.ToString() + '. ' + $r.title + '. ' + $r.why)
      foreach ($f in @($r.fix)) {
        if (-not $f.cmd) { continue }
        Write-Line ('   ' + $f.cmd)
        $note = Get-FlagNote $f.needs
        if ($note) { Write-Line $note }
      }
    }
  }
  if ($step -gt 0) {
    Write-Line ''
    Write-Line 'Після виправлень запустіть перевірку ще раз:'
    Write-Line ('   ' + $script:RunCmd)
  }

  Write-Line ''
  Write-Line '----- звіт для куратора -----'
  Write-Line ('aim-check windows ' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') + ' driver=' + $script:Driver)
  foreach ($r in $script:Records) {
    Write-Line ($r.id + ' ' + $r.status + ' ' + $r.evidence)
  }
  Write-Line '----- кінець звіту -----'
}

function Write-JsonBlock {
  Write-Line ''
  Write-Line '=== aim-check json ==='
  Write-Line '['
  for ($i = 0; $i -lt $script:Records.Count; $i++) {
    $r = $script:Records[$i]
    $fixes = @()
    foreach ($f in @($r.fix)) {
      if (-not $f.cmd) { continue }
      $fixes += ('{"cmd":"' + (ConvertTo-JsonString $f.cmd) + '","needs":"' + $f.needs + '"}')
    }
    $sep = ','
    if ($i -eq $script:Records.Count - 1) { $sep = '' }
    Write-Line ('{"id":"' + $r.id + '","status":"' + $r.status + '","group":"' + $r.group +
      '","title":"' + (ConvertTo-JsonString $r.title) + '","evidence":"' + (ConvertTo-JsonString $r.evidence) +
      '","why":"' + (ConvertTo-JsonString $r.why) + '","fix":[' + ($fixes -join ',') + ']}' + $sep)
  }
  Write-Line ']'
  Write-Line '=== end json ==='
}

function Write-Procedure {
  Write-Line ''
  Write-Line '=== порядок дій для Claude ==='
  Write-Line '1. Розкажи учневі простими словами, що працює і чого не вистачає.'
  Write-Line '2. Виправляй по одному, згори донизу, тільки пункти зі статусом fail. Бери тільки команди з розділу «Як виправити». Перед кожною командою поясни одним реченням, що вона зробить. Пункти warn поясни учневі, їхніх команд не виконуй.'
  Write-Line '3. Імʼя, пошту, натискання кнопок і вхід у браузері питай в учня. Не вигадуй їх.'
  Write-Line '4. Якщо команда не спрацювала двічі, зупинись і покажи учневі блок «звіт для куратора». Інших способів встановлення не шукай.'
  Write-Line '5. Після виправлень попроси учня закрити й знову відкрити програму або вікно термінала і вставити той самий запит ще раз.'
  Write-Line ('6. Коли жоден пункт не має статусу fail, запитай дозволу на пробну відправку і запусти: ' + $script:PushCmd)
  Write-Line '7. Якщо пробна відправка не пройшла, виконай команду з її пункту і запусти відправку ще раз.'
  Write-Line '8. Заверши одним реченням з підсумком.'
  Write-Line '=== кінець ==='
}

# ---- main ------------------------------------------------------------------------------

function Invoke-Main {
  param([switch]$Json, [switch]$PushTest)
  $script:Records = @()
  $script:NetOk = $true
  $script:HasWinget = $false
  $script:GitPath = ''
  $script:GhPath = ''
  $script:PushTest = [bool]$PushTest
  $wantJson = [bool]$Json
  $script:Driver = 'terminal'
  if ($env:CLAUDECODE -eq '1') { $script:Driver = 'claude'; $wantJson = $true }

  # Redirected output needs the UTF-8 byte path; see Write-Line. A window needs nothing.
  $script:Out = $null
  if ([Console]::IsOutputRedirected) {
    try { $script:Out = [Console]::OpenStandardOutput() } catch { $script:Out = $null }
  }
  # Old Windows 10 can refuse HTTPS without TLS 1.2. SystemDefault means Windows picks, which
  # is the better setting, so it is left alone.
  try {
    $sp = [Net.ServicePointManager]::SecurityProtocol
    if ($sp -ne 0 -and -not ($sp -band [Net.SecurityProtocolType]::Tls12)) {
      [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12
    }
  } catch { }

  $script:Tmp = Join-Path ([string]$env:TEMP) ('aimcheck-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
  try {
    foreach ($f in 'Invoke-SystemChecks', 'Invoke-ClaudeChecks', 'Invoke-GitChecks', 'Invoke-PythonChecks') {
      if (Get-Command $f -CommandType Function -ErrorAction SilentlyContinue) { & $f }
    }
    Write-Report
    if ($wantJson) { Write-JsonBlock }
    if ($script:Driver -eq 'claude') { Write-Procedure }
  } finally {
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    # Flushed, never disposed: disposing would close the process's own output handle.
    if ($null -ne $script:Out) { try { $script:Out.Flush() } catch { } }
  }

  $script:Rc = 0
  foreach ($r in $script:Records) { if ($r.status -eq 'fail') { $script:Rc = 1 } }
  # Never "exit": pasted into an open window it would close the window. SetShouldExit sets the
  # process result and lets the script finish; it runs only when the output is redirected, which
  # is where a result is read at all. The code is never returned into the success stream, which
  # carries the report.
  if ([Console]::IsOutputRedirected) { $host.SetShouldExit($script:Rc) }
}

# AIM_CHECK_LIB=1 lets tests load the functions without running the check.
if ($env:AIM_CHECK_LIB -ne '1') { Invoke-Main -Json:$Json -PushTest:$PushTest }
