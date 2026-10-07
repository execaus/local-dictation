#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
model_path="Resources/ggml-large-v3-turbo-q5_0.bin"
expected_sha1="e050f7970618a659205450ad97eb95a18d69c9ee"
model_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

mkdir -p Resources
if [[ ! -f "$model_path" ]]; then
    temporary_path="$(mktemp /private/tmp/local-dictation-model.XXXXXX)"
    trap 'rm -f "$temporary_path"' EXIT
    curl -fL --retry 2 --connect-timeout 15 -o "$temporary_path" "$model_url"
    actual_sha1="$(shasum "$temporary_path" | awk '{print $1}')"
    if [[ "$actual_sha1" != "$expected_sha1" ]]; then
        print -u2 "Ошибка: контрольная сумма загруженной модели не совпадает."
        exit 1
    fi
    mv "$temporary_path" "$model_path"
fi

actual_sha1="$(shasum "$model_path" | awk '{print $1}')"
if [[ "$actual_sha1" != "$expected_sha1" ]]; then
    print -u2 "Ошибка: контрольная сумма модели не совпадает."
    exit 1
fi
print "Модель проверена: $model_path"
