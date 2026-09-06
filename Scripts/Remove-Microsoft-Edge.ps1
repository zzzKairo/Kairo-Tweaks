Write-Status "EDGE REMOVAL"

function Stop-EdgeProcs {
    'MicrosoftEdgeUpdate','WidgetService','Widgets','msedge','msedgewebview2' | ForEach-Object {
        Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
    }
}

function Disable-EdgeUpdateServices {
    'edgeupdate','edgeupdatem' | ForEach-Object {
        $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue
            Set-Service -Name $_ -StartupType Disabled -ErrorAction SilentlyContinue
            Write-Status "Stopped and disabled service: $_"
        }
    }
    Get-ScheduledTask -TaskName "MicrosoftEdgeUpdateTaskMachine*" -ErrorAction SilentlyContinue | ForEach-Object {
        Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
        Write-Status "Disabled scheduled task: $($_.TaskName)"
    }
}

function Test-EdgeStillPresent {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (Test-Path (Join-Path $base 'Microsoft\Edge\Application\msedge.exe')) { return $true }
    }
    return [bool](Get-AppxPackage -AllUsers -Name 'Microsoft.MicrosoftEdge.Stable' -ErrorAction SilentlyContinue)
}

Stop-EdgeProcs
Disable-EdgeUpdateServices

$legacyPkg = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages" -Name -ErrorAction SilentlyContinue |
    Where-Object { $_ -match "Microsoft-Windows-Internet-Browser-Package" -and $_ -match "~~" } | Select-Object -First 1

if ($legacyPkg) {
    $legacyInfo = & dism.exe /online /Get-PackageInfo /PackageName:$legacyPkg 2>$null
    if ($legacyInfo -match "State\s*:\s*Installed") {
        $legacyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$legacyPkg"
        Set-ItemProperty -Path $legacyPath -Name "Visibility" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$legacyPath\Owners" -Recurse -Force -ErrorAction SilentlyContinue
        $dismResult = Start-Process dism.exe -ArgumentList "/online /Remove-Package /PackageName:$legacyPkg /NoRestart" -NoNewWindow -PassThru -Wait
        if ($dismResult.ExitCode -eq 0) {
            Write-Status "Legacy Edge package removed."
        } else {
            Write-Status "Legacy Edge DISM removal returned exit code $($dismResult.ExitCode)."
        }
        Get-AppxPackage -AllUsers Microsoft.MicrosoftEdge -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    } else {
        Write-Status "Legacy Edge package found but not in Installed state - skipping."
    }
} else {
    Write-Status "No legacy Edge package present."
}

$chromiumEntry = Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
    ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props.DisplayName -like "*Microsoft Edge*" -and $props.DisplayName -notlike "*WebView*") { $props }
    } | Select-Object -First 1

if (-not $chromiumEntry) {
    Write-Status "No Chromium Edge uninstall entry found under WOW6432Node."
} elseif (-not $chromiumEntry.UninstallString) {
    Write-Status "Chromium Edge entry found ($($chromiumEntry.DisplayName)) but has no UninstallString."
} else {
    $us = $chromiumEntry.UninstallString
    Stop-EdgeProcs
    if ($us -like "*msiexec*") {
        $proc = Start-Process cmd.exe -ArgumentList "/c $us /quiet" -WindowStyle Hidden -PassThru -Wait
    } else {
        $proc = Start-Process cmd.exe -ArgumentList "/c $us --force-uninstall" -WindowStyle Hidden -PassThru -Wait
    }
    if ($proc.ExitCode -eq 0) {
        Write-Status "Uninstaller completed for $($chromiumEntry.DisplayName)."
    } else {
        Write-Status "Uninstaller for $($chromiumEntry.DisplayName) returned exit code $($proc.ExitCode)."
    }
}

Get-AppxPackage -AllUsers Microsoft.MicrosoftEdge.Stable -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue

foreach ($base in @([Environment]::GetFolderPath("LocalApplicationData"), [Environment]::GetFolderPath("ProgramFilesX86"), [Environment]::GetFolderPath("ProgramFiles"))) {
    Get-ChildItem "$base\Microsoft\EdgeUpdate\*.*.*.*\MicrosoftEdgeUpdate.exe" -ErrorAction SilentlyContinue | ForEach-Object {
        Start-Process -FilePath $_.FullName -ArgumentList "/unregsvc" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Process -FilePath $_.FullName -ArgumentList "/uninstall" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
}

Get-ChildItem "$env:SystemDrive\Program Files (x86)\Microsoft" -Directory -ErrorAction SilentlyContinue |
    Where-Object { ($_.Name -like "*Edge*" -or $_.Name -like "*Temp*") -and $_.Name -notlike "*EdgeWebView*" } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\ProgramData\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:WINDIR\Temp\MsEdgeCrashpad" -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path "$($_.FullName)\NTUSER.DAT" } | ForEach-Object {
    Remove-Item "$($_.FullName)\AppData\Local\Microsoft\Edge" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$($_.FullName)\Desktop\Microsoft Edge.lnk" -Force -ErrorAction SilentlyContinue
    Remove-Item "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" -Force -ErrorAction SilentlyContinue
}
Remove-Item "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk" -Force -ErrorAction SilentlyContinue

@(
    "HKLM:\SOFTWARE\Microsoft\Edge",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge",
    "HKCU:\Software\Microsoft\Edge",
    "HKCU:\Software\Microsoft\EdgeUpdate",
    "HKLM:\SOFTWARE\Clients\StartMenuInternet\Microsoft Edge",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MicrosoftEdge",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
) | ForEach-Object { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty -Path "HKLM:\SOFTWARE\RegisteredApplications" -Name "Microsoft Edge" -Force -ErrorAction SilentlyContinue

Get-ScheduledTask -TaskName "*Edge*" -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -ne "EdgeRemoval" } | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
    Write-Status "Removed Edge task: $($_.TaskName)"
}

if (Test-EdgeStillPresent) {
    Write-Status "WARNING: Edge still detected after removal attempt. Restart and re-run may be needed."
} else {
    Write-Status "Edge removal verified: no msedge.exe or Edge Stable package detected."
}
Write-Status "DONE: Edge removal attempted. Restart recommended."
