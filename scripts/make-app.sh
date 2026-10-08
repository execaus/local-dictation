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
swift build --disable-sandbox -c release --product LocalDictationSpike

destination="$PWD/dist/LocalDictationSpike.app"
staging_root="$(mktemp -d /private/tmp/local-dictation.XXXXXX)"
verification_root="$(mktemp -d /private/tmp/local-dictation-verify.XXXXXX)"
trap 'rm -rf "$staging_root" "$verification_root"' EXIT
app_path="$staging_root/LocalDictationSpike.app"
bin_path="$(swift build --disable-sandbox -c release --show-bin-path)/LocalDictationSpike"
mkdir -p "$app_path/Contents/MacOS"
cp "$bin_path" "$app_path/Contents/MacOS/LocalDictationSpike"
mkdir -p "$app_path/Contents/Frameworks" "$app_path/Contents/Resources"
ditto Vendor/build-apple/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$app_path/Contents/Frameworks/whisper.framework"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app_path/Contents/Frameworks/Sparkle.framework"
cp Resources/ggml-large-v3-turbo-q5_0.bin "$app_path/Contents/Resources/ggml-large-v3-turbo-q5_0.bin"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp Vendor/whisper-LICENSE "$app_path/Contents/Resources/whisper-LICENSE"
cp Vendor/whisper-model-LICENSE "$app_path/Contents/Resources/whisper-model-LICENSE"
cp Vendor/Sparkle-LICENSE "$app_path/Contents/Resources/Sparkle-LICENSE"
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
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.6</string>
    <key>CFBundleVersion</key><string>8</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Запись речи для локального распознавания на этом Mac.</string>
    <key>SUFeedURL</key><string>https://github.com/execaus/local-dictation/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>jy2ZJPSDsi0DLT/suGBOZPXPePYjZkYpdZ9mk7xwHG8=</string>
    <key>SUEnableAutomaticChecks</key><false/>
    <key>SUAllowsAutomaticUpdates</key><false/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
    <key>SUSignedFeedFailureExpirationInterval</key><integer>0</integer>
</dict>
</plist>
PLIST

xattr -rc "$app_path"
codesign --force --sign - "$app_path/Contents/Frameworks/whisper.framework"
codesign --force --sign - --deep "$app_path/Contents/Frameworks/Sparkle.framework"
xattr -rc "$app_path"
codesign --force --sign - --identifier local.codex.LocalDictationSpike "$app_path"
codesign --verify --deep --strict "$app_path"
archive_path="/private/tmp/LocalDictation-0.2.6-macos-arm64.zip"
rm -f "$archive_path"
ditto --noextattr -c -k --keepParent "$app_path" "$archive_path"
ditto -x -k "$archive_path" "$verification_root"
xattr -rc "$verification_root/LocalDictationSpike.app"
codesign --verify --deep --strict "$verification_root/LocalDictationSpike.app"
mkdir -p "$PWD/release"
cp "$archive_path" "$PWD/release/LocalDictation-0.2.6-macos-arm64.zip"
mkdir -p "$PWD/dist"
rm -rf "$destination"
ditto --noextattr "$app_path" "$destination"
xattr -rc "$destination"
print "Готово: release/LocalDictation-0.2.6-macos-arm64.zip (архив проверен)"
