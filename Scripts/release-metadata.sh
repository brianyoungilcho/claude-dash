#!/usr/bin/env bash
set -euo pipefail

# Translate a release tag into the user-facing version, a monotonically
# increasing numeric CFBundleVersion, and release-channel metadata. Production
# reserves qualifier 99 so rc.1 ... rc.98 always sort below the final build.
tag="${1:-}"
if [[ ! "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-rc\.([0-9]+))?$ ]]; then
  echo "Release tag must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N" >&2
  exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
rc="${BASH_REMATCH[5]:-}"
for component in "$major" "$minor" "$patch"; do
  if [[ ( "$component" != "0" && "$component" == 0* ) || "$component" -gt 99 ]]; then
    echo "Version components must be canonical integers from 0 through 99" >&2
    exit 1
  fi
done

qualifier=99
prerelease=false
if [[ -n "$rc" ]]; then
  if [[ ( "$rc" != "0" && "$rc" == 0* ) || "$rc" -lt 1 || "$rc" -gt 98 ]]; then
    echo "RC number must be a canonical integer from 1 through 98" >&2
    exit 1
  fi
  qualifier="$rc"
  prerelease=true
fi

build_version=$((10#$major * 1000000 + 10#$minor * 10000 + 10#$patch * 100 + 10#$qualifier))
printf 'version=%s\n' "${tag#v}"
printf 'build_version=%s\n' "$build_version"
printf 'prerelease=%s\n' "$prerelease"
if [[ "$prerelease" == "true" ]]; then
  printf 'feed_filename=appcast-rc.xml\n'
else
  printf 'feed_filename=appcast.xml\n'
fi
