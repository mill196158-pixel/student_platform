#!/bin/bash
# Launch Admin Web in explicit local prototype / demo mode.
# Compatible with macOS system Bash 3.2 + set -u.
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

# No optional arrays — always a concrete define list.
exec flutter run -d chrome --dart-define=ADMIN_DEMO_MODE=true
