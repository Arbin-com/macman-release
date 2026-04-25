#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-macman.sh [latest|VERSION] [--auth auto|app|pat] [--silent|--non-interactive] [--no-browser-open]
Examples:
  install-macman.sh
  install-macman.sh latest
  install-macman.sh 1.2.3
  install-macman.sh --auth pat
EOF
}

TARGET="latest"
AUTH_MODE="auto"
MACMAN_RELEASE_SILENT=""
MACMAN_RELEASE_NO_BROWSER_OPEN="${MACMAN_RELEASE_NO_BROWSER_OPEN:-0}"
: "${MACMAN_RELEASE_BASE_URL:=https://arbin-com.github.io/macman-release}"
: "${MACMAN_GITHUB_APP_CLIENT_ID:=Iv23liqzeRmAZM7t6ZU1}"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --silent|--non-interactive)
      MACMAN_RELEASE_SILENT="1"
      ;;
    --no-browser-open)
      MACMAN_RELEASE_NO_BROWSER_OPEN="1"
      ;;
    --auth)
      if [ $# -lt 2 ]; then
        echo "--auth requires a value: auto, app, or pat" >&2
        usage
        exit 1
      fi
      case "$2" in
        auto|app|pat)
          AUTH_MODE="$2"
          ;;
        *)
          echo "Invalid auth mode: $2" >&2
          usage
          exit 1
          ;;
      esac
      shift
      ;;
    latest)
      TARGET="latest"
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([\-+][^[:space:]]+)?$ ]]; then
        TARGET="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
  shift
done

fetch_common() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    echo "Either curl or wget is required but neither is installed" >&2
    exit 1
  fi
}

if [ -n "${MACMAN_INSTALL_COMMON_PATH:-}" ] && [ -f "$MACMAN_INSTALL_COMMON_PATH" ]; then
  # shellcheck disable=SC1090
  . "$MACMAN_INSTALL_COMMON_PATH"
else
  script_dir=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
  fi
  if [ -n "$script_dir" ] && [ -f "$script_dir/install-common.sh" ]; then
    # shellcheck disable=SC1091
    . "$script_dir/install-common.sh"
  else
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    fetch_common "$MACMAN_RELEASE_BASE_URL/install-common.sh" "$tmp_dir/install-common.sh"
    # shellcheck disable=SC1091
    . "$tmp_dir/install-common.sh"
  fi
fi

AUTH_MODE="${AUTH_MODE:-auto}"
MACMAN_RELEASE_SILENT="${MACMAN_RELEASE_SILENT:-}"
export MACMAN_RELEASE_SILENT MACMAN_RELEASE_NO_BROWSER_OPEN AUTH_MODE

macman_release_require_downloader
macman_release_platform

if [ "$MACMAN_RELEASE_OS" != "linux" ]; then
  echo "macman installer is currently supported on Linux only." >&2
  exit 1
fi

if ! macman_release_platform_supported; then
  echo "Unsupported platform: $MACMAN_RELEASE_PLATFORM" >&2
  exit 1
fi

version="$(macman_release_resolve_version "$TARGET" | tr -d '[:space:]')"
if [ -z "$version" ]; then
  echo "Failed to resolve version for target: $TARGET" >&2
  exit 1
fi

manifest_json="$(macman_release_fetch_manifest "$version")"
if command -v jq >/dev/null 2>&1; then
  url="$(echo "$manifest_json" | jq -r ".platforms[\"$MACMAN_RELEASE_PLATFORM\"].url // empty")"
  checksum="$(echo "$manifest_json" | jq -r ".platforms[\"$MACMAN_RELEASE_PLATFORM\"].sha256 // empty")"
  github_asset_api_url="$(echo "$manifest_json" | jq -r ".platforms[\"$MACMAN_RELEASE_PLATFORM\"].github_asset_api_url // empty")"
  github_owner="$(echo "$manifest_json" | jq -r ".platforms[\"$MACMAN_RELEASE_PLATFORM\"].github_owner // empty")"
  github_repo="$(echo "$manifest_json" | jq -r ".platforms[\"$MACMAN_RELEASE_PLATFORM\"].github_repo // empty")"
  github_tag="$(echo "$manifest_json" | jq -r ".platforms[\"$MACMAN_RELEASE_PLATFORM\"].github_tag // empty")"
  github_asset="$(echo "$manifest_json" | jq -r ".platforms[\"$MACMAN_RELEASE_PLATFORM\"].github_asset // empty")"
else
  manifest_values="$(macman_release_get_manifest_values "$manifest_json" "$MACMAN_RELEASE_PLATFORM" || true)"
  url="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $1}')"
  checksum="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $2}')"
  github_asset_api_url="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $3}')"
  github_owner="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $4}')"
  github_repo="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $5}')"
  github_tag="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $6}')"
  github_asset="$(printf '%s' "$manifest_values" | awk -F '\t' '{print $7}')"
fi

macman_release_populate_github_metadata_from_url_if_needed

if { [ -z "$url" ] && [ -z "$github_asset_api_url" ]; } || [ -z "$checksum" ]; then
  echo "Platform $MACMAN_RELEASE_PLATFORM not found in manifest for version $version" >&2
  exit 1
fi

if [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Invalid checksum in manifest for $MACMAN_RELEASE_PLATFORM" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
install_success=0
cleanup() {
  if [ "$install_success" -eq 1 ]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

binary_path="$tmp_dir/macman-${version}-${MACMAN_RELEASE_PLATFORM}"

if [ -n "$github_asset_api_url" ]; then
  echo "Downloading macman $version ($MACMAN_RELEASE_PLATFORM)..."
  if ! macman_release_download_github_asset "$github_asset_api_url" "$binary_path"; then
    echo "Failed to download GitHub release asset ${github_asset:-for $MACMAN_RELEASE_PLATFORM}" >&2
    echo "Auth mode: ${AUTH_KIND:-unknown}. Provide GH_TOKEN/GITHUB_TOKEN or run interactively to authenticate." >&2
    exit 1
  fi
else
  macman_release_download_or_fail "$url" "$binary_path"
fi

macman_release_require_checksum_tool
actual="$(macman_release_checksum_cmd "$binary_path")"
if [ "$actual" != "$checksum" ]; then
  echo "Checksum verification failed" >&2
  exit 1
fi

install_dir="/usr/local/bin"
local_fallback_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"

if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    install_dir="$local_fallback_dir"
  fi
fi

echo "Installing macman into $install_dir..."
if [ "$install_dir" = "/usr/local/bin" ]; then
  macman_release_run_root install -d -m 0755 "$install_dir"
  macman_release_run_root install -m 0755 "$binary_path" "$install_dir/macman"
else
  install -d -m 0755 "$install_dir"
  install -m 0755 "$binary_path" "$install_dir/macman"
fi

install_success=1

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *)
    echo ""
    echo "macman was installed to $install_dir, but that directory is not on PATH."
    echo "Add this line to your shell profile:"
    echo "  export PATH=\"$install_dir:\$PATH\""
    ;;
esac

echo ""
echo "macman is installed."
echo "Binary: $install_dir/macman"
echo ""
echo "Quick start:"
echo "  macman --help"
echo "  macman login"
echo "  macman whoami"
