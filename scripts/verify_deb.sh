#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 PACKAGE.deb [SHA256SUMS_OUTPUT]" >&2
  exit 64
fi

package_path=$1
checksum_output=${2:-}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
control_path="$project_root/control"

for command_name in dpkg-deb file python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "missing required command: $command_name" >&2
    exit 69
  }
done
[[ -f "$package_path" && -s "$package_path" ]] || {
  echo "package is missing or empty: $package_path" >&2
  exit 66
}

read_control_field() {
  local field=$1
  sed -n "s/^${field}: //p" "$control_path" | head -n 1
}

expected_package=$(read_control_field Package)
expected_version=$(read_control_field Version)
expected_architecture=$(read_control_field Architecture)
actual_package=$(dpkg-deb -f "$package_path" Package)
actual_version=$(dpkg-deb -f "$package_path" Version)
actual_architecture=$(dpkg-deb -f "$package_path" Architecture)

[[ "$actual_package" == "$expected_package" ]] || {
  echo "package ID mismatch: $actual_package != $expected_package" >&2
  exit 65
}
[[ "$actual_version" == "$expected_version" ]] || {
  echo "package version mismatch: $actual_version != $expected_version" >&2
  exit 65
}
[[ "$actual_architecture" == "$expected_architecture" ]] || {
  echo "package architecture mismatch: $actual_architecture != $expected_architecture" >&2
  exit 65
}

temporary_root=$(mktemp -d)
cleanup() { rm -rf -- "$temporary_root"; }
trap cleanup EXIT INT TERM
payload_root="$temporary_root/payload"
metadata_root="$temporary_root/metadata"
mkdir -p "$payload_root" "$metadata_root"
dpkg-deb -x "$package_path" "$payload_root"
dpkg-deb -e "$package_path" "$metadata_root"

required_files=(
  "var/jb/Library/MobileSubstrate/DynamicLibraries/AVFCameraSupport.dylib"
  "var/jb/Library/MobileSubstrate/DynamicLibraries/AVFCameraSupport.plist"
  "var/jb/Library/MobileSubstrate/DynamicLibraries/VCMediaServer.dylib"
  "var/jb/Library/MobileSubstrate/DynamicLibraries/VCMediaServer.plist"
  "var/jb/Library/PreferenceBundles/VirtualCamPro.bundle/Info.plist"
  "var/jb/Library/PreferenceBundles/VirtualCamPro.bundle/Root.plist"
  "var/jb/Library/PreferenceLoader/Preferences/VirtualCamPro.plist"
  "var/jb/usr/bin/virtualcampro-config"
)
for relative_path in "${required_files[@]}"; do
  [[ -s "$payload_root/$relative_path" ]] || {
    echo "required payload is missing or empty: /$relative_path" >&2
    exit 65
  }
done
[[ -x "$payload_root/var/jb/usr/bin/virtualcampro-config" ]] || {
  echo "virtualcampro-config is not executable" >&2
  exit 65
}
[[ -x "$metadata_root/postinst" && -x "$metadata_root/postrm" ]] || {
  echo "maintainer scripts are not executable" >&2
  exit 65
}

for dylib_name in AVFCameraSupport VCMediaServer; do
  dylib_path="$payload_root/var/jb/Library/MobileSubstrate/DynamicLibraries/$dylib_name.dylib"
  dylib_description=$(file -b "$dylib_path")
  grep -Eq 'Mach-O universal binary with 2 architectures' <<<"$dylib_description" &&
    grep -q 'arm64e' <<<"$dylib_description" || {
    echo "dynamic library is not a two-slice arm64/arm64e Mach-O: $dylib_path" >&2
    echo "$dylib_description" >&2
    exit 65
  }
done

python3 - "$payload_root" <<'PY'
import plistlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
plists = list(root.rglob("*.plist"))
if not plists:
    raise SystemExit("package contains no property lists")
for path in plists:
    with path.open("rb") as handle:
        plistlib.load(handle)
print(f"validated {len(plists)} packaged property lists")
PY

if [[ -n "$checksum_output" ]]; then
  checksum_directory=$(dirname "$checksum_output")
  mkdir -p "$checksum_directory"
  (
    cd "$(dirname "$package_path")"
    sha256sum "$(basename "$package_path")"
  ) > "$checksum_output"
fi

echo "verified package: $actual_package $actual_version $actual_architecture"
