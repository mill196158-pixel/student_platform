# Launch Admin Web in real backend mode (browser login).
# Demo mode: use .\scripts\run_admin_web_demo.ps1
# Always binds Flutter Web to http://localhost:3000 for auth redirects.
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

# Optional env overrides; defaults live in AdminBackendConfig.
$defines = @()
if ($env:SUPABASE_URL) {
    $defines += "--dart-define=SUPABASE_URL=$($env:SUPABASE_URL)"
}
if ($env:SUPABASE_PUBLISHABLE_KEY) {
    $defines += "--dart-define=SUPABASE_PUBLISHABLE_KEY=$($env:SUPABASE_PUBLISHABLE_KEY)"
}
elseif ($env:SUPABASE_ANON_KEY) {
    $defines += "--dart-define=SUPABASE_ANON_KEY=$($env:SUPABASE_ANON_KEY)"
}

flutter run -d chrome --web-hostname=localhost --web-port=3000 @defines
