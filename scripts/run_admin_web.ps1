$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$adminDir = Join-Path $scriptDir "..\admin_console"
$sharedPubspec = Join-Path $scriptDir "..\packages\student_ui\pubspec.yaml"
$packageConfig = Join-Path $adminDir ".dart_tool\package_config.json"

Set-Location $adminDir

$needsPubGet = -not (Test-Path $packageConfig)
if (-not $needsPubGet) {
    $configTime = (Get-Item $packageConfig).LastWriteTimeUtc
    $needsPubGet =
        (Get-Item "pubspec.yaml").LastWriteTimeUtc -gt $configTime -or
        (Get-Item $sharedPubspec).LastWriteTimeUtc -gt $configTime
}

if ($needsPubGet) {
    flutter pub get
}

flutter run -d chrome
