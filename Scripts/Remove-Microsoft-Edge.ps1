$Script:LogDir  = Join-Path $env:ProgramData 'Kairo Tweaks\Logs'
$Script:LogFile = Join-Path $Script:LogDir 'EdgeCleanup.log'
$Script:BridgeDir = Join-Path $env:ProgramData 'Kairo Tweaks\EdgeLinkBridge'

New-Item -ItemType Directory -Path $Script:LogDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-CleanupLog {
    param([string]$Message)

    if ((Test-Path $Script:LogFile) -and (Get-Item $Script:LogFile).Length -gt 500KB) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Set-Content -Path $Script:LogFile -Value "$timestamp - log rotated (previous file exceeded 500KB)"
    }

    $line = "{0} - {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $Script:LogFile -Value $line
    Write-Host $Message
}

function Get-LegacyEdgePackageName {
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages' -Name -ErrorAction SilentlyContinue |
        Where-Object { $_ -like 'Microsoft-Windows-Internet-Browser-Package~*' } |
        Select-Object -First 1
}

function Test-LegacyEdgePresent {
    $pkg = Get-LegacyEdgePackageName
    if (-not $pkg) { return $false }
    $info = & dism.exe /online /Get-PackageInfo /PackageName:$pkg 2>$null
    return [bool]($info -match 'State\s*:\s*Installed')
}

function Test-ChromiumEdgePresent {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (Test-Path (Join-Path $base 'Microsoft\Edge\Application\msedge.exe')) { return $true }
    }
    $pkg = Get-AppxPackage -AllUsers -Name 'Microsoft.MicrosoftEdge.Stable' -ErrorAction SilentlyContinue
    return [bool]$pkg
}

function Stop-EdgeRelatedProcesses {
    $names = 'msedge', 'msedgewebview2', 'MicrosoftEdgeUpdate', 'OneDrive', 'WidgetService', 'Widgets'
    foreach ($name in $names) {
        $running = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($running) {
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-CleanupLog "Stopped $($running.Count) process(es) named $name"
        }
    }
}

function Uninstall-LegacyEdge {
    $pkg = Get-LegacyEdgePackageName
    if (-not $pkg) { return }

    Write-CleanupLog "Removing legacy Edge component package: $pkg"
    $pkgRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$pkg"
    Set-ItemProperty -Path $pkgRegPath -Name 'Visibility' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Remove-Item "$pkgRegPath\Owners" -Recurse -Force -ErrorAction SilentlyContinue

    $attempt = 0
    $succeeded = $false
    while (-not $succeeded -and $attempt -lt 2) {
        $attempt++
        $proc = Start-Process dism.exe -ArgumentList "/online /Remove-Package /PackageName:$pkg" -NoNewWindow -PassThru
        $succeeded = $proc.WaitForExit(45000)
        if (-not $succeeded) {
            Write-CleanupLog "DISM removal attempt $attempt did not finish in time; terminating and retrying"
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    Write-CleanupLog $(if ($succeeded) { 'DISM package removal completed' } else { 'DISM package removal did not confirm completion; continuing anyway' })

    Get-AppxPackage -AllUsers -Name 'Microsoft.MicrosoftEdge' -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
}

function Uninstall-ChromiumEdge {
    Write-CleanupLog 'Removing Chromium-based Edge'

    $reprovisionPath = Join-Path $env:WINDIR 'SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe'
    New-Item -Path $reprovisionPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    New-Item -Path (Join-Path $reprovisionPath 'MicrosoftEdge.exe') -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null

    Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props.DisplayName -like 'Microsoft Edge*' -and $props.UninstallString) {
            Stop-EdgeRelatedProcesses
            $args = if ($props.UninstallString -match 'msiexec') { "$($props.UninstallString) /quiet" }
                    else { "$($props.UninstallString) --force-uninstall --silent" }
            Write-CleanupLog "Running uninstaller: $($props.DisplayName)"
            Start-Process cmd.exe -ArgumentList "/c $args" -WindowStyle Hidden -Wait
        }
    }
    Get-AppxPackage -AllUsers -Name 'Microsoft.MicrosoftEdge.Stable' -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue

    Uninstall-EdgeUpdater
}

function Uninstall-EdgeUpdater {
    $updaterExes = foreach ($folderType in 'LocalApplicationData', 'ProgramFilesX86', 'ProgramFiles') {
        $root = [Environment]::GetFolderPath($folderType)
        Get-ChildItem (Join-Path $root 'Microsoft\EdgeUpdate\*\MicrosoftEdgeUpdate.exe') -ErrorAction SilentlyContinue
    }
    if (-not $updaterExes) {
        Write-CleanupLog 'No EdgeUpdate installation found'
        return
    }

    $backup = Join-Path $env:TEMP "EdgeUpdateClientState_$(Get-Date -Format 'yyyyMMddHHmmss').reg"
    $clientStateKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState'
    $hasBackup = $false
    if (Test-Path $clientStateKey) {
        cmd /c "reg export `"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\ClientState`" `"$backup`" /y" 2>$null
        $hasBackup = Test-Path $backup
    }

    foreach ($exe in $updaterExes) {
        Write-CleanupLog "Unregistering EdgeUpdate: $($exe.FullName)"
        Start-Process $exe.FullName -ArgumentList '/unregsvc' -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Process $exe.FullName -ArgumentList '/uninstall' -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
    }

    if ($hasBackup) {
        cmd /c "reg import `"$backup`"" 2>$null
        Remove-Item $backup -Force -ErrorAction SilentlyContinue
        Write-CleanupLog 'Restored EdgeUpdate client-state registry values'
    }
}

function Clear-EdgeRegistryFootprint {
    Write-CleanupLog 'Clearing Edge registry footprint'

    @(
        'HKLM:\SOFTWARE\Microsoft\Edge',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge',
        'HKCU:\Software\Microsoft\Edge',
        'HKCU:\Software\Microsoft\EdgeUpdate',
        'HKLM:\SOFTWARE\Clients\StartMenuInternet\Microsoft Edge',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MicrosoftEdge',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
        'HKLM:\SYSTEM\CurrentControlSet\Services\Eventlog\Application\Edge',
        'HKLM:\SYSTEM\CurrentControlSet\Services\Eventlog\Application\edgeupdate',
        'HKLM:\SYSTEM\CurrentControlSet\Services\Eventlog\Application\edgeupdatem'
    ) | Where-Object { Test-Path $_ } | ForEach-Object {
        Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
    }

    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\RegisteredApplications' -Name 'Microsoft Edge' -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage\AppLaunch' -Name 'MSEdge' -Force -ErrorAction SilentlyContinue

    foreach ($root in 'HKLM:\SOFTWARE\Classes', 'HKLM:\SOFTWARE\Classes\WOW6432Node', 'HKLM:\SOFTWARE\WOW6432Node\Classes') {
        Get-ChildItem $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like 'MicrosoftEdgeUpdate*' -or $_.PSChildName -like 'MSEdge*' } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    $muiCache = 'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'
    if (Test-Path $muiCache) {
        (Get-ItemProperty $muiCache -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.Name -like '*Edge*' } |
            ForEach-Object { Remove-ItemProperty -Path $muiCache -Name $_.Name -Force -ErrorAction SilentlyContinue }
    }
}

function Clear-EdgeFileFootprint {
    Write-CleanupLog 'Clearing leftover Edge folders'

    Get-ChildItem (Join-Path $env:SystemDrive 'Program Files (x86)\Microsoft') -Directory -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -like '*Edge*' -or $_.Name -like '*Temp*') -and $_.Name -notlike '*EdgeWebView*' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Remove-Item (Join-Path $env:ProgramData 'Microsoft\EdgeUpdate') -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $env:WINDIR 'Temp\MsEdgeCrashpad') -Recurse -Force -ErrorAction SilentlyContinue

    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'NTUSER.DAT') } |
        ForEach-Object { Remove-Item (Join-Path $_.FullName 'AppData\Local\Microsoft\Edge') -Recurse -Force -ErrorAction SilentlyContinue }
}

function Clear-EdgeShortcuts {
    $targets = @('C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk')

    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'NTUSER.DAT') } |
        ForEach-Object {
            $targets += Join-Path $_.FullName 'Desktop\Microsoft Edge.lnk'
            $targets += Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk'
            $targets += Join-Path $_.FullName 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk'
            $targets += Join-Path $_.FullName 'AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Microsoft Edge.lnk'
        }

    $removed = 0
    foreach ($path in $targets) {
        if (Test-Path $path -PathType Leaf) {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    Write-CleanupLog "Removed $removed Edge shortcut(s)"
}

function Remove-EdgeScheduledTasks {
    Get-ScheduledTask -TaskName '*Edge*' -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -notin @('EdgeRemoval', 'KairoEdgeLinkRepair') } |
        ForEach-Object {
            Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
            Write-CleanupLog "Removed scheduled task: $($_.TaskName)"
        }
}

function New-BridgeExecutable {
    param([string]$Path)
    if (Test-Path $Path) { return $true }

    Copy-Item (Join-Path $env:WINDIR 'System32\systray.exe') $Path -Force -ErrorAction SilentlyContinue
    return (Test-Path $Path)
}

function Get-RedirectHandlerSource {
    return @'
$callArgs = $args
if ($callArgs.Count -lt 2) { return }
$payload = $callArgs[1]

$decoded = [System.Uri]::UnescapeDataString($payload)
$linkMatch = [regex]::Match($decoded, 'https?://\S+')
$destination = if ($linkMatch.Success) { $linkMatch.Value.TrimEnd('"', "'") } else { $payload }

function Resolve-DefaultBrowserCommand {
    $userChoice = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction SilentlyContinue
    if ($userChoice.ProgId -and $userChoice.ProgId -notlike 'MSEdge*') {
        $cmd = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$($userChoice.ProgId)\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
        if ($cmd) { return $cmd }
    }
    foreach ($hive in 'HKLM:', 'HKCU:') {
        $clients = Get-ChildItem "$hive\SOFTWARE\Clients\StartMenuInternet" -ErrorAction SilentlyContinue
        foreach ($client in $clients) {
            $cmd = (Get-ItemProperty "$($client.PSPath)\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
            if ($cmd -and $cmd -notmatch 'msedge|iexplore|KairoBrowserBridge') { return $cmd }
        }
    }
    return $null
}

$browserCommand = Resolve-DefaultBrowserCommand
if (-not $browserCommand) { return }

$browserExe = ($browserCommand -split '"')[1]
if ($browserExe -and (Test-Path $browserExe)) {
    Start-Process -FilePath $browserExe -ArgumentList $destination
}
'@
}

function Get-RepairTaskSource {
    param([string]$BridgePath, [string]$HandlerPath)

    $template = @'
$bridge = '__BRIDGE_PATH__'
$handler = '__HANDLER_PATH__'
if (-not (Test-Path $bridge)) { exit }
if (-not (Test-Path $handler)) { exit }

$expectedProtocolCmd = '"' + $bridge + '" %1'
$currentProtocolCmd = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\microsoft-edge\shell\open\command' -ErrorAction SilentlyContinue).'(default)'
if ($currentProtocolCmd -ne $expectedProtocolCmd) {
    reg.exe add "HKCR\microsoft-edge\shell\open\command" /f /ve /d $expectedProtocolCmd | Out-Null
}

$currentHtmCmd = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\MSEdgeHTM\shell\open\command' -ErrorAction SilentlyContinue).'(default)'
if ($currentHtmCmd -ne $expectedProtocolCmd) {
    reg.exe add "HKCR\MSEdgeHTM\shell\open\command" /f /ve /d $expectedProtocolCmd | Out-Null
}
'@

    $template.Replace('__BRIDGE_PATH__', $BridgePath).Replace('__HANDLER_PATH__', $HandlerPath)
}

function Install-EdgeLinkBridge {
    Write-CleanupLog 'Setting up Edge link redirect'
    New-Item -ItemType Directory -Path $Script:BridgeDir -Force -ErrorAction SilentlyContinue | Out-Null

    $bridgeExe = Join-Path $Script:BridgeDir 'KairoBrowserBridge.exe'
    if (-not (New-BridgeExecutable -Path $bridgeExe)) {
        Write-CleanupLog 'Could not create the bridge executable - skipping link redirect setup'
        return $false
    }

    $handlerPath = Join-Path $Script:BridgeDir 'RedirectHandler.ps1'
    Get-RedirectHandlerSource | Set-Content -Path $handlerPath -Encoding UTF8 -Force

    $debuggerCommand = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$handlerPath`""
    $ifeoKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\KairoBrowserBridge.exe'
    New-Item -Path $ifeoKey -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path $ifeoKey -Name 'Debugger' -Value $debuggerCommand -Force

    reg.exe add 'HKCR\microsoft-edge' /f /ve /d 'URL:microsoft-edge' | Out-Null
    reg.exe add 'HKCR\microsoft-edge' /f /v 'URL Protocol' /d '' | Out-Null
    reg.exe add 'HKCR\microsoft-edge\shell\open\command' /f /ve /d "`"$bridgeExe`" %1" | Out-Null
    reg.exe add 'HKCR\MSEdgeHTM\shell\open\command' /f /ve /d "`"$bridgeExe`" %1" | Out-Null
    reg.exe delete 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\msedge.exe' /f 2>$null | Out-Null

    $repairScriptPath = Join-Path $Script:BridgeDir 'RepairAssociations.ps1'
    Get-RepairTaskSource -BridgePath $bridgeExe -HandlerPath $handlerPath | Set-Content -Path $repairScriptPath -Encoding UTF8 -Force

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$repairScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'KairoEdgeLinkRepair' -TaskPath '\Kairo Tweaks\' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

    Write-CleanupLog 'Edge link redirect installed'
    return $true
}

Write-CleanupLog '=== Starting Edge removal ==='

$hasLegacy = Test-LegacyEdgePresent
$hasChromium = Test-ChromiumEdgePresent

if (-not $hasLegacy -and -not $hasChromium) {
    Write-CleanupLog 'No Edge installation detected - nothing to remove'
} else {
    Stop-EdgeRelatedProcesses
    if ($hasLegacy) { Uninstall-LegacyEdge }
    if ($hasChromium) { Uninstall-ChromiumEdge }

    Clear-EdgeFileFootprint
    Clear-EdgeShortcuts
    Clear-EdgeRegistryFootprint
}

Install-EdgeLinkBridge | Out-Null
Remove-EdgeScheduledTasks

Write-CleanupLog '=== Edge removal finished ==='
