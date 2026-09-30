#!/usr/bin/env bash
# fm-today-lib.sh - the Today bridge's portal settings and its one authorized
# POST, shared by bin/fm-today-bridge.sh and bin/fm-today-notes.sh so every
# bridge endpoint reads the same settings and applies the same URL rule.
# docs/today-contract.md owns authentication; docs/configuration.md "Today
# bridge" owns the settings.
#
# fm_today_portal_settings <home>
#   Read FM_TODAY_PORTAL_URL and FM_TODAY_BRIDGE_TOKEN, the environment first,
#   then <home>/.env (bin/fm-env-lib.sh's fmx_env_get). On success set
#   FM_TODAY_URL (without a trailing /) and FM_TODAY_TOKEN and return 0.
#   Otherwise set FM_TODAY_SETTINGS_ERROR to one line ending "nothing was
#   sent" and return 2: a missing value, a URL that is neither https:// nor
#   http:// to 127.0.0.1 or localhost, or a token containing white space.
# fm_today_post <path> <body-file> <response-file> <private-dir>
#   POST <body-file> to $FM_TODAY_URL<path> with the bearer token, passed to
#   curl through a private header file under <private-dir> (never argv) and
#   removed at once. Print the HTTP status, or 000 when the portal could not be
#   reached, with curl's error in <private-dir>/curl.err. Bounded by
#   FM_TODAY_POST_MAX_SECS (default 30) plus the connect time.

# shellcheck source=bin/fm-env-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-env-lib.sh"

fm_today_setting() {  # <key> <home>
  local key=$1
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
  else
    fmx_env_get "$key" "$2/.env"
  fi
}

# FM_TODAY_URL, FM_TODAY_TOKEN, and FM_TODAY_SETTINGS_ERROR are read by callers.
# shellcheck disable=SC2034
fm_today_portal_settings() {  # <home>
  local url token missing=''
  FM_TODAY_URL=
  FM_TODAY_TOKEN=
  FM_TODAY_SETTINGS_ERROR=
  url=$(fm_today_setting FM_TODAY_PORTAL_URL "$1")
  token=$(fm_today_setting FM_TODAY_BRIDGE_TOKEN "$1")
  [ -n "$url" ] || missing="FM_TODAY_PORTAL_URL"
  [ -n "$token" ] || missing="${missing:+$missing and }FM_TODAY_BRIDGE_TOKEN"
  if [ -n "$missing" ]; then
    FM_TODAY_SETTINGS_ERROR="missing $missing; nothing was sent"
    return 2
  fi
  if ! [[ "$url" =~ ^https://|^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?(/.*)?$ ]]; then
    FM_TODAY_SETTINGS_ERROR="FM_TODAY_PORTAL_URL must be https://, or http:// only to 127.0.0.1 or localhost; nothing was sent"
    return 2
  fi
  case "$token" in
    *[[:space:]]*)
      FM_TODAY_SETTINGS_ERROR="FM_TODAY_BRIDGE_TOKEN must not contain whitespace; nothing was sent"
      return 2
      ;;
  esac
  FM_TODAY_URL=${url%/}
  FM_TODAY_TOKEN=$token
}

fm_today_post() {  # <path> <body-file> <response-file> <private-dir>
  local path=$1 body=$2 response=$3 dir=$4 hdr code max
  max=${FM_TODAY_POST_MAX_SECS:-30}
  case "$max" in ''|*[!0-9]*|0) max=30 ;; esac
  hdr="$dir/headers"
  (umask 077; printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$FM_TODAY_TOKEN" > "$hdr")
  code=$(curl -sS --connect-timeout 10 --max-time "$max" -o "$response" -w '%{http_code}' -H @"$hdr" \
    --data-binary @"$body" "$FM_TODAY_URL$path" 2>"$dir/curl.err") || code=000
  rm -f -- "$hdr"
  printf '%s\n' "${code:-000}"
}
