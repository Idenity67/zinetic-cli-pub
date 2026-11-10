#!/bin/bash
set -euo pipefail

ZE_VERSION="0.6.0-beta.1"
ZE_BASE_URL="${ZINETIC_ENDPOINT_BASE_URL:-https://github.com/Idenity67/zinetic-endpoint-pub/releases/download/v0.6.0-beta.1}"
ZE_BASE_URL="${ZE_BASE_URL%/}"
ZE_PKG="Zinetic-Endpoint-0.6.0-beta.1.pkg"
ZE_PKG_SHA256="550376a12b18b42f7af309c39ed43ae0943c557652ebd8ff7ba1444a05373d3a"
ZE_LINUX_SHA256_ZINETIC_AMD64="4fdd7f322327d3bcc6ae4da5772e291ef44bd6ac4b737ae4887b6fd1e0f58078"
ZE_LINUX_SHA256_ZINETICD_AMD64="c42e0416f2c2733081fe3ed70ffed7c5336537f0cfad2b8f2dfae51cd2572d74"
ZE_LINUX_SHA256_ZINETIC_ARM64="34d2f6f3719bf9e30cabc9b4c14963d9710016e2a294521148b107328d3d898d"
ZE_LINUX_SHA256_ZINETICD_ARM64="736b2557f1b07402e0956a0f224006142a13818f7b0a6dc22a2f7ce51873d7e6"
ZE_MACOS_BIN_DIR="/Library/Application Support/Zinetic/bin"
ZE_LINUX_BIN_DIR="/opt/zinetic/bin"
ZE_CLI_LINK="/usr/local/bin/zinetic"
ZE_SYSTEMD_RUNTIME="/run/systemd/system"
ZE_SYSTEMD_UNIT="/etc/systemd/system/zineticd-collector.service"
ZE_SYSTEMD_CREDS="/usr/bin/systemd-creds /bin/systemd-creds"
ZE_WSL_RELEASE="/proc/sys/kernel/osrelease"
ZE_WINDOWS_INSTALLER="${ZINETIC_ENDPOINT_WINDOWS_INSTALLER_URL:-https://cli.zinetic.net/endpoint/install.ps1}"
ZE_WINDOWS_COMMAND="irm $ZE_WINDOWS_INSTALLER | iex"
ZE_SERVICE_WAIT_SECONDS=90
ZE_SERVICE_POLL_SECONDS=3
ZE_OS=""
ZE_ARCH=""
ZE_BIN_DIR="$ZE_MACOS_BIN_DIR"
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

ze_as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		sudo "$@"
	fi
}

ze_windows_handoff() {
	local why="$1" shell="" candidate
	for candidate in powershell.exe pwsh.exe; do
		if command -v "$candidate" >/dev/null 2>&1; then
			shell="$candidate"
			break
		fi
	done
	if [ -z "$shell" ]; then
		ze_fail "$why; on Windows, open PowerShell and run: $ZE_WINDOWS_COMMAND"
	fi
	ze_say "$why, so the Windows installer is used instead."
	ze_say "It runs in PowerShell, and Windows asks for administrator rights."
	if ! "$shell" -NoProfile -ExecutionPolicy Bypass -Command "$ZE_WINDOWS_COMMAND" </dev/null; then
		ze_fail "the Windows installer did not finish; its messages above say why"
	fi
	ze_say ""
	ze_say "Run zinetic endpoint setup in a new PowerShell window; this shell does not see the updated PATH yet."
	exit 0
}

ze_is_wsl() {
	local release=""
	if [ -r "$ZE_WSL_RELEASE" ]; then
		release="$(cat "$ZE_WSL_RELEASE")"
	fi
	case "$release" in
	*[Mm]icrosoft* | *WSL*) return 0 ;;
	esac
	return 1
}

ze_require_rendered() {
	local platform="$1" sum
	shift
	for sum in "$@"; do
		case "$sum" in
		*[!0-9a-f]*) ze_fail "this installer was not built for $platform; install from https://cli.zinetic.net/endpoint/install.sh" ;;
		esac
		if [ "${#sum}" -ne 64 ]; then
			ze_fail "this installer was not built for $platform; install from https://cli.zinetic.net/endpoint/install.sh"
		fi
	done
}

ze_check_macos() {
	local major
	major="$(sw_vers -productVersion | cut -d. -f1)"
	case "$major" in
	'' | *[!0-9]*) ze_fail "the macOS version could not be read" ;;
	esac
	if [ "$major" -lt 12 ]; then
		ze_fail "macOS $(sw_vers -productVersion) is too old; Zinetic Endpoint needs macOS 12 or later"
	fi
	ze_require_rendered macOS "$ZE_PKG_SHA256"
	ZE_OS="darwin"
	ZE_BIN_DIR="$ZE_MACOS_BIN_DIR"
}

ze_has_systemd_creds() {
	local tool
	for tool in $ZE_SYSTEMD_CREDS; do
		if [ -x "$tool" ]; then
			return 0
		fi
	done
	return 1
}

ze_root_controlled() {
	local path="$1" uid gid mode
	read -r uid gid mode < <(stat -c '%u %g %a' "$path")
	if [ "$uid" != 0 ]; then
		printf '%s is owned by uid %s, not root' "$path" "$uid"
		return 1
	fi
	if [ $((8#$mode & 8#002)) -ne 0 ]; then
		printf '%s is writable by every user' "$path"
		return 1
	fi
	if [ $((8#$mode & 8#020)) -ne 0 ] && [ "$gid" != 0 ]; then
		printf '%s is writable by members of group %s' "$path" "$gid"
		return 1
	fi
	return 0
}

ze_check_linux_folders() {
	local dir problem
	dir="$(dirname "$ZE_LINUX_BIN_DIR")"
	while [ ! -e "$dir" ] && [ "$dir" != / ]; do
		dir="$(dirname "$dir")"
	done
	dir="$(readlink -f "$dir")"
	while :; do
		if ! problem="$(ze_root_controlled "$dir")"; then
			ze_fail "$problem; zineticd runs as root, so every folder above $ZE_LINUX_BIN_DIR must be owned by root and writable only by root"
		fi
		[ "$dir" = / ] && break
		dir="$(dirname "$dir")"
	done
}

ze_check_linux() {
	local machine version
	machine="$(uname -m)"
	case "$machine" in
	x86_64 | amd64) ZE_ARCH="amd64" ;;
	aarch64 | arm64) ZE_ARCH="arm64" ;;
	*) ze_fail "the $machine processor is not supported; Zinetic Endpoint runs on x86_64 and arm64 Linux" ;;
	esac
	if [ ! -d "$ZE_SYSTEMD_RUNTIME" ]; then
		ze_fail "Zinetic Endpoint runs as a systemd service, and systemd is not running on this machine"
	fi
	version="$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 }' | sed 's/[^0-9].*//')"
	case "$version" in
	'' | *[!0-9]*) ze_fail "the systemd version could not be read" ;;
	esac
	if [ "$version" -lt 250 ]; then
		ze_fail "this machine runs systemd $version; Zinetic Endpoint keeps its device key as a systemd encrypted credential, which needs systemd 250 or later"
	fi
	if ! ze_has_systemd_creds; then
		ze_fail "systemd-creds was not found; Zinetic Endpoint keeps its device key as a systemd encrypted credential, which needs systemd-creds from systemd 250 or later"
	fi
	ze_require_rendered Linux "$ZE_LINUX_SHA256_ZINETIC_AMD64" "$ZE_LINUX_SHA256_ZINETICD_AMD64" \
		"$ZE_LINUX_SHA256_ZINETIC_ARM64" "$ZE_LINUX_SHA256_ZINETICD_ARM64"
	ze_check_linux_folders
	ZE_OS="linux"
	ZE_BIN_DIR="$ZE_LINUX_BIN_DIR"
}

ze_check_platform() {
	local system
	system="$(uname -s)"
	case "$system" in
	Darwin) ze_check_macos ;;
	Linux)
		if ze_is_wsl; then
			ze_windows_handoff "this is Linux running under WSL, and Zinetic Endpoint protects the Windows device itself"
		fi
		ze_check_linux
		;;
	MINGW* | MSYS* | CYGWIN* | UCRT* | CLANG* | *_NT-*) ze_windows_handoff "this is a Windows shell ($system)" ;;
	*) ze_fail "$system is not supported; Zinetic Endpoint runs on macOS, Linux and Windows" ;;
	esac
}

ze_installed_version() {
	local zinetic="$ZE_BIN_DIR/zinetic"
	if [ -x "$zinetic" ]; then
		"$zinetic" version 2>/dev/null | awk 'NR == 1 && $1 == "zinetic" { print $2 }' || true
	fi
}

ze_release_line() {
	printf '%s\n' "$1" | sed -n 's/^\(..*\)-[0-9]\{8\}-g[0-9a-f]\{7,40\}$/\1/p'
}

ze_release_date() {
	printf '%s\n' "$1" | sed -n 's/^..*-\([0-9]\{8\}\)-g[0-9a-f]\{7,40\}$/\1/p'
}

ze_semver_identifiers() {
	local list="$1" strict="$2" id
	local -a ids
	case "$list" in
	"" | .* | *. | *..*) return 1 ;;
	esac
	IFS=. read -r -a ids <<<"$list"
	for id in "${ids[@]}"; do
		case "$id" in
		0?*)
			if [ "$strict" = 1 ] && ze_digits "$id"; then
				return 1
			fi
			;;
		esac
	done
}

ze_digits() {
	case "$1" in
	"" | *[!0-9]*) return 1 ;;
	esac
}

ze_semver() {
	local pattern='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z.-]+))?(\+([0-9A-Za-z.-]+))?$'
	local core pre build has_pre has_build
	[[ $1 =~ $pattern ]] || return 1
	core="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
	has_pre="${BASH_REMATCH[4]}"
	pre="${BASH_REMATCH[5]}"
	has_build="${BASH_REMATCH[6]}"
	build="${BASH_REMATCH[7]}"
	if [ -n "$has_pre" ]; then
		ze_semver_identifiers "$pre" 1 || return 1
	fi
	if [ -n "$has_build" ]; then
		ze_semver_identifiers "$build" 0 || return 1
	fi
	printf '%s %s\n' "$core" "$pre"
}

ze_order_text() {
	local sorted
	if [ "$1" = "$2" ]; then
		printf '=\n'
		return 0
	fi
	sorted="$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort)"
	if [ "${sorted%%$'\n'*}" = "$1" ]; then
		printf '<\n'
	else
		printf '>\n'
	fi
}

ze_order_digits() {
	if [ "${#1}" -lt "${#2}" ]; then
		printf '<\n'
	elif [ "${#1}" -gt "${#2}" ]; then
		printf '>\n'
	else
		ze_order_text "$1" "$2"
	fi
}

ze_order_identifiers() {
	if ze_digits "$1" && ze_digits "$2"; then
		ze_order_digits "$1" "$2"
	elif ze_digits "$1"; then
		printf '<\n'
	elif ze_digits "$2"; then
		printf '>\n'
	else
		ze_order_text "$1" "$2"
	fi
}

ze_semver_order() {
	local a b order i
	local a_major a_minor a_patch a_pre b_major b_minor b_patch b_pre
	local -a x y
	a="$(ze_semver "$1")" || return 1
	b="$(ze_semver "$2")" || return 1
	read -r a_major a_minor a_patch a_pre <<<"$a"
	read -r b_major b_minor b_patch b_pre <<<"$b"
	for order in "$(ze_order_digits "$a_major" "$b_major")" "$(ze_order_digits "$a_minor" "$b_minor")" "$(ze_order_digits "$a_patch" "$b_patch")"; do
		if [ "$order" != "=" ]; then
			printf '%s\n' "$order"
			return 0
		fi
	done
	if [ -z "$a_pre" ] || [ -z "$b_pre" ]; then
		if [ -z "$a_pre" ] && [ -z "$b_pre" ]; then
			printf '=\n'
		elif [ -z "$a_pre" ]; then
			printf '>\n'
		else
			printf '<\n'
		fi
		return 0
	fi
	IFS=. read -r -a x <<<"$a_pre"
	IFS=. read -r -a y <<<"$b_pre"
	i=0
	while [ "$i" -lt "${#x[@]}" ] && [ "$i" -lt "${#y[@]}" ]; do
		order="$(ze_order_identifiers "${x[$i]}" "${y[$i]}")"
		if [ "$order" != "=" ]; then
			printf '%s\n' "$order"
			return 0
		fi
		i=$((i + 1))
	done
	ze_order_digits "${#x[@]}" "${#y[@]}"
}

ze_installed_is_newer() {
	local installed="$1" installed_date release_date order
	if order="$(ze_semver_order "$installed" "$ZE_VERSION")"; then
		if [ "$order" = ">" ]; then
			return 0
		fi
		return 1
	fi
	if ze_semver "$installed" >/dev/null && [ -n "$(ze_release_date "$ZE_VERSION")" ]; then
		return 0
	fi
	installed_date="$(ze_release_date "$installed")"
	release_date="$(ze_release_date "$ZE_VERSION")"
	[ -n "$installed_date" ] && [ -n "$release_date" ] &&
		[ "$(ze_release_line "$installed")" = "$(ze_release_line "$ZE_VERSION")" ] &&
		[ "$installed_date" -gt "$release_date" ]
}

ze_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

ze_fetch() {
	local name="$1" out="$2" url="$ZE_BASE_URL/$1"
	local progress=(--silent --show-error)
	if [ -t 2 ]; then
		progress=(--progress-bar)
	fi
	ze_say "Downloading $name"
	if ! curl --fail --location --retry 3 --connect-timeout 20 "${progress[@]}" --output "$out" "$url"; then
		ze_fail "could not download $url; nothing was installed"
	fi
}

ze_check_sum() {
	local file="$1" expected="$2" what="$3" actual
	actual="$(ze_sha256 "$file")"
	if [ "$actual" != "$expected" ]; then
		ze_fail "the downloaded $what does not match the published checksum (expected $expected, got $actual); nothing was installed"
	fi
}

ze_install_macos() {
	local pkg="$ZE_WORK/$ZE_PKG"
	ze_fetch "$ZE_PKG" "$pkg"
	ze_check_sum "$pkg" "$ZE_PKG_SHA256" "package"
	ze_say "Checksum verified"
	if [ "$(id -u)" -eq 0 ]; then
		installer -pkg "$pkg" -target / || ze_fail "the macOS installer failed; see /var/log/install.log"
	else
		ze_say "Installing needs administrator rights. macOS may ask for your password."
		sudo installer -pkg "$pkg" -target / || ze_fail "the macOS installer failed; see /var/log/install.log"
	fi
}

ze_install_linux() {
	local cli="zinetic-linux-$ZE_ARCH" daemon="zineticd-linux-$ZE_ARCH" cli_sum daemon_sum
	case "$ZE_ARCH" in
	amd64)
		cli_sum="$ZE_LINUX_SHA256_ZINETIC_AMD64"
		daemon_sum="$ZE_LINUX_SHA256_ZINETICD_AMD64"
		;;
	arm64)
		cli_sum="$ZE_LINUX_SHA256_ZINETIC_ARM64"
		daemon_sum="$ZE_LINUX_SHA256_ZINETICD_ARM64"
		;;
	esac
	ze_fetch "$cli" "$ZE_WORK/zinetic"
	ze_fetch "$daemon" "$ZE_WORK/zineticd"
	ze_check_sum "$ZE_WORK/zinetic" "$cli_sum" "$cli"
	ze_check_sum "$ZE_WORK/zineticd" "$daemon_sum" "$daemon"
	ze_say "Checksums verified"
	if [ "$(id -u)" -ne 0 ]; then
		ze_say "Installing needs administrator rights. sudo may ask for your password."
	fi
	local folder
	for folder in "$(dirname "$ZE_BIN_DIR")" "$ZE_BIN_DIR"; do
		ze_as_root install -d -o root -g root -m 0755 "$folder" ||
			ze_fail "could not create $folder"
		if ! ze_as_root chown root:root "$folder" || ! ze_as_root chmod 0755 "$folder"; then
			ze_fail "could not make $folder belong to root"
		fi
	done
	ze_as_root install -o root -g root -m 0755 "$ZE_WORK/zineticd" "$ZE_BIN_DIR/zineticd" ||
		ze_fail "could not install zineticd into $ZE_BIN_DIR"
	ze_as_root install -o root -g root -m 0755 "$ZE_WORK/zinetic" "$ZE_BIN_DIR/zinetic" ||
		ze_fail "could not install zinetic into $ZE_BIN_DIR"
	if ! ze_as_root mkdir -p "$(dirname "$ZE_CLI_LINK")" || ! ze_as_root ln -sfn "$ZE_BIN_DIR/zinetic" "$ZE_CLI_LINK"; then
		ze_say "Could not link $ZE_CLI_LINK to $ZE_BIN_DIR/zinetic; run zinetic as \"$ZE_BIN_DIR/zinetic\"."
	fi
	if [ -f "$ZE_SYSTEMD_UNIT" ]; then
		if ze_as_root "$ZE_BIN_DIR/zineticd" collector start </dev/null >/dev/null 2>&1; then
			ze_say "Restarted the endpoint service with the new version."
		else
			ze_say "The endpoint service did not restart with the new version. Run: zinetic endpoint restart"
		fi
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

ze_status_json() {
	"$ZE_BIN_DIR/zinetic" endpoint status --json 2>/dev/null || true
}

ze_endpoint_state() {
	local view
	view="$(ze_status_json)"
	printf '%s\n' "$view" | sed -n 's/.*"state":"\([A-Z_]*\)".*/\1/p' | head -n 1
}

ze_service_runs_release() {
	local view service daemon
	view="$(ze_status_json)"
	service="$(printf '%s\n' "$view" | sed -n 's/.*"service":{\([^}]*\)}.*/\1/p' | head -n 1)"
	daemon="$(printf '%s\n' "$view" | sed -n 's/.*"daemon_version":"\([^"]*\)".*/\1/p' | head -n 1)"
	case "$service" in
	*'"running":true'*) ;;
	*) return 1 ;;
	esac
	case "$view" in
	*'"code":"SERVICE_OUTDATED"'*) return 1 ;;
	esac
	[ "$daemon" = "$ZE_VERSION" ]
}

ze_wait_for_service() {
	local deadline=$((SECONDS + ZE_SERVICE_WAIT_SECONDS))
	if ze_service_runs_release; then
		return 0
	fi
	ze_say "Waiting up to $ZE_SERVICE_WAIT_SECONDS seconds for the endpoint service to start Zinetic Endpoint $ZE_VERSION"
	while [ "$SECONDS" -lt "$deadline" ]; do
		sleep "$ZE_SERVICE_POLL_SECONDS"
		if ze_service_runs_release; then
			return 0
		fi
	done
	return 1
}

ze_next_steps() {
	local moment="${1:-}" state
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
		if [ "$moment" = after-install ] && [ "${ZINETIC_ENDPOINT_SKIP_SERVICE_WAIT:-}" != 1 ] && ! ze_wait_for_service; then
			ze_say "Warning: the endpoint service did not come back on Zinetic Endpoint $ZE_VERSION within $ZE_SERVICE_WAIT_SECONDS seconds, so this device may not be protected until it does. The device keeps its enrollment. To see what the service is doing, run:"
			ze_say "  $(ze_command_name) endpoint status"
			ze_say "If it does not show the service running $ZE_VERSION, restart it:"
			ze_say "  $(ze_command_name) endpoint restart"
		else
			ze_say "This device is already set up and keeps its enrollment. To see how the endpoint is doing, run:"
			ze_say "  $(ze_command_name) endpoint status"
		fi
		;;
	esac
}

ze_main() {
	local installed
	case "$ZE_VERSION$ZE_BASE_URL" in
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
		if ! ze_installed_is_newer "$installed"; then
			ze_say "Upgrading Zinetic Endpoint from $installed to $ZE_VERSION"
		elif [ "${ZINETIC_ENDPOINT_ALLOW_DOWNGRADE:-0}" = "1" ]; then
			ze_say "Downgrading Zinetic Endpoint from $installed to $ZE_VERSION"
		else
			ze_fail "this device runs Zinetic Endpoint $installed, which is newer than $ZE_VERSION, so nothing was changed. To install $ZE_VERSION anyway, run the installer with ZINETIC_ENDPOINT_ALLOW_DOWNGRADE=1."
		fi
	else
		ze_say "Installing Zinetic Endpoint $ZE_VERSION"
	fi
	ZE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/zinetic-endpoint.XXXXXX")"
	trap ze_cleanup EXIT
	case "$ZE_OS" in
	darwin) ze_install_macos ;;
	linux) ze_install_linux ;;
	esac
	installed="$(ze_installed_version)"
	if [ "$installed" != "$ZE_VERSION" ]; then
		ze_fail "the package was installed, but $ZE_BIN_DIR/zinetic reports version ${installed:-none} instead of $ZE_VERSION"
	fi
	ze_say ""
	ze_say "Zinetic Endpoint $ZE_VERSION is installed."
	ze_next_steps after-install
}

ze_main "$@"
