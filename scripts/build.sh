#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="$project_dir/build"
app_dir="$build_dir/Lyric Fever Scroll.app"
contents_dir="$app_dir/Contents"
executable="$contents_dir/MacOS/Lyric Fever Scroll"
adapter_source="$project_dir/Vendor/MediaRemoteAdapter"
adapter_framework="$adapter_source/MediaRemoteAdapter.framework"
adapter_script="$adapter_source/run.pl"
opencc_files=(TSCharacters TSPhrases TWPhrasesRev TWVariants TWVariantsRevPhrases)

if [[ ! -e "$adapter_framework" || ! -f "$adapter_script" ]]; then
  echo "Vendored MediaRemoteAdapter is incomplete" >&2
  exit 1
fi

(cd "$adapter_source" && shasum -a 256 -c SHA256SUMS >/dev/null)

if [[ -e "$app_dir" ]]; then
  previous_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/LyricFeverScroll-build.XXXXXX")"
  mv "$app_dir" "$previous_build_dir/"
fi
mkdir -p "$contents_dir/MacOS" "$contents_dir/Frameworks" "$contents_dir/Resources/MediaRemoteAdapter" "$contents_dir/Resources/OpenCC" "$contents_dir/Resources/ThirdPartyLicenses"

swiftc \
  -swift-version 5 \
  -O \
  -whole-module-optimization \
  -framework AppKit \
  -framework CoreServices \
  -framework Foundation \
  -framework ServiceManagement \
  "$project_dir"/Sources/*.swift \
  -o "$executable"

cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
ditto "$adapter_framework" "$contents_dir/Frameworks/MediaRemoteAdapter.framework"
cp "$adapter_script" "$contents_dir/Resources/MediaRemoteAdapter/run.pl"
for name in $opencc_files; do
  cp "$project_dir/Resources/OpenCC/$name.txt" "$contents_dir/Resources/OpenCC/$name.txt"
done
cp "$project_dir/THIRD_PARTY_LICENSES/OpenCC-LICENSE" "$contents_dir/Resources/ThirdPartyLicenses/OpenCC-LICENSE"
cp "$project_dir/THIRD_PARTY_LICENSES/MediaRemoteAdapter-LICENSE" "$contents_dir/Resources/ThirdPartyLicenses/MediaRemoteAdapter-LICENSE"
cp "$project_dir/THIRD_PARTY_LICENSES/AppleLyricsReferences-LICENSES" "$contents_dir/Resources/ThirdPartyLicenses/AppleLyricsReferences-LICENSES"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
