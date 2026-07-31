# Start Pixel 9a emulator with public DNS so Supabase works without VPN.
# Usage: powershell -ExecutionPolicy Bypass -File scripts/start_pixel_9a.ps1

$ErrorActionPreference = "Stop"

$sdkRoot = $env:ANDROID_HOME
if (-not $sdkRoot) {
    $localProps = Join-Path $PSScriptRoot "..\android\local.properties"
    if (Test-Path $localProps) {
        $sdkLine = Get-Content $localProps | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
        if ($sdkLine) {
            $sdkRoot = ($sdkLine -replace '^sdk\.dir=', '').Trim().Replace('\\', '\')
        }
    }
}
if (-not $sdkRoot) {
    $sdkRoot = Join-Path $env:LOCALAPPDATA "Android\Sdk"
}

$emulator = Join-Path $sdkRoot "emulator\emulator.exe"
if (-not (Test-Path $emulator)) {
    Write-Error "emulator.exe not found at: $emulator"
}

Write-Host "Stopping old emulator instances..."
adb devices | Select-String "emulator-" | ForEach-Object {
    $id = ($_ -split "\s+")[0]
    if ($id) { adb -s $id emu kill 2>$null | Out-Null }
}
Start-Sleep -Seconds 2

Write-Host "Starting Pixel_9a with DNS 8.8.8.8 / 8.8.4.4 ..."
Start-Process -FilePath $emulator -ArgumentList @(
    "-avd", "Pixel_9a",
    "-dns-server", "8.8.8.8,8.8.4.4",
    "-no-snapshot-load"
)

Write-Host "Waiting for boot..."
adb wait-for-device | Out-Null
for ($i = 0; $i -lt 60; $i++) {
    $boot = adb shell getprop sys.boot_completed 2>$null
    if ($boot -match "1") { break }
    Start-Sleep -Seconds 2
}

adb shell settings put global private_dns_mode hostname | Out-Null
adb shell settings put global private_dns_specifier dns.google | Out-Null

Write-Host "Emulator ready. Private DNS: dns.google"
Write-Host "Run app from Android Studio or: flutter run -d emulator-5554 ..."
