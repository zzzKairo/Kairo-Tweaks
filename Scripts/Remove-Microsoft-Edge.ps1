# ── adv_edge
Write-Status "=== EDGE REMOVAL (CONFIRMED) ==="
function Stop-EdgeProcs {
    'MicrosoftEdgeUpdate','WidgetService','Widgets','msedge','msedgewebview2' | ForEach-Object {
        Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
    }
}
Stop-EdgeProcs

# Legacy (pre-Chromium) UWP Edge
$legacyPkg = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages" -Name -ErrorAction SilentlyContinue |
    Where-Object { $_ -match "Microsoft-Windows-Internet-Browser-Package" -and $_ -match "~~" } | Select-Object -First 1
if ($legacyPkg) {
    $legacyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$legacyPkg"
    Set-ItemProperty -Path $legacyPath -Name "Visibility" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$legacyPath\Owners" -Recurse -Force -ErrorAction SilentlyContinue
    dism.exe /online /Remove-Package /PackageName:$legacyPkg /NoRestart 2>$null | Out-Null
    Get-AppxPackage -AllUsers Microsoft.MicrosoftEdge | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Write-Status "Legacy Edge removed."
}

# Chromium Edge
Get-ChildItem "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue | ForEach-Object {
    $dn = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName
    if ($dn -like "*Microsoft Edge*" -and $dn -notlike "*WebView*") {
        $us = (Get-ItemProperty $_.PSPath).UninstallString
        if ($us) {
            Stop-EdgeProcs
            if ($us -like "*msiexec*") { Start-Process cmd.exe "/c $us /quiet" -WindowStyle Hidden -Wait }
            else { Start-Process cmd.exe "/c $us --force-uninstall --silent" -WindowStyle Hidden -Wait }
            Write-Status "Ran uninstaller: $dn"
        }
    }
}
Get-AppxPackage -AllUsers Microsoft.MicrosoftEdge.Stable | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue

# EdgeUpdate
foreach ($base in @([Environment]::GetFolderPath("LocalApplicationData"), [Environment]::GetFolderPath("ProgramFilesX86"), [Environment]::GetFolderPath("ProgramFiles"))) {
    Get-ChildItem "$base\Microsoft\EdgeUpdate\*.*.*.*\MicrosoftEdgeUpdate.exe" -ErrorAction SilentlyContinue | ForEach-Object {
        Start-Process -FilePath $_.FullName -ArgumentList "/unregsvc" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
        Start-Process -FilePath $_.FullName -ArgumentList "/uninstall" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
}

# Leftover folders (never touches EdgeWebView)
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

# Registry cleanup
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
Write-Status "DONE: Edge removal attempted. Restart recommended."
