#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
admin_dir="$script_dir/../admin_console"
package_config="$admin_dir/.dart_tool/package_config.json"

cd "$admin_dir"

if [[ ! -f "$package_config" ||
      "pubspec.yaml" -nt "$package_config" ||
      "../packages/student_ui/pubspec.yaml" -nt "$package_config" ]]; then
  flutter pub get
fi

exec flutter run -d chrome
