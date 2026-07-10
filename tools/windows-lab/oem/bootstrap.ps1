$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = "C:\EtherGuard"
$oem = "C:\OEM"
$log = Join-Path $root "logs\bootstrap.log"
New-Item -ItemType Directory -Force -Path $root, "$root\src", "$root\bin", "$root\config", "$root\logs" | Out-Null

function Expand-Zip {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $shell = New-Object -ComObject Shell.Application
    $source = $shell.NameSpace($Archive)
    $target = $shell.NameSpace($Destination)
    if (-not $source -or -not $target) { throw "cannot open archive $Archive" }
    $target.CopyHere($source.Items(), 0x14)
}

function Wait-ForPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $deadline = (Get-Date).AddMinutes(2)
    while (-not (Test-Path $Path)) {
        if ((Get-Date) -ge $deadline) { throw "timed out waiting for $Path" }
        Start-Sleep -Seconds 1
    }
}

$isWin7 = [Environment]::OSVersion.Version.Major -eq 6 -and [Environment]::OSVersion.Version.Minor -eq 1
$transcribing = -not $isWin7
if ($transcribing) { Start-Transcript -Path $log -Append }
try {
    $win7Updates = @(
        @{ Id = "KB4490628"; File = "Windows6.1-KB4490628-x64.msu" },
        @{ Id = "KB4474419"; File = "Windows6.1-KB4474419-v3-x64.msu" }
    )
    $win7UpdateInstalled = $false
    if ($isWin7) {
        foreach ($item in $win7Updates) {
            if (Get-HotFix -Id $item.Id -ErrorAction SilentlyContinue) { continue }
            $update = Join-Path $oem $item.File
            if (-not (Test-Path $update)) { throw "Windows 7 update $($item.Id) is missing" }
            $process = Start-Process wusa.exe -ArgumentList "`"$update`" /quiet /norestart" -Wait -PassThru
            if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
                throw "$($item.Id) installation failed with exit code $($process.ExitCode)"
            }
            $win7UpdateInstalled = $true
        }
    }
    if ($win7UpdateInstalled) {
        $scriptPath = $MyInvocation.MyCommand.Path
        $runOnce = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        New-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "EtherGuardBootstrap" -Value $runOnce -PropertyType String -Force | Out-Null
        & shutdown.exe /r /t 5
        return
    }

    $tapArchive = Join-Path $oem $(if ($isWin7) { "dist.win7.zip" } else { "dist.win10.zip" })
    $tapRoot = Join-Path $env:TEMP "tap-windows6"
    $tapEntity = Get-WmiObject Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like "ROOT\NET\*" -and $_.Name -like "*TAP-Windows*" } | Select-Object -First 1
    $tapNeedsInstall = -not $tapEntity -or $tapEntity.ConfigManagerErrorCode -ne 0
    if (-not $tapNeedsInstall -and $isWin7) {
        try { Start-Service tap0901 -ErrorAction Stop } catch { $tapNeedsInstall = $true }
    }

    if ($tapNeedsInstall) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tapRoot
        Expand-Zip -Archive $tapArchive -Destination $tapRoot
        $installerName = if ($isWin7) { "tapinstall.exe" } else { "devcon.exe" }
        Wait-ForPath -Path (Join-Path $tapRoot "$(if ($isWin7) { 'dist.win7' } else { 'dist.win10' })\amd64\$installerName")
        $installer = Get-ChildItem $tapRoot -Recurse -Include devcon.exe,tapinstall.exe |
            Where-Object { $_.FullName -match "amd64" } | Select-Object -First 1
        $inf = Get-ChildItem $tapRoot -Recurse -Filter OemVista.inf |
            Where-Object { $_.FullName -match "amd64" } | Select-Object -First 1
        if (-not $installer -or -not $inf) { throw "TAP-Windows6 amd64 installer files are missing" }
        if ($isWin7) {
            $catalog = Get-ChildItem $tapRoot -Recurse -Filter tap0901.cat |
                Where-Object { $_.FullName -match "amd64" } | Select-Object -First 1
            if (-not $catalog) { throw "TAP-Windows6 amd64 catalog is missing" }
            $signature = Get-AuthenticodeSignature $catalog.FullName
            if (-not $signature.SignerCertificate) { throw "TAP-Windows6 catalog signer is missing" }
            $publisher = Join-Path $env:TEMP "tap-windows6-publisher.cer"
            [System.IO.File]::WriteAllBytes($publisher, $signature.SignerCertificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            & certutil.exe -addstore -f TrustedPublisher $publisher | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "failed to trust the pinned TAP-Windows6 publisher certificate" }
            & $installer.FullName remove TAP0901 | Out-Null
        }
        & $installer.FullName install $inf.FullName TAP0901
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) { throw "TAP-Windows6 installation failed with exit code $LASTEXITCODE" }
        if ($LASTEXITCODE -eq 1) {
            $scriptPath = $MyInvocation.MyCommand.Path
            $runOnce = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
            New-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "EtherGuardBootstrap" -Value $runOnce -PropertyType String -Force | Out-Null
            & shutdown.exe /r /t 5
            return
        }
    }

    $tap = Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.PNPDeviceID -like "ROOT\NET\*" -and $_.Name -like "*TAP-Windows*" } | Select-Object -First 1
    if (-not $tap) { throw "TAP-Windows6 adapter was not found after installation" }
    if ($tap.NetConnectionID -ne "tap1") {
        $connectionKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}\$($tap.GUID)\Connection"
        if ((Get-ItemProperty -Path $connectionKey -Name Name).Name -ne $tap.NetConnectionID) {
            Set-ItemProperty -Path $connectionKey -Name Name -Value $tap.NetConnectionID
        }
        & netsh.exe interface set interface "name=$($tap.NetConnectionID)" "newname=tap1"
        if ($LASTEXITCODE -ne 0) { throw "failed to rename TAP adapter with exit code $LASTEXITCODE" }
    }

    $goVersion = if ($isWin7) { "1.20.14" } else { "1.26.5" }
    if ($isWin7) {
        $goBin = Join-Path $env:ProgramFiles "Go\bin"
        $goExe = Join-Path $goBin "go.exe"
        $installedVersion = if (Test-Path $goExe) { (& $goExe version) -join "" } else { "" }
        if ($installedVersion -notlike "*go$goVersion windows/amd64*") {
            $msi = Join-Path $oem "go$goVersion.windows-amd64.msi"
            $process = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "Go installation failed with exit code $($process.ExitCode)" }
        }
    } else {
        $toolchainRoot = Join-Path $root "toolchains\go$goVersion"
        $goBin = Join-Path $toolchainRoot "go\bin"
        $goExe = Join-Path $goBin "go.exe"
        if (-not (Test-Path $goExe)) {
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $toolchainRoot
            New-Item -ItemType Directory -Force -Path $toolchainRoot | Out-Null
            $archive = Join-Path $oem "go$goVersion.windows-amd64.zip"
            & tar.exe -xf $archive -C $toolchainRoot
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $goExe)) {
                throw "Go archive extraction failed with exit code $LASTEXITCODE"
            }
        }
    }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if (($machinePath -split ";") -notcontains $goBin) {
        [Environment]::SetEnvironmentVariable("Path", "$goBin;$machinePath", "Machine")
    }

    if ($isWin7) {
        $sshRoot = "C:\Program Files\OpenSSH"
        if (-not (Test-Path "$sshRoot\sshd.exe")) {
            $sshTemp = Join-Path $env:TEMP "OpenSSH-Win64"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $sshTemp
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $sshRoot
            Expand-Zip -Archive (Join-Path $oem "OpenSSH-Win64-7.7.2.zip") -Destination $env:TEMP
            Wait-ForPath -Path "$sshTemp\sshd.exe"
            Move-Item "$env:TEMP\OpenSSH-Win64" $sshRoot
            & "$sshRoot\install-sshd.ps1"
        }
    } else {
        $capability = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"
        if ($capability.State -ne "Installed") { Add-WindowsCapability -Online -Name $capability.Name | Out-Null }
    }

    $sshConfig = "$env:ProgramData\ssh\sshd_config"
    New-Item -ItemType Directory -Force -Path (Split-Path $sshConfig) | Out-Null
    @(
        "PubkeyAuthentication yes"
        "PasswordAuthentication no"
        "PermitEmptyPasswords no"
        "AuthorizedKeysFile .ssh/authorized_keys"
        "SyslogFacility LOCAL0"
        "LogLevel VERBOSE"
    ) | Set-Content -Encoding ascii $sshConfig
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    Copy-Item -Force (Join-Path $oem "authorized_keys") (Join-Path $sshDir "authorized_keys")
    Set-Service sshd -StartupType Automatic
    if ((Get-Service sshd).Status -eq "Running") { Restart-Service sshd } else { Start-Service sshd }

    & netsh.exe advfirewall firewall show rule "name=EtherGuard SSH" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & netsh.exe advfirewall firewall add rule "name=EtherGuard SSH" dir=in action=allow protocol=TCP localport=22 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "failed to add SSH firewall rule" }
    }
    & netsh.exe advfirewall firewall show rule "name=EtherGuard UDP" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & netsh.exe advfirewall firewall add rule "name=EtherGuard UDP" dir=in action=allow protocol=UDP localport=30001 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "failed to add EtherGuard firewall rule" }
    }
} catch {
    Write-Error $_
    throw
} finally {
    if ($transcribing) { Stop-Transcript }
}
