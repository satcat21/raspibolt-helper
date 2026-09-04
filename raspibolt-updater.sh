#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# RaspiBolt updater
#
# For each RaspiBolt application: looks up the latest version
# online, and if a newer version exists, asks for confirmation
# before updating it. Finishes with `apt update / upgrade /
# autoremove`.
#
# Target: Debian 13 (Trixie) inside a Proxmox LXC, apps
# installed by hand following the official RaspiBolt guides:
#
#   Bitcoin Core      https://raspibolt.org/docs/bitcoin/bitcoin-client/
#   Electrs           https://raspibolt.org/docs/bitcoin/electrum-server/
#   BTC RPC Explorer  https://raspibolt.org/docs/bitcoin/blockchain-explorer/
#   LND               https://raspibolt.org/docs/lightning/lightning-client/
#   RTL               https://raspibolt.org/docs/lightning/web-app/
#   Mempool           https://raspibolt.org/docs/bonus/bitcoin/mempool/
#   Balance of Satoshis (BoS)
#     https://github.com/raspibolt/raspibolt/blob/v3-final/guide/bonus/lightning/balance-of-satoshis.md
#   Circuit Breaker
#     https://github.com/raspibolt/raspibolt/blob/v3-final/guide/bonus/lightning/circuit-breaker.md
#
# If your install paths, usernames or service names differ from
# the guides, adjust the APP_* tables below.
#
# Design notes:
#   - Runs as root. Everything that touches an application's
#     own source tree (git/npm/cargo/go) is executed as that
#     application's own Linux user via `sudo -u`, exactly like
#     a human operator following the guide would. Only
#     systemctl, apt and installing binaries into
#     /usr/local/bin happen directly as root.
#   - Bitcoin Core and LND are prebuilt binary releases:
#     tarballs are downloaded, checksummed, and (best-effort)
#     GPG-verified before their binaries replace the ones in
#     /usr/local/bin.
#   - Every other application is a Git checkout: it is updated
#     with `git fetch` + `git checkout <tag>`, then rebuilt
#     (cargo/npm/go) as its own user.
#   - Circuit Breaker has no tagged releases upstream; the
#     guide tracks the master branch, so it is updated by
#     commit instead of by version.
#   - A hard failure inside an application update (failed
#     checksum, failed build, service that won't start) aborts
#     the whole script via `die`, on purpose: on a node running
#     Bitcoin/Lightning software, silently continuing to the
#     next application after something went wrong is worse than
#     stopping and asking you to look. Already-updated apps are
#     unaffected, and re-running the script is safe -- apps
#     already on the latest version are skipped.
#   - No automatic rollback is attempted for Git-based apps
#     beyond what `.old` binary/checksum backups and Git history
#     already give you; see the per-app backup notes below.
# ============================================================

# ------------------------------------------------------------
# Application configuration
# ------------------------------------------------------------

APP_ORDER=(bitcoin electrs btcrpcexplorer lnd rtl mempool bos circuitbreaker)

declare -A APP_NAME=(
    [bitcoin]="Bitcoin Core"
    [electrs]="Electrs"
    [btcrpcexplorer]="BTC RPC Explorer"
    [lnd]="LND"
    [rtl]="RTL"
    [mempool]="Mempool"
    [bos]="Balance of Satoshis"
    [circuitbreaker]="Circuit Breaker"
)

# Linux user that owns/builds each application's source tree.
# (Electrs is built from the admin account per the RaspiBolt
#  guide, even though the "electrs" system user runs the
#  compiled binary as a service.)
declare -A APP_BUILD_USER=(
    [electrs]="admin"
    [btcrpcexplorer]="btcrpcexplorer"
    [rtl]="rtl"
    [mempool]="mempool"
    [bos]="bos"
    [circuitbreaker]="circuitbreaker"
)

# Source/build directories for the applications that are built
# from a Git checkout (Bitcoin Core and LND are prebuilt binary
# releases instead, see update_bitcoin/update_lnd below).
declare -A APP_SRC_DIR=(
    [electrs]="/home/admin/rust/electrs"
    [btcrpcexplorer]="/home/btcrpcexplorer/btc-rpc-explorer"
    [rtl]="/home/rtl/RTL"
    [mempool]="/home/mempool/mempool"
    [bos]="/home/bos/balanceofsatoshis"
    [circuitbreaker]="/home/circuitbreaker/circuitbreaker"
)

# Primary systemd service for each app. Leave empty ("") for
# apps that are not run as a persistent service.
declare -A APP_SERVICE=(
    [bitcoin]="bitcoind"
    [electrs]="electrs"
    [btcrpcexplorer]="btcrpcexplorer"
    [lnd]="lnd"
    [rtl]="rtl"
    [mempool]="mempool"
    [bos]=""
    [circuitbreaker]="circuitbreaker"
)

# GitHub repository used to look up the latest available
# version. Circuit Breaker has no tagged releases upstream
# (the guide tracks the master branch), so it is handled
# separately.
declare -A APP_GH_REPO=(
    [bitcoin]="bitcoin/bitcoin"
    [electrs]="romanz/electrs"
    [btcrpcexplorer]="janoside/btc-rpc-explorer"
    [lnd]="lightningnetwork/lnd"
    [rtl]="Ride-The-Lightning/RTL"
    [mempool]="mempool/mempool"
    [bos]="alexbosworth/balanceofsatoshis"
    [circuitbreaker]="lightningequipment/circuitbreaker"
)

declare -A APP_TAG_PATTERN=(
    [bitcoin]='^v[0-9]+\.[0-9]+(\.[0-9]+)?$'
    [electrs]='^v[0-9]+\.[0-9]+\.[0-9]+$'
    [btcrpcexplorer]='^v[0-9]+\.[0-9]+\.[0-9]+$'
    [lnd]='^v[0-9]+\.[0-9]+\.[0-9]+(-beta)?$'
    [rtl]='^v[0-9]+\.[0-9]+\.[0-9]+$'
    [mempool]='^v[0-9]+\.[0-9]+\.[0-9]+$'
    [bos]='^v[0-9]+\.[0-9]+\.[0-9]+$'
)

# LND release manifest signers, tried in this order.
#
# LND releases are signed by a rotating subset of maintainers rather
# than by one fixed key: v0.21.3-beta, for instance, carries no
# roasbeef signature at all, and assuming one made this script abort
# at the download step (curl --fail on a 404) before it could update
# anything. Each name here is looked up as manifest-<signer>-<version>.sig
# in the release, and the first that both exists and verifies is
# accepted; the matching public key is fetched from upstream's
# scripts/keys/<signer>.asc if it is not already in root's keyring.
# Reorder or extend the list -- here or in the config file below --
# if the maintainer set changes.
LND_SIGNERS=(
    roasbeef
    guggero
    ziggie1984
    ellemouton
    yyforyongyu
    bhandras
    carlaKC
    georgetsagk
    hieblmi
    gijswijs
    boris
    suheb
    ViktorT-11
    sputn1ck
    proofofkeags
    ffranr
)

BACKUP_ROOT="/root/raspibolt-updater-backups"
LOG_LINES=30

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# ------------------------------------------------------------
# Horizontal rules
#
# One width for every separator the script prints, so a rule spans
# the output instead of stopping short of it -- the widest line
# it prints is the architecture summary, at about 73 columns, and
# 78 is also what the login banner (raspibolt-motd.sh) rules to.
# Built rather than typed out, so the width is stated once and the
# "=" and "-" variants cannot drift apart.
# ------------------------------------------------------------

RULE_WIDTH=78
printf -v RULE_HEAVY '%*s' "$RULE_WIDTH" ''
RULE_HEAVY="${RULE_HEAVY// /=}"
printf -v RULE_LIGHT '%*s' "$RULE_WIDTH" ''
RULE_LIGHT="${RULE_LIGHT// /-}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    error "$*"
    exit 1
}

confirm() {
    local prompt="$1"
    local default="${2:-N}"
    local answer

    if [[ "$default" == "Y" ]]; then
        read -r -p "$prompt [Y/n] " answer
        answer="${answer:-Y}"
    else
        read -r -p "$prompt [y/N] " answer
        answer="${answer:-N}"
    fi

    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Normalize a version string for comparison so that "v31.1"
# and "v31.1.0" (GitHub tags vs. `bitcoind --version` output are
# not always padded to the same number of components) compare
# as equal, while still keeping suffixes like "-beta" intact.
norm_ver() {
    local v="${1#v}"
    local numeric="$v" suffix=""

    if [[ "$v" =~ ^([0-9]+(\.[0-9]+)*)(.*)$ ]]; then
        numeric="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[3]}"
    fi

    local IFS=.
    read -ra parts <<<"$numeric"
    while (( ${#parts[@]} < 3 )); do
        parts+=(0)
    done

    printf '%s%s' "${parts[*]}" "$suffix"
}

run_as() {
    local user="$1"
    shift
    sudo -u "$user" -H bash -lc "$*"
}

cleanup_on_exit() {
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup_on_exit EXIT

service_exists() {
    local service="$1"
    [[ -n "$service" ]] && systemctl list-unit-files "${service}.service" >/dev/null 2>&1
}

stop_service() {
    local service="$1"
    service_exists "$service" || return 0
    info "Stopping $service..."
    systemctl stop "$service"
}

start_and_check_service() {
    local service="$1"
    service_exists "$service" || return 0
    info "Starting $service..."
    systemctl start "$service"
    sleep 3
    if ! systemctl is-active --quiet "$service"; then
        error "$service is not active."
        journalctl -u "$service" -n "$LOG_LINES" --no-pager || true
        die "$service failed to start."
    fi
    success "$service is running."
}

# Warn about, and optionally discard, uncommitted local changes
# in a Git-checkout app before touching it. Returns 1 (without
# dying) if the user declines, so the caller can skip that app
# and move on to the next one.
check_clean_worktree() {
    local app="$1"
    local dir="${APP_SRC_DIR[$app]}"
    local user="${APP_BUILD_USER[$app]}"
    local changes

    changes="$(sudo -u "$user" git -C "$dir" status --porcelain)"

    if [[ -n "$changes" ]]; then
        warning "Uncommitted changes in $dir:"
        echo
        echo "$changes"
        echo
        confirm "Discard local changes and continue?" "N" || return 1
    fi

    return 0
}

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "This updater must be run as root."
fi

# ------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------

REQUIRED_COMMANDS=(
    curl
    jq
    git
    gpg
    sudo
    systemctl
    apt
    sha256sum
    tar
    install
    mktemp
    stat
    find
    sort
    grep
    awk
    journalctl
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Required command not found: $cmd"
done

# ------------------------------------------------------------
# Optional local configuration
#
# The tables above describe the stock RaspiBolt layout. Where your
# install differs -- other directories, usernames, service names, a
# different backup location, a different set of LND signers, or an
# architecture uname -m reports in a way this script cannot map --
# put the overrides in a config file rather than editing the script,
# so a script update cannot clobber them and the updater and the
# checker cannot drift apart:
#
#   /etc/raspibolt-updater.conf   (or wherever $RASPIBOLT_UPDATER_CONF points)
#
# It is sourced here, after the defaults, so it can assign straight
# into the tables above:  APP_SRC_DIR[electrs]="/opt/electrs"
# See raspibolt-updater.conf.example for every key. Since a root
# script sources it, it is refused unless root owns it and nobody
# else can write it.
# ------------------------------------------------------------

RASPIBOLT_UPDATER_CONF="${RASPIBOLT_UPDATER_CONF:-/etc/raspibolt-updater.conf}"

if [[ -f "$RASPIBOLT_UPDATER_CONF" ]]; then
    read -r conf_uid conf_perm < <(stat -c '%u %a' "$RASPIBOLT_UPDATER_CONF")

    if (( conf_uid != 0 )); then
        die "$RASPIBOLT_UPDATER_CONF is not owned by root; refusing to source it (chown root: it)."
    fi
    if (( (8#$conf_perm & 8#022) != 0 )); then
        die "$RASPIBOLT_UPDATER_CONF is writable by group or others; refusing to source it (chmod 600 it)."
    fi

    # shellcheck source=/dev/null
    source "$RASPIBOLT_UPDATER_CONF"
    info "Configuration overrides loaded from $RASPIBOLT_UPDATER_CONF"
fi

mkdir -p "$BACKUP_ROOT"

# ------------------------------------------------------------
# Architecture detection (for Bitcoin Core / LND binaries)
#
# Only these two apps ship prebuilt binaries; everything else is
# compiled on the machine and is architecture-agnostic. Values set in
# the config file win over detection, for the cases uname -m cannot
# answer on its own (a 32-bit userland on a 64-bit kernel, say).
# ------------------------------------------------------------

case "$(uname -m)" in
    x86_64)
        detected_bitcoin_arch="x86_64-linux-gnu"
        detected_lnd_arch="amd64"
        ;;
    aarch64)
        detected_bitcoin_arch="aarch64-linux-gnu"
        detected_lnd_arch="arm64"
        ;;
    *)
        detected_bitcoin_arch=""
        detected_lnd_arch=""
        ;;
esac

BITCOIN_ARCH="${BITCOIN_ARCH:-$detected_bitcoin_arch}"
LND_ARCH="${LND_ARCH:-$detected_lnd_arch}"

if [[ -z "$BITCOIN_ARCH" || -z "$LND_ARCH" ]]; then
    die "Unsupported architecture: $(uname -m). Set BITCOIN_ARCH and LND_ARCH in ${RASPIBOLT_UPDATER_CONF}."
fi

# ------------------------------------------------------------
# Latest-version lookups
# ------------------------------------------------------------

gh_latest_tag() {
    local repo="$1" pattern="$2"
    local response

    response="$(
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --retry 2 \
            --connect-timeout 10 \
            --max-time 20 \
            -H "User-Agent: raspibolt-updater" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${repo}/tags?per_page=100" \
            2>/dev/null
    )" || { echo ""; return; }

    jq -r '.[].name' <<<"$response" 2>/dev/null |
        grep -E "$pattern" |
        grep -viE 'rc[0-9]*$' |
        sort -V |
        tail -n1
}

latest_circuitbreaker() {
    git ls-remote \
        "https://github.com/${APP_GH_REPO[circuitbreaker]}.git" \
        refs/heads/master 2>/dev/null |
        awk '{print substr($1, 1, 7)}'
}

get_latest_version() {
    local app="$1"

    if [[ "$app" == "circuitbreaker" ]]; then
        latest_circuitbreaker
        return
    fi

    gh_latest_tag "${APP_GH_REPO[$app]}" "${APP_TAG_PATTERN[$app]}"
}

# ------------------------------------------------------------
# Installed-version lookups
# ------------------------------------------------------------

# Resolve a binary by its known RaspiBolt install location first,
# falling back to PATH lookup. This avoids false "not installed"
# results caused by PATH differing between an interactive shell
# and however this script happens to be invoked.
resolve_bin() {
    local name="$1"
    if [[ -x "/usr/local/bin/$name" ]]; then
        printf '%s' "/usr/local/bin/$name"
    else
        command -v "$name" 2>/dev/null
    fi
}

current_bitcoin() {
    local bin
    bin="$(resolve_bin bitcoind)"
    [[ -n "$bin" ]] || { echo ""; return; }
    "$bin" --version 2>/dev/null |
        head -n1 |
        grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' || echo ""
}

current_lnd() {
    local bin raw
    bin="$(resolve_bin lnd)"
    [[ -n "$bin" ]] || { echo ""; return; }
    raw="$("$bin" --version 2>/dev/null || true)"
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-beta)?' <<<"$raw" |
        head -n1 |
        sed 's/^/v/'
}

current_electrs() {
    local bin raw
    bin="$(resolve_bin electrs)"
    [[ -n "$bin" ]] || { echo ""; return; }
    raw="$("$bin" --version 2>/dev/null || true)"
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$raw" |
        head -n1 |
        sed 's/^/v/'
}

current_git_repo() {
    local app="$1"
    local dir="${APP_SRC_DIR[$app]}"
    local user="${APP_BUILD_USER[$app]}"

    [[ -d "$dir/.git" ]] || { echo ""; return; }

    sudo -u "$user" git -C "$dir" describe --tags --always 2>/dev/null || echo ""
}

# Circuit Breaker has no tagged releases upstream and tracks
# master (see latest_circuitbreaker()), so its "current version"
# must be a bare short commit hash too -- not `git describe`'s
# nearest-tag format ("v0.5.1-4-g53d4c4c"), which would never
# match.
current_circuitbreaker() {
    local dir="${APP_SRC_DIR[circuitbreaker]}"
    local user="${APP_BUILD_USER[circuitbreaker]}"

    [[ -d "$dir/.git" ]] || { echo ""; return; }

    sudo -u "$user" git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo ""
}

get_current_version() {
    local app="$1"

    case "$app" in
        bitcoin) current_bitcoin ;;
        lnd) current_lnd ;;
        electrs) current_electrs ;;
        circuitbreaker) current_circuitbreaker ;;
        *) current_git_repo "$app" ;;
    esac
}

# ------------------------------------------------------------
# Bitcoin Core update (prebuilt binary release)
# ------------------------------------------------------------

update_bitcoin() {
    local latest="$1"
    local version="${latest#v}"
    local tarball="bitcoin-${version}-${BITCOIN_ARCH}.tar.gz"
    local base_url="https://bitcoincore.org/bin/bitcoin-core-${version}"

    warning "Read the Bitcoin Core release notes before upgrading:"
    echo "  https://github.com/bitcoin/bitcoin/blob/master/doc/release-notes.md"
    echo

    TMP_DIR="$(mktemp -d)"

    (
        cd "$TMP_DIR"

        info "Downloading Bitcoin Core ${latest} for ${BITCOIN_ARCH}..."
        curl --fail --silent --show-error --location --retry 3 -O "${base_url}/${tarball}"
        curl --fail --silent --show-error --location --retry 3 -O "${base_url}/SHA256SUMS"
        curl --fail --silent --show-error --location --retry 3 -O "${base_url}/SHA256SUMS.asc"

        info "Verifying checksum..."
        sha256sum --ignore-missing --check SHA256SUMS

        info "Verifying signature..."
        if ! gpg --verify SHA256SUMS.asc SHA256SUMS; then
            warning "GPG signature verification failed or the release signing keys are not imported into root's keyring."
            warning "See: https://raspibolt.org/docs/bitcoin/bitcoin-client/ (verify section) for importing the guix builder keys."
            confirm "Continue anyway, relying on the checksum verification only?" "N" \
                || die "Update aborted: signature verification failed."
        fi

        info "Extracting..."
        tar -xzf "$tarball"
    )

    stop_service "${APP_SERVICE[bitcoin]}"

    info "Backing up current binaries..."
    for bin in bitcoind bitcoin-cli bitcoin-tx bitcoin-wallet bitcoin-util bitcoin-qt; do
        [[ -x "/usr/local/bin/$bin" ]] \
            && cp -a "/usr/local/bin/$bin" "/usr/local/bin/${bin}.old"
    done

    info "Installing new binaries..."
    install -m 0755 -o root -g root -t /usr/local/bin "$TMP_DIR/bitcoin-${version}/bin/"*

    rm -rf "$TMP_DIR"
    TMP_DIR=""

    start_and_check_service "${APP_SERVICE[bitcoin]}"

    success "Bitcoin Core updated to ${latest}."
}

# ------------------------------------------------------------
# LND update (prebuilt binary release)
# ------------------------------------------------------------

update_lnd() {
    local latest="$1"
    local base_url="https://github.com/lightningnetwork/lnd/releases/download/${latest}"
    local tarball="lnd-linux-${LND_ARCH}-${latest}.tar.gz"

    warning "LND releases can include one-way database migrations. Read the release notes before upgrading:"
    echo "  https://github.com/lightningnetwork/lnd/releases/tag/${latest}"
    echo

    if ! confirm "Have you read the release notes and backed up your channel state?" "N"; then
        die "Update aborted: please review the release notes first."
    fi

    TMP_DIR="$(mktemp -d)"

    (
        cd "$TMP_DIR"

        info "Downloading LND ${latest} for linux-${LND_ARCH}..."
        curl --fail --silent --show-error --location --retry 3 -O "${base_url}/${tarball}"
        curl --fail --silent --show-error --location --retry 3 -O "${base_url}/manifest-${latest}.txt"
        info "Verifying checksum..."
        sha256sum --check "manifest-${latest}.txt" --ignore-missing

        info "Verifying signature..."
        signature_ok=0
        for signer in "${LND_SIGNERS[@]}"; do
            # Not every maintainer signs every release, so a missing
            # signature file is the normal case rather than a failure:
            # move on to the next name instead of aborting the update.
            if ! curl --fail --silent --location --retry 2 -o "manifest-${signer}-${latest}.sig" "${base_url}/manifest-${signer}-${latest}.sig"; then
                rm -f "manifest-${signer}-${latest}.sig"
                continue
            fi

            if ! gpg --list-keys "$signer" >/dev/null 2>&1; then
                info "Importing the LND release signing key (${signer})..."
                curl --fail --silent --show-error --location "https://raw.githubusercontent.com/lightningnetwork/lnd/master/scripts/keys/${signer}.asc" | gpg --import || true
            fi

            if gpg --verify "manifest-${signer}-${latest}.sig" "manifest-${latest}.txt" 2>/dev/null; then
                success "Signature verified: ${latest} signed by ${signer}."
                signature_ok=1
                break
            fi

            warning "The signature by ${signer} did not verify; trying the next signer."
        done

        if (( signature_ok == 0 )); then
            warning "No LND release signature could be verified for ${latest}."
            warning "Signers tried: ${LND_SIGNERS[*]}"
            warning "Either none of them signed this release, or their keys could not be fetched."
            if ! confirm "Continue anyway, relying on the checksum verification only?" "N"; then
                die "Update aborted: signature verification failed."
            fi
        fi


        info "Extracting..."
        tar -xzf "$tarball"
    )

    stop_service "${APP_SERVICE[lnd]}"

    info "Backing up current binaries..."
    for bin in lnd lncli; do
        [[ -x "/usr/local/bin/$bin" ]] \
            && cp -a "/usr/local/bin/$bin" "/usr/local/bin/${bin}.old"
    done

    info "Installing new binaries..."
    install -m 0755 -o root -g root -t /usr/local/bin \
        "$TMP_DIR/lnd-linux-${LND_ARCH}-${latest}/"*

    rm -rf "$TMP_DIR"
    TMP_DIR=""

    start_and_check_service "${APP_SERVICE[lnd]}"

    warning "Monitor sync status until it settles: journalctl -f -u lnd  (watch for synced_to_chain: true)"

    success "LND updated to ${latest}."
}

# ------------------------------------------------------------
# Electrs update (built from source under the admin account)
# ------------------------------------------------------------

update_electrs() {
    local latest="$1"
    local dir="${APP_SRC_DIR[electrs]}"
    local user="${APP_BUILD_USER[electrs]}"

    [[ -d "$dir/.git" ]] \
        || die "Electrs source directory not found: $dir (adjust APP_SRC_DIR[electrs] if your install differs)"

    check_clean_worktree "electrs" || { warning "Electrs update skipped."; return 1; }

    info "Fetching electrs source..."
    sudo -u "$user" git -C "$dir" fetch --tags

    info "Cleaning working tree and checking out ${latest}..."
    sudo -u "$user" git -C "$dir" clean -xfd
    sudo -u "$user" git -C "$dir" checkout "$latest"

    if ! sudo -u "$user" git -C "$dir" verify-tag "$latest" 2>&1; then
        warning "GPG signature on tag ${latest} could not be verified (romanz's key may not be imported)."
        confirm "Continue anyway?" "N" || die "Update aborted: signature verification failed."
    fi

    info "Building electrs (cargo build --release, this can take a while)..."
    run_as "$user" "cd '$dir' && cargo clean && cargo build --locked --release"

    stop_service "${APP_SERVICE[electrs]}"

    [[ -x /usr/local/bin/electrs ]] && cp -a /usr/local/bin/electrs /usr/local/bin/electrs.old

    info "Installing new binary..."
    install -m 0755 -o root -g root -t /usr/local/bin "$dir/target/release/electrs"

    start_and_check_service "${APP_SERVICE[electrs]}"

    success "Electrs updated to ${latest}."
}

# ------------------------------------------------------------
# Generic Git + npm application update
# (BTC RPC Explorer, RTL, Balance of Satoshis)
# ------------------------------------------------------------

update_git_npm_app() {
    local app="$1" latest="$2" npm_cmd="$3"
    local dir="${APP_SRC_DIR[$app]}"
    local user="${APP_BUILD_USER[$app]}"
    local service="${APP_SERVICE[$app]}"
    local name="${APP_NAME[$app]}"

    [[ -d "$dir/.git" ]] \
        || die "$name source directory not found: $dir (adjust APP_SRC_DIR[$app] if your install differs)"

    check_clean_worktree "$app" || { warning "$name update skipped."; return 1; }

    stop_service "$service"

    info "Fetching $name source..."
    sudo -u "$user" git -C "$dir" fetch --tags
    sudo -u "$user" git -C "$dir" reset --hard HEAD

    info "Checking out ${latest}..."
    sudo -u "$user" git -C "$dir" checkout "$latest"

    if ! sudo -u "$user" git -C "$dir" verify-tag "$latest" >/dev/null 2>&1; then
        warning "GPG signature on tag ${latest} could not be verified (maintainer key may not be imported)."
        confirm "Continue anyway?" "N" || die "Update aborted: signature verification failed."
    fi

    info "Installing dependencies ($npm_cmd)..."
    run_as "$user" "cd '$dir' && $npm_cmd"

    start_and_check_service "$service"

    success "$name updated to ${latest}."
}

update_btcrpcexplorer() {
    update_git_npm_app "btcrpcexplorer" "$1" "npm install"
}

update_rtl() {
    update_git_npm_app "rtl" "$1" "npm install --omit=dev --legacy-peer-deps"
}

update_bos() {
    update_git_npm_app "bos" "$1" "npm install"

    if service_exists "bos-telegram"; then
        info "Restarting bos-telegram..."
        systemctl restart bos-telegram || warning "Could not restart bos-telegram."
    fi
}

# ------------------------------------------------------------
# Mempool update (separate backend + frontend build)
# ------------------------------------------------------------

update_mempool() {
    local latest="$1"
    local dir="${APP_SRC_DIR[mempool]}"
    local user="${APP_BUILD_USER[mempool]}"

    [[ -d "$dir/.git" ]] \
        || die "Mempool source directory not found: $dir (adjust APP_SRC_DIR[mempool] if your install differs)"

    warning "Some Mempool releases include a database migration. Review the release notes before upgrading:"
    echo "  https://github.com/mempool/mempool/releases/tag/${latest}"
    echo

    check_clean_worktree "mempool" || { warning "Mempool update skipped."; return 1; }

    stop_service "${APP_SERVICE[mempool]}"

    info "Fetching mempool source..."
    sudo -u "$user" git -C "$dir" fetch --tags
    sudo -u "$user" git -C "$dir" reset --hard HEAD
    sudo -u "$user" git -C "$dir" checkout "$latest"

    info "Building mempool backend..."
    run_as "$user" "cd '$dir/backend' && npm install --prod && npm run build"

    info "Building mempool frontend (this can take a while)..."
    run_as "$user" "cd '$dir/frontend' && npm install && npm run generate-themes && npm run generate-config && npm run ng -- build --configuration production && npm run sync-assets"

    start_and_check_service "${APP_SERVICE[mempool]}"

    success "Mempool updated to ${latest}."
}

# ------------------------------------------------------------
# Circuit Breaker update (rolling release, tracks master)
# ------------------------------------------------------------

update_circuitbreaker() {
    local dir="${APP_SRC_DIR[circuitbreaker]}"
    local user="${APP_BUILD_USER[circuitbreaker]}"

    [[ -d "$dir/.git" ]] \
        || die "Circuit Breaker source directory not found: $dir (adjust APP_SRC_DIR[circuitbreaker] if your install differs)"

    warning "Circuit Breaker has no tagged releases upstream; this tracks the master branch."
    echo "  Review recent commits before upgrading: https://github.com/lightningequipment/circuitbreaker/commits/master"
    echo

    check_clean_worktree "circuitbreaker" || { warning "Circuit Breaker update skipped."; return 1; }

    stop_service "${APP_SERVICE[circuitbreaker]}"

    info "Fetching circuitbreaker source..."
    sudo -u "$user" git -C "$dir" fetch origin master
    sudo -u "$user" git -C "$dir" reset --hard origin/master
    sudo -u "$user" git -C "$dir" checkout master

    info "Building circuitbreaker (go install)..."
    run_as "$user" "cd '$dir' && go install"

    start_and_check_service "${APP_SERVICE[circuitbreaker]}"

    success "Circuit Breaker updated."
}

run_update() {
    local app="$1" latest="$2"

    case "$app" in
        bitcoin) update_bitcoin "$latest" ;;
        electrs) update_electrs "$latest" ;;
        btcrpcexplorer) update_btcrpcexplorer "$latest" ;;
        lnd) update_lnd "$latest" ;;
        rtl) update_rtl "$latest" ;;
        mempool) update_mempool "$latest" ;;
        bos) update_bos "$latest" ;;
        circuitbreaker) update_circuitbreaker ;;
    esac
}

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------

echo
echo "$RULE_HEAVY"
echo " RaspiBolt updater"
echo "$RULE_HEAVY"
echo
info "Architecture: $(uname -m) (Bitcoin Core: $BITCOIN_ARCH, LND: $LND_ARCH)"

declare -A RESULT

for app in "${APP_ORDER[@]}"; do
    name="${APP_NAME[$app]}"

    echo
    echo "$RULE_LIGHT"
    echo " $name"
    echo "$RULE_LIGHT"

    current="$(get_current_version "$app" || true)"
    latest="$(get_latest_version "$app" || true)"

    if [[ -z "$current" ]]; then
        warning "$name does not appear to be installed. Skipping."
        RESULT[$app]="not installed"
        continue
    fi

    if [[ -z "$latest" ]]; then
        warning "Could not determine the latest $name version online. Skipping."
        RESULT[$app]="lookup failed"
        continue
    fi

    info "Current version: $current"
    info "Latest version:  $latest"

    if [[ "$(norm_ver "$current")" == "$(norm_ver "$latest")" ]]; then
        success "$name is already up to date."
        RESULT[$app]="up to date"
        continue
    fi

    echo
    if ! confirm "Update $name from $current to $latest?" "N"; then
        warning "$name update skipped."
        RESULT[$app]="skipped"
        continue
    fi

    if run_update "$app" "$latest"; then
        RESULT[$app]="updated to $latest"
    else
        RESULT[$app]="skipped"
    fi
done

# ------------------------------------------------------------
# APT maintenance
# ------------------------------------------------------------

echo
echo "$RULE_HEAVY"
echo " System package maintenance"
echo "$RULE_HEAVY"
echo

info "Running apt update..."
apt update

info "Running apt upgrade..."
apt upgrade -y

info "Running apt autoremove..."
apt autoremove -y

success "APT maintenance completed."

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "$RULE_HEAVY"
echo " Summary"
echo "$RULE_HEAVY"
echo

for app in "${APP_ORDER[@]}"; do
    printf "%-22s %s\n" "${APP_NAME[$app]}" "${RESULT[$app]:-not checked}"
done

echo
echo "$RULE_HEAVY"
success "RaspiBolt update run completed."
echo "$RULE_HEAVY"
echo
