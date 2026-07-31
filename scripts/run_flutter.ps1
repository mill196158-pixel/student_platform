# Run Flutter (Supabase URL/key are baked into lib/src/config/supabase_config.dart).
# Usage: powershell -ExecutionPolicy Bypass -File scripts/run_flutter.ps1 [flutter args...]

$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)
& flutter @args
