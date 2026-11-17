# aim-setup: setup check for Windows, for students of A&I Mastery courses built on Claude Code.
# It answers one question: do Claude Code, Git-to-GitHub sync and Python scripts work here?
#
# Run:       powershell -NoProfile -Command "irm https://raw.githubusercontent.com/pantyuhov9-web/aim-setup/main/check.ps1 | iex"
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

# The address moves to https://ai-mastery.xyz once that site redirects to this repo.
$script:BaseUrl = 'https://raw.githubusercontent.com/pantyuhov9-web/aim-setup/main'
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
