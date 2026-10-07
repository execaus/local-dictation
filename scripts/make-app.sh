#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
if [[ ! -f Resources/ggml-large-v3-turbo-q5_0.bin ]]; then
    print -u2 "Сначала положите модель в Resources или выполните zsh scripts/fetch-model.sh."
    exit 1
fi
if [[ "$(shasum Resources/ggml-large-v3-turbo-q5_0.bin | awk '{print $1}')" != "e050f7970618a659205450ad97eb95a18d69c9ee" ]]; then
    print -u2 "Контрольная сумма модели не совпадает; сборка остановлена."
    exit 1
fi
swift build -c release --product LocalDictationSpike

destination="$PWD/dist/LocalDictationSpike.app"
staging_root="$(mktemp -d /private/tmp/local-dictation.XXXXXX)"
trap 'rm -rf "$staging_root"' EXIT
app_path="$staging_root/LocalDictationSpike.app"
bin_path="$(swift build -c release --show-bin-path)/LocalDictationSpike"
mkdir -p "$app_path/Contents/MacOS"
cp "$bin_path" "$app_path/Contents/MacOS/LocalDictationSpike"
mkdir -p "$app_path/Contents/Frameworks" "$app_path/Contents/Resources"
ditto Vendor/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$app_path/Contents/Frameworks/whisper.framework"
cp Resources/ggml-large-v3-turbo-q5_0.bin "$app_path/Contents/Resources/ggml-large-v3-turbo-q5_0.bin"
cp Vendor/whisper-LICENSE "$app_path/Contents/Resources/whisper-LICENSE"
cp Vendor/whisper-model-LICENSE "$app_path/Contents/Resources/whisper-model-LICENSE"
install_name_tool -add_rpath @executable_path/../Frameworks "$app_path/Contents/MacOS/LocalDictationSpike"

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ru</string>
    <key>CFBundleExecutable</key><string>LocalDictationSpike</string>
    <key>CFBundleIdentifier</key><string>local.codex.LocalDictationSpike</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>LocalDictationSpike</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Запись речи для локального распознавания на этом Mac.</string>
</dict>
</plist>
PLIST

xattr -rc "$app_path"
codesign --force --sign - "$app_path/Contents/Frameworks/whisper.framework"
xattr -rc "$app_path"
codesign --force --sign - --identifier local.codex.LocalDictationSpike "$app_path"
codesign --verify --deep --strict "$app_path"
mkdir -p "$PWD/dist"
rm -rf "$destination"
ditto --noextattr "$app_path" "$destination"
codesign --verify "$destination"
print "Готово: $destination"
