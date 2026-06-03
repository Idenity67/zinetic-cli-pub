#!/bin/sh
set -eu

DIST_REPO="${ZIN_DIST_REPO:-Idenity67/zinetic-cli-pub}"
REPO="${ZIN_REPO:-$DIST_REPO}"
BINARY="zin"
INSTALL_DIR="${ZIN_INSTALL_DIR:-/usr/local/bin}"
RELEASE_BASE_URL="${ZIN_RELEASE_BASE_URL:-https://github.com/${REPO}/releases/download}"
REQUIRE_SIGSTORE="${ZIN_REQUIRE_SIGSTORE:-0}"
SKIP_SIGSTORE="${ZIN_SKIP_SIGSTORE:-0}"
SIGSTORE_OIDC_ISSUER="${ZIN_SIGSTORE_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"
SIGSTORE_IDENTITY_REGEX="${ZIN_SIGSTORE_IDENTITY_REGEX:-^https://github\.com/Idenity67/zinetic-cli/\.github/workflows/release\.yaml@refs/tags/.*$}"
INSTALLER_ORIGIN="${ZIN_INSTALLER_ORIGIN:-https://cli.zinetic.net/install.sh}"

get_os() {
  case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) printf "unsupported OS: %s\n" "$(uname -s)" >&2; exit 1 ;;
  esac
}

get_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) printf "unsupported architecture: %s\n" "$(uname -m)" >&2; exit 1 ;;
  esac
}

get_latest_version() {
  if command -v gh >/dev/null 2>&1; then
    if GH_PROMPT_DISABLED=1 gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null; then
      return 0
    fi
  fi
  github_api "https://api.github.com/repos/${REPO}/releases/latest" | \
    grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/'
}

github_token() {
  if [ -n "${ZIN_GITHUB_TOKEN:-}" ]; then
    printf "%s" "$ZIN_GITHUB_TOKEN"
  elif [ -n "${GH_TOKEN:-}" ]; then
    printf "%s" "$GH_TOKEN"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    printf "%s" "$GITHUB_TOKEN"
  fi
}

github_api() {
  TOKEN=$(github_token)
  if [ -n "$TOKEN" ]; then
    curl -fsSL \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "$1"
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      "$1"
  fi
}

download_file() {
  URL="$1"
  DEST="$2"
  TOKEN=$(github_token)
  if [ -n "$TOKEN" ]; then
    curl -fsSL \
      -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/octet-stream" \
      -o "$DEST" \
      "$URL"
  else
    curl -fsSL -o "$DEST" "$URL"
  fi
}

download_release_assets() {
  VERSION="$1"
  ARCHIVE="$2"
  DEST_DIR="$3"
  if command -v gh >/dev/null 2>&1; then
    if GH_PROMPT_DISABLED=1 gh release download "$VERSION" --repo "$REPO" --pattern "$ARCHIVE" --pattern checksums.txt --pattern checksums.txt.sigstore.json --dir "$DEST_DIR" 2>/dev/null; then
      return 0
    fi
  fi

  URL="${RELEASE_BASE_URL%/}/${VERSION}/${ARCHIVE}"
  CHECKSUM_URL="${RELEASE_BASE_URL%/}/${VERSION}/checksums.txt"
  CHECKSUM_BUNDLE_URL="${RELEASE_BASE_URL%/}/${VERSION}/checksums.txt.sigstore.json"
  printf "Downloading %s...\n" "$URL"
  download_file "$URL" "${DEST_DIR}/${ARCHIVE}"
  download_file "$CHECKSUM_URL" "${DEST_DIR}/checksums.txt"
  download_file "$CHECKSUM_BUNDLE_URL" "${DEST_DIR}/checksums.txt.sigstore.json"
}

verify_sigstore_bundle() {
  if [ "$SKIP_SIGSTORE" = "1" ]; then
    printf "warning: Sigstore verification explicitly disabled via ZIN_SKIP_SIGSTORE=1\n" >&2
    printf "warning: installing without release signature verification\n" >&2
    return 0
  fi

  if ! command -v cosign >/dev/null 2>&1; then
    if [ "$REQUIRE_SIGSTORE" = "1" ]; then
      printf "error: cosign not found and Sigstore verification is required (ZIN_REQUIRE_SIGSTORE=1)\n" >&2
      exit 1
    fi
    printf "warning: cosign not found; cannot verify the release signature\n" >&2
    printf "warning: install cosign or set ZIN_SKIP_SIGSTORE=1 to acknowledge and skip verification\n" >&2
    return 0
  fi

  if [ ! -s "checksums.txt.sigstore.json" ]; then
    printf "error: cosign is installed but checksums.txt.sigstore.json is missing\n" >&2
    printf "error: refusing to install an unverified release; set ZIN_SKIP_SIGSTORE=1 to override\n" >&2
    exit 1
  fi

  printf "Verifying release signature with cosign...\n"
  if ! cosign verify-blob \
    --bundle checksums.txt.sigstore.json \
    --certificate-oidc-issuer "$SIGSTORE_OIDC_ISSUER" \
    --certificate-identity-regexp "$SIGSTORE_IDENTITY_REGEX" \
    checksums.txt >/dev/null 2>&1; then
    printf "error: Sigstore signature verification failed; refusing to install\n" >&2
    exit 1
  fi
  printf "Sigstore signature verified.\n"
}

main() {
  OS=$(get_os)
  ARCH=$(get_arch)
  VERSION="${ZIN_VERSION:-}"
  if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
    VERSION="$(get_latest_version)"
  fi

  if [ -z "$VERSION" ]; then
    printf "error: unable to determine latest version\n" >&2
    exit 1
  fi

  printf "Installing %s %s (%s/%s)...\n" "$BINARY" "$VERSION" "$OS" "$ARCH"
  printf "  source : %s\n" "$INSTALLER_ORIGIN"
  printf "  docs   : https://docs.zinetic.net/cli\n"

  EXT="tar.gz"
  if [ "$OS" = "windows" ]; then
    EXT="zip"
  fi

  ARCHIVE="${BINARY}_${VERSION#v}_${OS}_${ARCH}.${EXT}"
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  download_release_assets "$VERSION" "$ARCHIVE" "$TMPDIR"

  cd "$TMPDIR"
  verify_sigstore_bundle

  CHECKSUM_LINE=""
  while read -r checksum filename rest; do
    if [ "$filename" = "$ARCHIVE" ]; then
      CHECKSUM_LINE="${checksum}  ${filename}"
      break
    fi
  done < checksums.txt

  if [ -z "$CHECKSUM_LINE" ]; then
    printf "error: checksum for %s not found in checksums.txt\n" "$ARCHIVE" >&2
    exit 1
  fi
  printf "%s\n" "$CHECKSUM_LINE" > checksum.expected

  if [ "$OS" = "darwin" ] && command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c --quiet checksum.expected
  elif command -v sha256sum >/dev/null 2>&1 && sha256sum --version >/dev/null 2>&1; then
    sha256sum -c --quiet checksum.expected
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c --quiet checksum.expected
  else
    printf "error: unable to verify checksum (no sha256sum or shasum found)\n" >&2
    exit 1
  fi

  if [ "$EXT" = "tar.gz" ]; then
    tar -xzf "$ARCHIVE"
  else
    unzip -q "$ARCHIVE"
  fi

  if [ ! -d "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR" 2>/dev/null || true
  fi

  if [ ! -w "$INSTALL_DIR" ]; then
    printf "Installing to %s (requires sudo)...\n" "$INSTALL_DIR"
    sudo mkdir -p "$INSTALL_DIR"
    sudo install -m 755 "$BINARY" "$INSTALL_DIR/$BINARY"
  else
    install -m 755 "$BINARY" "$INSTALL_DIR/$BINARY"
  fi

  printf "Installed %s to %s/%s\n" "$VERSION" "$INSTALL_DIR" "$BINARY"
  printf "Run '%s version' to verify.\n" "$BINARY"
  printf "\nDocumentation: https://docs.zinetic.net/cli\n"
  printf "Support:        https://zinetic.net\n"
}

main
