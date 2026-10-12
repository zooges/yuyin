#!/usr/bin/env bash
# Download sherpa-onnx models into Application Support for the Yuyin app.
set -euo pipefail

APP_SUPPORT="${HOME}/Library/Application Support/Yuyin/Models"
REPO_COPY="$(cd "$(dirname "$0")" && pwd)/downloaded"
mkdir -p "$APP_SUPPORT" "$REPO_COPY"

download_one() {
  local name="$1"
  local url="$2"
  local dest_dir="$3"
  local archive="/tmp/yuyin-${name}.tar.bz2"

  if [[ -f "${dest_dir}/tokens.txt" ]]; then
    echo "✓ ${name} already installed at ${dest_dir}"
    return 0
  fi

  echo "→ Downloading ${name}…"
  curl -L --fail --progress-bar -o "$archive" "$url"
  local tmp
  tmp="$(mktemp -d)"
  tar xjf "$archive" -C "$tmp"
  local bundle
  bundle="$(find "$tmp" -maxdepth 2 -type f -name tokens.txt | head -1 | xargs dirname)"
  rm -rf "$dest_dir"
  mkdir -p "$(dirname "$dest_dir")"
  mv "$bundle" "$dest_dir"
  # keep a repo-local mirror for CI/dev
  rm -rf "${REPO_COPY}/$(basename "$dest_dir")"
  cp -R "$dest_dir" "${REPO_COPY}/$(basename "$dest_dir")"
  rm -rf "$tmp" "$archive"
  echo "✓ Installed ${name} → ${dest_dir}"
}

download_one "streaming-x-asr-160ms" \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-x-asr-160ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05.tar.bz2" \
  "${APP_SUPPORT}/streaming-x-asr-160ms"

download_one "sensevoice-small" \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2" \
  "${APP_SUPPORT}/sensevoice-small"

echo ""
echo "Done. 未沙盒的开发版会直接读取上述目录；签名（沙盒）版请在 App 设置 → 模型 →「导入已下载的模型文件夹…」中选择这些目录。"
