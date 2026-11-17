# aim-setup: Windows transport probe. Read-only: it prints facts the Windows checker will
# depend on and changes nothing. It is temporary and is removed when the Windows checker lands.
$line = 'Привіт, це перевірка української мови'
Write-Output "text: $line"
Write-Output ("powershell: " + $PSVersionTable.PSVersion.ToString())
Write-Output ("64-bit process: " + [Environment]::Is64BitProcess)
Write-Output ("windows build: " + [Environment]::OSVersion.Version.Build)
Write-Output ("tls: " + [Net.ServicePointManager]::SecurityProtocol)
Write-Output ("console output encoding: " + [Console]::OutputEncoding.WebName)
Write-Output ("output redirected: " + [Console]::IsOutputRedirected)
Write-Output ("culture: " + (Get-Culture).Name)
