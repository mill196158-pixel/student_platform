# Launch Admin Web in explicit local prototype / demo mode.
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
$adminDir = Join-Path $repoRoot "admin_console"
$sharedPubspec = Join-Path $repoRoot "packages\student_ui\pubspec.yaml"
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

flutter run -d chrome --dart-define=ADMIN_DEMO_MODE=true
