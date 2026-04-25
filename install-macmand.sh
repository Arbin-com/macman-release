#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-macmand.sh [latest|VERSION] [--auth auto|app|pat] [--silent|--non-interactive] [--no-browser-open]
Examples:
  install-macmand.sh
  install-macmand.sh latest
  install-macmand.sh 1.2.3
  install-macmand.sh --silent
  install-macmand.sh --auth app
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
  echo "macmand installer is currently supported on Linux only." >&2
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

if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required but not installed" >&2
  exit 1
fi
macman_release_require_checksum_tool

tmp_dir="$(mktemp -d)"
install_success=0
cleanup() {
  if [ "$install_success" -eq 1 ]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

zip_path="$tmp_dir/macmand-${version}-${MACMAN_RELEASE_PLATFORM}.zip"
extract_root="$tmp_dir/extract"
mkdir -p "$extract_root"

if [ -n "$github_asset_api_url" ]; then
  echo "Downloading macmand $version ($MACMAN_RELEASE_PLATFORM)..."
  if ! macman_release_download_github_asset "$github_asset_api_url" "$zip_path"; then
    echo "Failed to download GitHub release asset ${github_asset:-for $MACMAN_RELEASE_PLATFORM}" >&2
    echo "Auth mode: ${AUTH_KIND:-unknown}. Provide GH_TOKEN/GITHUB_TOKEN or run interactively to authenticate." >&2
    exit 1
  fi
else
  macman_release_download_or_fail "$url" "$zip_path"
fi

actual="$(macman_release_checksum_cmd "$zip_path")"
if [ "$actual" != "$checksum" ]; then
  echo "Checksum verification failed" >&2
  exit 1
fi

unzip -q "$zip_path" -d "$extract_root"
if [ ! -f "$extract_root/macmand" ]; then
  echo "macmand binary not found in package" >&2
  exit 1
fi
if [ ! -d "$extract_root/web/dist" ]; then
  echo "web/dist not found in package" >&2
  exit 1
fi

install_root="/usr/local/lib/macman"
bin_link="/usr/local/bin/macmand"
data_dir="/var/lib/macman"
service_name="macmand"
service_file="/etc/systemd/system/${service_name}.service"
service_user="macman"
service_group="macman"

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required to install macmand as a system service" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl is required but not installed" >&2
  exit 1
fi

if ! command -v useradd >/dev/null 2>&1; then
  echo "useradd is required but not installed" >&2
  exit 1
fi

if ! command -v groupadd >/dev/null 2>&1; then
  echo "groupadd is required but not installed" >&2
  exit 1
fi

echo "Installing macmand into standard Linux locations..."
macman_release_run_root install -d -m 0755 "$install_root" "$install_root/web" "$data_dir"
macman_release_run_root install -m 0755 "$extract_root/macmand" "$install_root/macmand"
macman_release_run_root rm -rf "$install_root/web/dist"
macman_release_run_root cp -R "$extract_root/web/dist" "$install_root/web/dist"
macman_release_run_root ln -sf "$install_root/macmand" "$bin_link"

if ! getent group "$service_group" >/dev/null 2>&1; then
  macman_release_run_root groupadd --system "$service_group"
fi
if ! id -u "$service_user" >/dev/null 2>&1; then
  macman_release_run_root useradd \
    --system \
    --home-dir "$data_dir" \
    --no-create-home \
    --shell /usr/sbin/nologin \
    --gid "$service_group" \
    "$service_user"
fi
macman_release_run_root chown -R "$service_user:$service_group" "$data_dir"
macman_release_run_root chmod 0750 "$data_dir"

cat <<EOF | macman_release_run_root tee "$service_file" >/dev/null
[Unit]
Description=macmand daemon
After=network-online.target
Wants=network-online.target

[Service]
User=$service_user
Group=$service_group
WorkingDirectory=$install_root
ExecStart=$install_root/macmand --data-dir $data_dir
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

macman_release_run_root systemctl daemon-reload
macman_release_run_root systemctl enable --now "$service_name"

install_success=1

echo ""
echo "macmand is installed and the service has been started."
echo "Service name: $service_name"
echo "Data directory: $data_dir"
echo "Binary: $install_root/macmand"
echo "Web assets: $install_root/web/dist"
echo ""
echo "Quick start:"
echo "  sudo systemctl status $service_name"
echo "  sudo journalctl -u $service_name -f"
echo "  macmand --help"
echo ""
echo "If this is a fresh install, set MACMAND_BOOTSTRAP_ADMIN_PASSWORD before the first boot if you want the daemon to seed an initial admin automatically."
