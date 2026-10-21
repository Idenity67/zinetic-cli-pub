#!/bin/bash
set -euo pipefail

ZE_VERSION="p1-04-uat-20261021-g7ff1a2d"
ZE_BASE_URL="${ZINETIC_ENDPOINT_BASE_URL:-https://github.com/Idenity67/zinetic-endpoint-pub/releases/download/p1-04-uat-20261021-g7ff1a2d}"
ZE_BASE_URL="${ZE_BASE_URL%/}"
ZE_PKG="Zinetic-Endpoint-p1-04-uat-20261021-g7ff1a2d.pkg"
ZE_PKG_SHA256="a195990c12ba10a94ab65d8683c93543f4d69e2ab690aa5a9f9c237837de4aff"
ZE_BIN_DIR="/Library/Application Support/Zinetic/bin"
ZE_CLI_LINK="/usr/local/bin/zinetic"
ZE_WINDOWS_COMMAND="irm https://cli.zinetic.net/endpoint/install.ps1 | iex"
ZE_WORK=""

ze_say() {
	printf '%s\n' "$*"
}

ze_fail() {
	printf 'zinetic installer: %s\n' "$*" >&2
	exit 1
}

ze_cleanup() {
	if [ -n "$ZE_WORK" ]; then
		rm -rf "$ZE_WORK"
	fi
}

ze_check_platform() {
	local system major
	system="$(uname -s)"
	case "$system" in
	Darwin) ;;
	Linux) ze_fail "Linux is not supported by this release; Zinetic Endpoint currently runs on macOS and Windows" ;;
	MINGW* | MSYS* | CYGWIN*) ze_fail "on Windows, open PowerShell as Administrator and run: $ZE_WINDOWS_COMMAND" ;;
	*) ze_fail "$system is not supported; Zinetic Endpoint runs on macOS and Windows" ;;
	esac
	major="$(sw_vers -productVersion | cut -d. -f1)"
	case "$major" in
	'' | *[!0-9]*) ze_fail "the macOS version could not be read" ;;
	esac
	if [ "$major" -lt 12 ]; then
		ze_fail "macOS $(sw_vers -productVersion) is too old; Zinetic Endpoint needs macOS 12 or later"
	fi
}

ze_installed_version() {
	local zinetic="$ZE_BIN_DIR/zinetic"
	if [ -x "$zinetic" ]; then
		"$zinetic" version 2>/dev/null | awk 'NR == 1 && $1 == "zinetic" { print $2 }' || true
	fi
}

ze_download() {
	local url="$ZE_BASE_URL/$ZE_PKG" out="$1"
	local progress=(--silent --show-error)
	if [ -t 2 ]; then
		progress=(--progress-bar)
	fi
	ze_say "Downloading $ZE_PKG"
	if ! curl --fail --location --retry 3 --connect-timeout 20 "${progress[@]}" --output "$out" "$url"; then
		ze_fail "could not download $url; nothing was installed"
	fi
}

ze_verify() {
	local actual
	actual="$(shasum -a 256 "$1" | awk '{ print $1 }')"
	if [ "$actual" != "$ZE_PKG_SHA256" ]; then
		ze_fail "the downloaded package does not match the published checksum (expected $ZE_PKG_SHA256, got $actual); nothing was installed"
	fi
	ze_say "Checksum verified"
}

ze_install() {
	local pkg="$1"
	if [ "$(id -u)" -eq 0 ]; then
		installer -pkg "$pkg" -target / || ze_fail "the macOS installer failed; see /var/log/install.log"
	else
		ze_say "Installing needs administrator rights. macOS may ask for your password."
		sudo installer -pkg "$pkg" -target / || ze_fail "the macOS installer failed; see /var/log/install.log"
	fi
}

ze_command_name() {
	local found
	found="$(command -v zinetic 2>/dev/null || true)"
	if [ "$found" = "$ZE_CLI_LINK" ] || [ "$found" = "$ZE_BIN_DIR/zinetic" ]; then
		printf 'zinetic'
	else
		printf '"%s/zinetic"' "$ZE_BIN_DIR"
	fi
}

ze_endpoint_state() {
	local view
	view="$("$ZE_BIN_DIR/zinetic" endpoint status --json 2>/dev/null || true)"
	printf '%s\n' "$view" | sed -n 's/.*"state":"\([A-Z_]*\)".*/\1/p' | head -n 1
}

ze_next_steps() {
	local state
	state="$(ze_endpoint_state)"
	ze_say ""
	case "$state" in
	"" | NOT_INSTALLED | SETUP_REQUIRED)
		ze_say "Next, set up this device. Run this as yourself, not with sudo:"
		ze_say "  $(ze_command_name) endpoint setup"
		;;
	ENROLLMENT_INCOMPLETE)
		ze_say "Setup has not finished on this device. To continue it, run this as yourself, not with sudo:"
		ze_say "  $(ze_command_name) endpoint setup"
		;;
	*)
		ze_say "This device is already set up and keeps its enrollment. To see how the endpoint is doing, run:"
		ze_say "  $(ze_command_name) endpoint status"
		;;
	esac
}

ze_main() {
	local installed
	case "$ZE_VERSION$ZE_PKG_SHA256" in
	*@*) ze_fail "this installer template has not been rendered for a release" ;;
	esac
	ze_check_platform
	installed="$(ze_installed_version)"
	if [ "$installed" = "$ZE_VERSION" ] && [ "${ZINETIC_ENDPOINT_REINSTALL:-0}" != "1" ]; then
		ze_say "Zinetic Endpoint $ZE_VERSION is already installed."
		ze_say "To install it again, run the installer with ZINETIC_ENDPOINT_REINSTALL=1."
		ze_next_steps
		return 0
	fi
	if [ -n "$installed" ] && [ "$installed" != "$ZE_VERSION" ]; then
		ze_say "Upgrading Zinetic Endpoint from $installed to $ZE_VERSION"
	else
		ze_say "Installing Zinetic Endpoint $ZE_VERSION"
	fi
	ZE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/zinetic-endpoint.XXXXXX")"
	trap ze_cleanup EXIT
	ze_download "$ZE_WORK/$ZE_PKG"
	ze_verify "$ZE_WORK/$ZE_PKG"
	ze_install "$ZE_WORK/$ZE_PKG"
	installed="$(ze_installed_version)"
	if [ "$installed" != "$ZE_VERSION" ]; then
		ze_fail "the package was installed, but $ZE_BIN_DIR/zinetic reports version ${installed:-none} instead of $ZE_VERSION"
	fi
	ze_say ""
	ze_say "Zinetic Endpoint $ZE_VERSION is installed."
	ze_next_steps
}

ze_main "$@"
