#!/usr/bin/env bash
# Sign on this machine and complete the matching GitHub release draft.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
for command in gh node flutter sha256sum; do
  command -v "$command" >/dev/null || { echo "$command is required." >&2; exit 1; }
done
[ -z "$(git status --porcelain)" ] || { echo 'Commit or stash local changes before signing.' >&2; exit 1; }
node scripts/release/check_versions.js
version="$(node -p "require('./server/package.json').version")"
build_number="$(sed -n 's/^version: [^+]*+\([0-9]*\).*/\1/p' app/shell/pubspec.yaml)"
tag="v$version"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
[ "$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft)" = true ] || {
  echo "$tag must be an existing release draft." >&2; exit 1;
}
tag_commit="$(gh api "repos/$repo/git/ref/tags/$tag" --jq 'select(.object.type == "commit") | .object.sha')"
[ "$tag_commit" = "$(git rev-parse HEAD)" ] || { echo 'Check out the exact release commit before signing.' >&2; exit 1; }
[ -f app/shell/android/key.properties ] || { echo 'Android release signing is not configured.' >&2; exit 1; }

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$sdk" ] && [ -d "$sdk/build-tools" ] || { echo 'Set ANDROID_HOME to the Android SDK.' >&2; exit 1; }
signer="$(find "$sdk/build-tools" -name apksigner -type f | sort -V | tail -n 1)"
aapt="$(find "$sdk/build-tools" -name aapt -type f | sort -V | tail -n 1)"
[ -n "$signer" ] && [ -n "$aapt" ] || { echo 'Android build-tools (apksigner and aapt) are required.' >&2; exit 1; }

tmp="$(mktemp -d)"
cleanup() {
  rm -f "$tmp/source/app/shell/android/key.properties"
  if [ -e "$tmp/source/.git" ]; then
    git worktree remove --force "$tmp/source" >/dev/null 2>&1 || echo 'Could not remove the temporary Git worktree.' >&2
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
gh release download "$tag" --repo "$repo" --dir "$tmp" \
  --pattern SHA256SUMS --pattern install.sh --pattern "relay-backend-setup-$tag.tar.gz" \
  --pattern "relay-windows-x64-$tag.zip" --pattern "relay-backend-windows-x64-$tag.zip" \
  --pattern "relay-desktop_${version}_amd64.deb"
(
  cd "$tmp"
  : > base-checksums
  for asset in install.sh "relay-backend-setup-$tag.tar.gz" \
    "relay-windows-x64-$tag.zip" "relay-backend-windows-x64-$tag.zip" \
    "relay-desktop_${version}_amd64.deb"; do
    awk -v name="$asset" '$2 == name { print; found++ } END { if (found != 1) exit 1 }' SHA256SUMS >> base-checksums
  done
  sha256sum --check base-checksums
)

# The checkout must exclude local Firebase config and other ignored state.
git worktree add --detach "$tmp/source" HEAD >/dev/null
ln -s "$root/app/shell/android/key.properties" "$tmp/source/app/shell/android/key.properties"
(cd "$tmp/source/app/shell" && flutter pub get --enforce-lockfile && flutter build apk --release --no-pub)
apk="$tmp/source/app/shell/build/app/outputs/flutter-apk/app-release.apk"
expected_cert=3e4dea3f6cd50fd30b25a168ba9eb2c14a14ecb8f786ffcb4e3c1836275a720f
certificate="$("$signer" verify --print-certs "$apk")"
grep -Fqi "Signer #1 certificate SHA-256 digest: $expected_cert" <<< "$certificate" || {
  echo 'The APK was not signed with the Relay release certificate.' >&2; exit 1;
}
apk_info="$("$aapt" dump badging "$apk")"
grep -Fq "package: name='dev.relay.app' versionCode='$build_number' versionName='$version'" <<< "$apk_info" || {
  echo 'The APK package or version does not match this release.' >&2; exit 1;
}
cp "$apk" "$tmp/relay-android-$tag.apk"
(cd "$tmp" && sha256sum install.sh "relay-backend-setup-$tag.tar.gz" \
  "relay-windows-x64-$tag.zip" "relay-backend-windows-x64-$tag.zip" \
  "relay-desktop_${version}_amd64.deb" \
  "relay-android-$tag.apk" > SHA256SUMS && sha256sum --check SHA256SUMS)
gh release upload "$tag" --repo "$repo" --clobber "$tmp/relay-android-$tag.apk" "$tmp/SHA256SUMS"
gh release view "$tag" --repo "$repo" --json body --jq .body > "$tmp/notes.md"
sed '1{/^> Android APK is pending local signing\. Do not publish this draft yet\.$/d;}' "$tmp/notes.md" > "$tmp/complete-notes.md"
gh release edit "$tag" --repo "$repo" --notes-file "$tmp/complete-notes.md"
echo "Signed Android APK and verified checksums added to the $tag draft. Review it before publishing."
