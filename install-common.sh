#!/usr/bin/env bash

# Shared helpers for macman installer scripts.

MACMAN_RELEASE_BASE_URL="${MACMAN_RELEASE_BASE_URL:-https://arbin-com.github.io/macman-release}"
MACMAN_GITHUB_APP_CLIENT_ID="${MACMAN_GITHUB_APP_CLIENT_ID:-Iv23liqzeRmAZM7t6ZU1}"
MACMAN_RELEASE_GITHUB_OWNER="${MACMAN_RELEASE_GITHUB_OWNER:-Arbin-com}"
MACMAN_RELEASE_GITHUB_REPO="${MACMAN_RELEASE_GITHUB_REPO:-macman}"
MACMAN_RELEASE_API_BASE_URL="${MACMAN_RELEASE_API_BASE_URL:-https://api.github.com/repos/${MACMAN_RELEASE_GITHUB_OWNER}/${MACMAN_RELEASE_GITHUB_REPO}}"
MACMAN_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/macman"
MACMAN_APP_TOKEN_FILE="$MACMAN_CONFIG_DIR/github-app-auth.json"

macman_release_require_downloader() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
  else
    echo "Either curl or wget is required but neither is installed" >&2
    exit 1
  fi
}

macman_release_download() {
  local url="$1"
  local out="${2:-}"
  if [ "$DOWNLOADER" = "curl" ]; then
    if [ -n "$out" ]; then
      curl -fsSL -o "$out" "$url"
    else
      curl -fsSL "$url"
    fi
  else
    if [ -n "$out" ]; then
      wget -q -O "$out" "$url"
    else
      wget -q -O - "$url"
    fi
  fi
}

macman_release_download_or_fail() {
  local url="$1"
  local out="${2:-}"
  if ! macman_release_download "$url" "$out"; then
    echo "Failed to download $url" >&2
    exit 1
  fi
}

macman_release_urlencode() {
  local value="$1"
  local encoded=""
  local i char
  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) encoded+="$char" ;;
      *)
        printf -v encoded '%s%%%02X' "$encoded" "'$char"
        ;;
    esac
  done
  printf '%s' "$encoded"
}

macman_release_form_encode() {
  local encoded=""
  while [ $# -gt 1 ]; do
    if [ -n "$encoded" ]; then
      encoded+="&"
    fi
    encoded+="$(macman_release_urlencode "$1")=$(macman_release_urlencode "$2")"
    shift 2
  done
  printf '%s' "$encoded"
}

macman_release_json_get_string() {
  local json
  json="$(macman_release_normalize_json "$1")"
  if [[ $json =~ \"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

macman_release_json_get_number() {
  local json
  json="$(macman_release_normalize_json "$1")"
  if [[ $json =~ \"$2\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

macman_release_normalize_json() {
  echo "$1" | tr -d '\n\r\t' | sed 's/[[:space:]]\+/ /g'
}

macman_release_parse_github_release_url() {
  local source_url="$1"
  if [[ "$source_url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$ ]]; then
    printf '%s\t%s\t%s\t%s\n' \
      "${BASH_REMATCH[1]}" \
      "${BASH_REMATCH[2]}" \
      "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[4]}"
    return 0
  fi
  return 1
}

macman_release_github_api_get() {
  local path="$1"
  macman_release_resolve_github_auth

  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer $GITHUB_AUTH_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$MACMAN_RELEASE_API_BASE_URL$path"
  else
    wget -q -O - \
      --header="Accept: application/vnd.github+json" \
      --header="Authorization: Bearer $GITHUB_AUTH_TOKEN" \
      --header="X-GitHub-Api-Version: 2022-11-28" \
      "$MACMAN_RELEASE_API_BASE_URL$path"
  fi
}

macman_release_resolve_newest_release_tag() {
  local releases_json normalized
  releases_json="$(macman_release_github_api_get "/releases?per_page=1")"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.[0].tag_name // empty' <<<"$releases_json"
    return 0
  fi
  normalized="$(macman_release_normalize_json "$releases_json")"
  if [[ $normalized =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

macman_release_resolve_asset_api_url_from_tag() {
  local tag="$1"
  local asset_name="$2"
  local response asset_url normalized asset_block
  response="$(macman_release_github_api_get "/releases/tags/$tag")"
  if command -v jq >/dev/null 2>&1; then
    asset_url="$(echo "$response" | jq -r --arg asset_name "$asset_name" '.assets[] | select(.name == $asset_name) | .url' | head -n 1)"
  else
    normalized="$(macman_release_normalize_json "$response")"
    asset_block="$(printf '%s' "$normalized" | grep -oE '\{[^{}]*"name"[[:space:]]*:[[:space:]]*"[^"]+"[^{}]*"url"[[:space:]]*:[[:space:]]*"https://api\.github\.com/repos/[^"]+/releases/assets/[0-9]+"[^{}]*\}' | grep "\"name\":\"$asset_name\"" | head -n 1 || true)"
    if [ -n "$asset_block" ]; then
      asset_url="$(macman_release_json_get_string "$asset_block" "url" || true)"
    else
      asset_url=""
    fi
  fi

  if [ -z "$asset_url" ]; then
    echo "Failed to resolve GitHub release asset URL for tag $tag asset $asset_name" >&2
    exit 1
  fi
  printf '%s' "$asset_url"
}

macman_release_platform_target() {
  case "$MACMAN_RELEASE_PLATFORM" in
    linux-amd64) printf '%s' "linux-amd64" ;;
    linux-arm64) printf '%s' "linux-arm64" ;;
    osx-amd64) printf '%s' "osx-amd64" ;;
    osx-arm64) printf '%s' "osx-arm64" ;;
    *)
      echo "Unsupported platform: $MACMAN_RELEASE_PLATFORM" >&2
      exit 1
      ;;
  esac
}

macman_release_macman_asset_name() {
  printf 'macman-%s' "$(macman_release_platform_target)"
}

macman_release_macmand_asset_name() {
  printf 'macmand-%s.zip' "$(macman_release_platform_target)"
}

macman_release_platform() {
  case "$(uname -s)" in
    Linux) MACMAN_RELEASE_OS="linux" ;;
    Darwin) MACMAN_RELEASE_OS="osx" ;;
    *)
      echo "Unsupported OS: $(uname -s)" >&2
      exit 1
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) MACMAN_RELEASE_ARCH="amd64" ;;
    arm64|aarch64) MACMAN_RELEASE_ARCH="arm64" ;;
    *)
      echo "Unsupported arch: $(uname -m)" >&2
      exit 1
      ;;
  esac

  if [ "$MACMAN_RELEASE_OS" = "osx" ] && [ "$MACMAN_RELEASE_ARCH" = "amd64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
    MACMAN_RELEASE_ARCH="arm64"
  fi

  MACMAN_RELEASE_PLATFORM="${MACMAN_RELEASE_OS}-${MACMAN_RELEASE_ARCH}"
}

macman_release_platform_supported() {
  case "$MACMAN_RELEASE_PLATFORM" in
    linux-amd64|linux-arm64|osx-amd64|osx-arm64)
      return 0
      ;;
  esac
  return 1
}

macman_release_require_checksum_tool() {
  if [ "$MACMAN_RELEASE_OS" = "osx" ]; then
    if ! command -v shasum >/dev/null 2>&1; then
      echo "shasum is required but not installed" >&2
      exit 1
    fi
  else
    if ! command -v sha256sum >/dev/null 2>&1; then
      echo "sha256sum is required but not installed" >&2
      exit 1
    fi
  fi
}

macman_release_is_epoch_in_future() {
  local epoch="${1:-0}"
  local now
  now="$(date +%s)"
  [ "$epoch" -gt "$now" ]
}

macman_release_github_post_form() {
  local url="$1"
  shift
  local body
  body="$(macman_release_form_encode "$@")"

  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL \
      -X POST \
      -H "Accept: application/json" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data "$body" \
      "$url"
  else
    wget -q -O - \
      --method=POST \
      --header="Accept: application/json" \
      --header="Content-Type: application/x-www-form-urlencoded" \
      --body-data="$body" \
      "$url"
  fi
}

macman_release_load_app_token_cache() {
  MACMAN_APP_ACCESS_TOKEN=""
  MACMAN_APP_REFRESH_TOKEN=""
  MACMAN_APP_ACCESS_TOKEN_EXPIRES_AT=0
  MACMAN_APP_REFRESH_TOKEN_EXPIRES_AT=0

  if [ ! -f "$MACMAN_APP_TOKEN_FILE" ]; then
    return 1
  fi

  local cache_json
  cache_json="$(cat "$MACMAN_APP_TOKEN_FILE")"

  if command -v jq >/dev/null 2>&1; then
    MACMAN_APP_ACCESS_TOKEN="$(echo "$cache_json" | jq -r '.access_token // empty')"
    MACMAN_APP_REFRESH_TOKEN="$(echo "$cache_json" | jq -r '.refresh_token // empty')"
    MACMAN_APP_ACCESS_TOKEN_EXPIRES_AT="$(echo "$cache_json" | jq -r '.access_token_expires_at // 0')"
    MACMAN_APP_REFRESH_TOKEN_EXPIRES_AT="$(echo "$cache_json" | jq -r '.refresh_token_expires_at // 0')"
  else
    MACMAN_APP_ACCESS_TOKEN="$(macman_release_json_get_string "$cache_json" "access_token" || true)"
    MACMAN_APP_REFRESH_TOKEN="$(macman_release_json_get_string "$cache_json" "refresh_token" || true)"
    MACMAN_APP_ACCESS_TOKEN_EXPIRES_AT="$(macman_release_json_get_number "$cache_json" "access_token_expires_at" || printf '0')"
    MACMAN_APP_REFRESH_TOKEN_EXPIRES_AT="$(macman_release_json_get_number "$cache_json" "refresh_token_expires_at" || printf '0')"
  fi

  [ -n "$MACMAN_APP_ACCESS_TOKEN" ]
}

macman_release_save_app_token_cache() {
  local access_token="$1"
  local refresh_token="$2"
  local expires_in="$3"
  local refresh_expires_in="$4"
  local now
  now="$(date +%s)"
  local access_expires_at=$((now + expires_in - 60))
  local refresh_expires_at=$((now + refresh_expires_in - 300))

  mkdir -p "$MACMAN_CONFIG_DIR"
  chmod 700 "$MACMAN_CONFIG_DIR" 2>/dev/null || true
  printf '{\n  "access_token": "%s",\n  "refresh_token": "%s",\n  "access_token_expires_at": %s,\n  "refresh_token_expires_at": %s\n}\n' \
    "$(macman_release_json_escape "$access_token")" \
    "$(macman_release_json_escape "$refresh_token")" \
    "$access_expires_at" \
    "$refresh_expires_at" > "$MACMAN_APP_TOKEN_FILE"
  chmod 600 "$MACMAN_APP_TOKEN_FILE" 2>/dev/null || true
}

macman_release_json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

macman_release_open_browser_if_possible() {
  local url="$1"
  if [ -n "${MACMAN_RELEASE_NO_BROWSER_OPEN:-}" ] && [ "${MACMAN_RELEASE_NO_BROWSER_OPEN}" = "1" ]; then
    return 0
  fi
  if [ "$MACMAN_RELEASE_OS" = "osx" ] && command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || true
  elif [ "$MACMAN_RELEASE_OS" = "linux" ] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  fi
}

macman_release_refresh_app_access_token() {
  if ! macman_release_load_app_token_cache || [ -z "$MACMAN_APP_REFRESH_TOKEN" ] || ! macman_release_is_epoch_in_future "${MACMAN_APP_REFRESH_TOKEN_EXPIRES_AT:-0}"; then
    return 1
  fi

  local response
  if ! response="$(macman_release_github_post_form "https://github.com/login/oauth/access_token" \
    client_id "$MACMAN_GITHUB_APP_CLIENT_ID" \
    grant_type "refresh_token" \
    refresh_token "$MACMAN_APP_REFRESH_TOKEN")"; then
    return 1
  fi

  local error access_token refresh_token expires_in refresh_expires_in
  error="$(macman_release_json_get_string "$response" "error" || true)"
  if [ -n "$error" ]; then
    return 1
  fi

  access_token="$(macman_release_json_get_string "$response" "access_token" || true)"
  refresh_token="$(macman_release_json_get_string "$response" "refresh_token" || true)"
  expires_in="$(macman_release_json_get_number "$response" "expires_in" || printf '0')"
  refresh_expires_in="$(macman_release_json_get_number "$response" "refresh_token_expires_in" || printf '0')"

  if [ -z "$access_token" ] || [ -z "$refresh_token" ] || [ "$expires_in" -le 0 ] || [ "$refresh_expires_in" -le 0 ]; then
    return 1
  fi

  macman_release_save_app_token_cache "$access_token" "$refresh_token" "$expires_in" "$refresh_expires_in"
  GITHUB_AUTH_TOKEN="$access_token"
  AUTH_KIND="app"
  return 0
}

macman_release_start_device_flow() {
  local response device_code user_code verification_uri interval expires_in
  response="$(macman_release_github_post_form "https://github.com/login/device/code" client_id "$MACMAN_GITHUB_APP_CLIENT_ID")"
  device_code="$(macman_release_json_get_string "$response" "device_code" || true)"
  user_code="$(macman_release_json_get_string "$response" "user_code" || true)"
  verification_uri="$(macman_release_json_get_string "$response" "verification_uri" || true)"
  interval="$(macman_release_json_get_number "$response" "interval" || printf '5')"
  expires_in="$(macman_release_json_get_number "$response" "expires_in" || printf '900')"

  if [ -z "$device_code" ] || [ -z "$user_code" ] || [ -z "$verification_uri" ]; then
    echo "Failed to start GitHub device flow" >&2
    exit 1
  fi

  echo "Authenticate with GitHub to download private release assets."
  echo "Open: $verification_uri"
  echo "Code: $user_code"
  macman_release_open_browser_if_possible "$verification_uri"

  local started_at now response_token error access_token refresh_token token_expires_in refresh_expires_in
  started_at="$(date +%s)"
  while true; do
    response_token="$(macman_release_github_post_form "https://github.com/login/oauth/access_token" \
      client_id "$MACMAN_GITHUB_APP_CLIENT_ID" \
      device_code "$device_code" \
      grant_type "urn:ietf:params:oauth:grant-type:device_code")"
    error="$(macman_release_json_get_string "$response_token" "error" || true)"

    if [ -z "$error" ]; then
      access_token="$(macman_release_json_get_string "$response_token" "access_token" || true)"
      refresh_token="$(macman_release_json_get_string "$response_token" "refresh_token" || true)"
      token_expires_in="$(macman_release_json_get_number "$response_token" "expires_in" || printf '0')"
      refresh_expires_in="$(macman_release_json_get_number "$response_token" "refresh_token_expires_in" || printf '0')"
      if [ -z "$access_token" ] || [ -z "$refresh_token" ] || [ "$token_expires_in" -le 0 ] || [ "$refresh_expires_in" -le 0 ]; then
        echo "GitHub device flow returned an incomplete token response" >&2
        exit 1
      fi
      macman_release_save_app_token_cache "$access_token" "$refresh_token" "$token_expires_in" "$refresh_expires_in"
      GITHUB_AUTH_TOKEN="$access_token"
      AUTH_KIND="app"
      return 0
    fi

    case "$error" in
      authorization_pending)
        sleep "$interval"
        ;;
      slow_down)
        interval=$((interval + 5))
        sleep "$interval"
        ;;
      expired_token|access_denied)
        echo "GitHub device flow failed: $error" >&2
        exit 1
        ;;
      *)
        echo "GitHub device flow failed: $error" >&2
        exit 1
        ;;
    esac

    now="$(date +%s)"
    if [ $((now - started_at)) -ge "$expires_in" ]; then
      echo "GitHub device flow code expired before authentication completed" >&2
      exit 1
    fi
  done
}

macman_release_use_cached_app_token_if_available() {
  if ! macman_release_load_app_token_cache; then
    return 1
  fi
  if [ -n "$MACMAN_APP_ACCESS_TOKEN" ] && macman_release_is_epoch_in_future "${MACMAN_APP_ACCESS_TOKEN_EXPIRES_AT:-0}"; then
    GITHUB_AUTH_TOKEN="$MACMAN_APP_ACCESS_TOKEN"
    AUTH_KIND="app"
    return 0
  fi
  macman_release_refresh_app_access_token
}

macman_release_require_pat_token() {
  if [ -n "${GITHUB_AUTH_TOKEN:-}" ]; then
    AUTH_KIND="pat"
    return 0
  fi

  if [ -n "${MACMAN_RELEASE_SILENT:-}" ] || [ ! -r /dev/tty ]; then
    echo "GitHub personal access token authentication is required in non-interactive mode. Set GH_TOKEN or GITHUB_TOKEN, or run interactively to use browser login." >&2
    exit 1
  fi

  printf "GitHub personal access token: " >/dev/tty
  stty -echo </dev/tty
  IFS= read -r GITHUB_AUTH_TOKEN </dev/tty
  stty echo </dev/tty
  printf "\n" >/dev/tty

  GITHUB_AUTH_TOKEN="$(echo "$GITHUB_AUTH_TOKEN" | tr -d '[:space:]')"
  if [ -z "$GITHUB_AUTH_TOKEN" ]; then
    echo "A GitHub personal access token is required" >&2
    exit 1
  fi
  AUTH_KIND="pat"
}

macman_release_choose_auth_mode_interactive() {
  local selection
  echo "Authentication required."
  echo "1) GitHub browser login (recommended)"
  echo "2) Personal access token"
  while true; do
    printf "Select [1/2]: " >/dev/tty
    IFS= read -r selection </dev/tty
    case "$selection" in
      1) AUTH_MODE="app"; return 0 ;;
      2) AUTH_MODE="pat"; return 0 ;;
    esac
  done
}

macman_release_resolve_github_auth() {
  case "${AUTH_MODE:-auto}" in
    pat)
      macman_release_require_pat_token
      ;;
    app)
      if ! macman_release_use_cached_app_token_if_available; then
        if [ -n "${MACMAN_RELEASE_SILENT:-}" ] || [ ! -r /dev/tty ]; then
          echo "GitHub App authentication requires an interactive terminal or a cached token in non-interactive mode" >&2
          exit 1
        fi
        macman_release_start_device_flow
      fi
      ;;
    auto)
      if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
        macman_release_require_pat_token
        return 0
      fi
      if macman_release_use_cached_app_token_if_available; then
        return 0
      fi
      if [ -n "${MACMAN_RELEASE_SILENT:-}" ] || [ ! -r /dev/tty ]; then
        echo "Authentication required. Set GH_TOKEN or GITHUB_TOKEN, or use an interactive terminal to authenticate with GitHub browser login." >&2
        exit 1
      fi
      macman_release_choose_auth_mode_interactive
      macman_release_resolve_github_auth
      ;;
  esac
}

macman_release_download_github_asset() {
  local url="$1"
  local out="$2"
  macman_release_resolve_github_auth

  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL \
      -H "Accept: application/octet-stream" \
      -H "Authorization: Bearer $GITHUB_AUTH_TOKEN" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -o "$out" \
      "$url"
  else
    wget -q \
      --header="Accept: application/octet-stream" \
      --header="Authorization: Bearer $GITHUB_AUTH_TOKEN" \
      --header="X-GitHub-Api-Version: 2022-11-28" \
      -O "$out" \
      "$url"
  fi
}

macman_release_populate_github_metadata_from_url_if_needed() {
  if [ -n "${github_asset_api_url:-}" ] || [ -z "${url:-}" ]; then
    return 0
  fi

  local parsed_url
  parsed_url="$(macman_release_parse_github_release_url "$url" || true)"
  if [ -z "$parsed_url" ]; then
    return 0
  fi

  IFS=$'\t' read -r github_owner github_repo github_tag github_asset <<< "$parsed_url"
}

macman_release_get_manifest_values() {
  local json="$1"
  local platform="$2"
  json="$(macman_release_normalize_json "$json")"
  local section=""
  if [[ $json =~ \"$platform\"[[:space:]]*:[[:space:]]*\{([^}]*)\} ]]; then
    section="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  local url=""
  local checksum=""
  local github_asset_api_url=""
  local github_owner=""
  local github_repo=""
  local github_tag=""
  local github_asset=""
  if [[ $section =~ \"url\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    url="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"sha256\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    checksum="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_asset_api_url\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_asset_api_url="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_owner\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_owner="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_repo\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_repo="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_tag\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_tag="${BASH_REMATCH[1]}"
  fi
  if [[ $section =~ \"github_asset\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
    github_asset="${BASH_REMATCH[1]}"
  fi

  if { [ -n "$url" ] || [ -n "$github_asset_api_url" ]; } && [ -n "$checksum" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$url" \
      "$checksum" \
      "$github_asset_api_url" \
      "$github_owner" \
      "$github_repo" \
      "$github_tag" \
      "$github_asset"
    return 0
  fi
  return 1
}

macman_release_resolve_version() {
  local target="${1:-newest}"
  case "$target" in
    newest|latest|"")
      macman_release_resolve_newest_release_tag
      ;;
    *)
      printf '%s' "$target"
      ;;
  esac
}

macman_release_fetch_manifest() {
  local version="$1"
  macman_release_download_or_fail "$MACMAN_RELEASE_BASE_URL/$version/manifest.json"
}

macman_release_checksum_cmd() {
  local path="$1"
  if [ "$MACMAN_RELEASE_OS" = "osx" ]; then
    shasum -a 256 "$path" | cut -d' ' -f1
  else
    sha256sum "$path" | cut -d' ' -f1
  fi
}

macman_release_run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return $?
  fi
  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required for this installer" >&2
    exit 1
  fi
  sudo "$@"
}
