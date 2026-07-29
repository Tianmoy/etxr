#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT/etxr.sh"

FIXTURE="$TMP/release"
api_fixture=""
mkdir -p "$FIXTURE"

build_release_fixture() {
  local tag_version="$1" script_version="$2"
  local script_digest checksums_digest
  cat >"$FIXTURE/etxr.sh" <<EOF
#!/usr/bin/env bash
VERSION="$script_version"
printf '%s\n' "\$VERSION"
EOF
  chmod 755 "$FIXTURE/etxr.sh"
  script_digest="$(sha256sum "$FIXTURE/etxr.sh" | awk '{print $1}')"
  printf '%s  etxr.sh\n' "$script_digest" >"$FIXTURE/checksums.txt"
  checksums_digest="$(sha256sum "$FIXTURE/checksums.txt" | awk '{print $1}')"
  api_fixture="$(
    jq -n \
      --arg tag "v${tag_version}" \
      --arg script_digest "sha256:${script_digest}" \
      --arg checksums_digest "sha256:${checksums_digest}" \
      '{
        tag_name: $tag,
        assets: [
          {
            name: "etxr.sh",
            browser_download_url: "https://fixture.invalid/etxr.sh",
            digest: $script_digest
          },
          {
            name: "checksums.txt",
            browser_download_url: "https://fixture.invalid/checksums.txt",
            digest: $checksums_digest
          }
        ]
      }'
  )"
}

fetch_etxr_release_api() {
  printf '%s\n' "$api_fixture"
}

curl() {
  local output="" url="" argument
  while (($#)); do
    argument="$1"
    case "$argument" in
      -o)
        output="$2"
        shift 2
        ;;
      --proto|--connect-timeout|--max-time|--retry|--retry-delay|-H)
        shift 2
        ;;
      -*)
        shift
        ;;
      *)
        url="$argument"
        shift
        ;;
    esac
  done
  [[ -n "$output" ]] || return 2
  case "$url" in
    https://fixture.invalid/etxr.sh)
      cp "$FIXTURE/etxr.sh" "$output"
      ;;
    https://fixture.invalid/checksums.txt)
      cp "$FIXTURE/checksums.txt" "$output"
      ;;
    *)
      return 22
      ;;
  esac
}

test "$(etxr_version_compare 1.2.3 1.2.3)" = 0
test "$(etxr_version_compare 1.2.3 1.2.4)" = -1
test "$(etxr_version_compare 2.0.0 1.99.99)" = 1
test "$(etxr_version_compare 01.002.0003 1.2.3)" = 0

SELF_BIN="$TMP/installed-etxr"
cat >"$SELF_BIN" <<EOF
#!/usr/bin/env bash
VERSION="7.6.5"
touch "$TMP/installed-script-was-executed"
EOF
chmod 755 "$SELF_BIN"
test "$(etxr_installed_version)" = 7.6.5
test ! -e "$TMP/installed-script-was-executed"

build_release_fixture 9.8.7 9.8.7
download_etxr_release_script "$TMP/good"
test "$(cat "$TMP/good/VERSION")" = 9.8.7
test "$("$TMP/good/etxr.sh")" = 9.8.7

api_fixture="$(jq '(.assets[] | select(.name == "checksums.txt")).digest = null' \
  <<<"$api_fixture")"
if (download_etxr_release_script "$TMP/missing-api-digest") >/dev/null 2>&1; then
  echo "self-update unexpectedly accepted a missing Release API digest" >&2
  exit 1
fi

build_release_fixture 9.8.7 9.8.7
printf '\n# tampered\n' >>"$FIXTURE/etxr.sh"
if (download_etxr_release_script "$TMP/tampered") >/dev/null 2>&1; then
  echo "self-update unexpectedly accepted a tampered script" >&2
  exit 1
fi

build_release_fixture 9.8.7 9.8.6
if (download_etxr_release_script "$TMP/version-mismatch") >/dev/null 2>&1; then
  echo "self-update unexpectedly accepted a tag/script version mismatch" >&2
  exit 1
fi

echo "self-update-test: PASS"
