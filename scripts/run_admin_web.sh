#!/bin/bash
# Launch Admin Web in real backend mode (browser login).
# Demo mode: use ./scripts/run_admin_web_demo.sh
#
# Compatible with macOS system Bash 3.2 + set -u (no empty-array expansion).
# Always binds Flutter Web to http://localhost:3000 for auth redirects.
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
admin_dir="$repo_root/admin_console"
package_config="$admin_dir/.dart_tool/package_config.json"

cd "$admin_dir"

if [[ ! -f "$package_config" ||
      "pubspec.yaml" -nt "$package_config" ||
      "../packages/student_ui/pubspec.yaml" -nt "$package_config" ]]; then
  flutter pub get
fi

# Optional overrides via positional params (safe under Bash 3.2 + set -u).
# Defaults are baked into AdminBackendConfig (public publishable client only).
set --
if [[ -n "${SUPABASE_URL:-}" ]]; then
  set -- "$@" --dart-define="SUPABASE_URL=$SUPABASE_URL"
fi
if [[ -n "${SUPABASE_PUBLISHABLE_KEY:-}" ]]; then
  set -- "$@" --dart-define="SUPABASE_PUBLISHABLE_KEY=$SUPABASE_PUBLISHABLE_KEY"
elif [[ -n "${SUPABASE_ANON_KEY:-}" ]]; then
  set -- "$@" --dart-define="SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"
fi

exec flutter run -d chrome --web-hostname=localhost --web-port=3000 "$@"
