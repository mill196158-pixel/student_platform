#!/bin/bash
# Double-clickable macOS launcher for real Admin Web (Chrome + browser login).
# Uses system /bin/bash (3.2 on macOS).
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$script_dir/.."

exec /bin/bash "$script_dir/run_admin_web.sh"
