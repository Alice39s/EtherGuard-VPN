#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT=etherguard-winlab
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
readonly ENV_FILE="$SCRIPT_DIR/.env.local"
readonly LIMIT_WARN_KIB=$((36 * 1024 * 1024))
readonly LIMIT_HARD_KIB=$((40 * 1024 * 1024))

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

compose() {
	docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" --file "$COMPOSE_FILE" "$@"
}

usage_kib() {
	du -sk "$SCRIPT_DIR" 2>/dev/null | awk '{print $1}'
}

check_usage() {
	local mode=${1:-normal}
	local used
	used=$(usage_kib)
	if ((used > LIMIT_HARD_KIB)); then
		printf 'error: lab uses %.1f GiB, exceeding the 40 GiB limit\n' "$(awk -v n="$used" 'BEGIN { print n / 1048576 }')" >&2
		[[ "$mode" == cache ]] && exit 1
	elif ((used > LIMIT_WARN_KIB)); then
		printf 'warning: lab uses %.1f GiB, exceeding the 36 GiB warning threshold\n' "$(awk -v n="$used" 'BEGIN { print n / 1048576 }')" >&2
	fi
}

verify_file() {
	local file=$1 expected=$2 actual
	actual=$(sha256sum "$file" | awk '{print $1}')
	[[ "$actual" == "$expected" ]] || die "checksum mismatch for $(basename "$file")"
}

download_fixed_assets() {
	local sha name url target temp
	while read -r sha name url; do
		[[ -n "$sha" ]] || continue
		target="$SCRIPT_DIR/cache/$name"
		if [[ -f "$target" ]]; then
			verify_file "$target" "$sha"
			continue
		fi
		check_usage cache
		temp="$target.part"
		curl --fail --location --retry 3 --output "$temp" "$url"
		verify_file "$temp" "$sha"
		mv "$temp" "$target"
	done <"$SCRIPT_DIR/checksums.txt"
}

download_go() {
	local version=$1
	local format=$2
	local filename="go${version}.windows-amd64.${format}"
	local manifest sha target temp
	manifest=$(mktemp)
	curl --fail --silent --show-error --location --output "$manifest" 'https://go.dev/dl/?mode=json&include=all'
	sha=$(jq -er --arg version "go$version" --arg filename "$filename" '.[] | select(.version == $version) | .files[] | select(.filename == $filename) | .sha256' "$manifest")
	rm -f "$manifest"
	target="$SCRIPT_DIR/cache/$filename"
	if [[ -f "$target" ]]; then
		verify_file "$target" "$sha"
		return
	fi
	check_usage cache
	temp="$target.part"
	curl --fail --location --retry 3 --output "$temp" "https://go.dev/dl/$filename"
	verify_file "$temp" "$sha"
	mv "$temp" "$target"
}

ports_are_free() {
	local port
	for port in 18006 13389 12222 30001; do
		if ss -H -lntup 2>/dev/null | grep -Eq ":${port}([[:space:]]|$)"; then
			die "port $port is already in use"
		fi
	done
}

prepare() {
	need docker
	need curl
	need jq
	need sha256sum
	need ss
	[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || die '/dev/kvm is not readable and writable'
	[[ -c /dev/net/tun ]] || die '/dev/net/tun is unavailable'
	docker info >/dev/null
	docker compose version >/dev/null
	local free_kib
	free_kib=$(df -Pk "$SCRIPT_DIR" | awk 'NR == 2 {print $4}')
	((free_kib >= 48 * 1024 * 1024)) || die 'at least 48 GiB free disk space is required before preparation'
	ports_are_free
	mkdir -p "$SCRIPT_DIR"/{cache/go-mod,cache/go-build,shared,artifacts,state/win10-ltsc,state/win7}
	chmod 700 "$SCRIPT_DIR"/{cache,cache/go-mod,cache/go-build,shared,artifacts,state,state/win10-ltsc,state/win7}
	download_fixed_assets
	download_go 1.26.5 zip
	download_go 1.20.14 msi
	cp -f "$SCRIPT_DIR/cache/dist.win10.zip" "$SCRIPT_DIR/oem/"
	cp -f "$SCRIPT_DIR/cache/dist.win7.zip" "$SCRIPT_DIR/oem/"
	cp -f "$SCRIPT_DIR/cache/OpenSSH-Win64-7.7.2.zip" "$SCRIPT_DIR/oem/"
	cp -f "$SCRIPT_DIR/cache/Windows6.1-KB4490628-x64.msu" "$SCRIPT_DIR/oem/"
	cp -f "$SCRIPT_DIR/cache/Windows6.1-KB4474419-v3-x64.msu" "$SCRIPT_DIR/oem/"
	cp -f "$SCRIPT_DIR/cache/go1.26.5.windows-amd64.zip" "$SCRIPT_DIR/oem/"
	cp -f "$SCRIPT_DIR/cache/go1.20.14.windows-amd64.msi" "$SCRIPT_DIR/oem/"
	check_usage
}

env_value() {
	local key=$1
	sed -n "s/^${key}=//p" "$ENV_FILE" | tail -1
}

assert_env() {
	[[ -f "$ENV_FILE" ]] || die 'create .env.local from the matching example first'
	[[ "$(stat -c '%a' "$ENV_FILE")" == 600 ]] || die '.env.local must have mode 0600'
	[[ -n "$(env_value WINDOWS_PASSWORD)" ]] || die 'WINDOWS_PASSWORD is empty'
}

running_vm() {
	docker ps --filter "label=com.docker.compose.project=$PROJECT" --filter 'status=running' --format '{{.Names}}' | head -1
}

up() {
	local target=${1:-}
	[[ "$target" == win10 || "$target" == win7 ]] || die 'usage: lab.sh up win10|win7'
	assert_env
	[[ -z "$(running_vm)" ]] || die 'a Windows VM is already running; stop it before switching environments'
	local expected
	if [[ "$target" == win10 ]]; then
		expected=10l
	else
		expected=7u
	fi
	[[ "$(env_value VERSION)" == "$expected" ]] || die ".env.local VERSION must be $expected for $target"
	check_usage cache
	compose up --detach
	check_usage
}

down() {
	assert_env
	compose --profile acceptance down --volumes --remove-orphans
	check_usage
}

status() {
	assert_env
	compose ps --all
	compose logs --tail 80 windows || true
	du -sh "$SCRIPT_DIR" "$SCRIPT_DIR"/state/* 2>/dev/null || true
	find "$SCRIPT_DIR/state" -type f \( -name '*.img' -o -name '*.qcow2' \) | while read -r disk; do
		printf '%s\n' "$disk"
		qemu-img info --force-share "$disk" 2>/dev/null | sed -n '/virtual size/p;/disk size/p' || ls -lh "$disk"
	done
	check_usage
}

tunnel() {
	printf '%s\n' 'ssh hk-coolify -N -L 18006:127.0.0.1:18006 -L 13389:127.0.0.1:13389 -L 12222:127.0.0.1:12222 -L 30001:127.0.0.1:30001'
}

sync_source() {
	need rsync
	local root
	root=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
	mkdir -p "$SCRIPT_DIR/shared/src"
	git -C "$root" ls-files -z |
		grep -zvE '(^|/)(AGENTS\.md|CLAUDE\.md|superpowers)(/|$)|(^|/)(\.env[^/]*|.*\.key|.*\.pem)$|(^|/)(etherguard-go[^/]*|artifacts|state|shared|cache)(/|$)' |
		rsync --archive --delete --from0 --files-from=- "$root/" "$SCRIPT_DIR/shared/src/"
}

win_exec() {
	assert_env
	shift || true
	[[ ${1:-} == -- ]] && shift
	(($# > 0)) || die 'usage: lab.sh exec -- <Windows command>'
	local vm password command
	vm=$(running_vm)
	[[ -n "$vm" ]] || die 'no Windows VM is running'
	password=$(env_value WINDOWS_PASSWORD)
	command=$*
	mkdir -p "$SCRIPT_DIR/cache/pip"
	docker run --rm \
		--network "container:$vm" \
		--volume "$SCRIPT_DIR/cache/pip:/root/.cache/pip" \
		--env "WINPASS=$password" \
		--env "WIN_COMMAND=$command" \
		--env PIP_ROOT_USER_ACTION=ignore \
		--env PYTHONWARNINGS=ignore \
		'python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf' \
		sh -lc 'pip install --disable-pip-version-check --quiet "setuptools<81" impacket==0.12.0 >/dev/null && printf "%s\nexit\n" "$WIN_COMMAND" | smbexec.py "EtherGuard:${WINPASS}@172.30.6.2"'
}

prune_win7() {
	[[ -z "$(running_vm)" ]] || die 'stop the VM before pruning Win7'
	local dir="$SCRIPT_DIR/state/win7"
	find "$dir" -maxdepth 1 -type f \( -name 'data.qcow2' -o -name 'windows.img' -o -name 'windows.qcow2' -o -name 'windows.boot' -o -name '*.rom' -o -name '*.vars' \) -print -delete
	rm -rf "$dir/backups"
	check_usage
}

case ${1:-} in
	prepare) prepare ;;
	up) up "${2:-}" ;;
	down) down ;;
	status) status ;;
	tunnel) tunnel ;;
	sync-source) sync_source ;;
	exec) win_exec "$@" ;;
	prune-win7) prune_win7 ;;
	*) die 'usage: lab.sh prepare|up win10|up win7|down|status|tunnel|sync-source|exec -- <command>|prune-win7' ;;
esac
