#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# RaspiBolt update checker
#
# Read-only. Makes no changes to the system.
#
# Prints a table comparing the currently installed version of
# every RaspiBolt application against the latest version
# available online, so you can see at a glance whether
# `raspibolt-updater.sh` has anything to do.
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
# NOTE: latest-version lookups use the unauthenticated GitHub
# API (60 requests/hour per source IP). Running this very
# frequently may hit that limit; a failed lookup is shown as
# "unknown" rather than aborting the whole check.
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
# releases instead, see below).
declare -A APP_SRC_DIR=(
    [electrs]="/home/admin/rust/electrs"
    [btcrpcexplorer]="/home/btcrpcexplorer/btc-rpc-explorer"
    [rtl]="/home/rtl/RTL"
    [mempool]="/home/mempool/mempool"
    [bos]="/home/bos/balanceofsatoshis"
    [circuitbreaker]="/home/circuitbreaker/circuitbreaker"
)

declare -A APP_SERVICE=(
    [bitcoin]="bitcoind"
    [electrs]="electrs"
    [btcrpcexplorer]="btcrpcexplorer"
    [lnd]="lnd"
    [rtl]="rtl"
    [mempool]="mempool"
    [bos]="bos-telegram"
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

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

# ------------------------------------------------------------
# Horizontal rules
#
# One width for every separator the script prints, so a rule spans
# the output instead of stopping short of it. The results table is
# the widest thing here: its four columns are 22 + 20 + 20 wide with
# a space between them, and the last one holds a status string as
# long as "unknown (lookup failed)". Derived from those numbers
# rather than typed out, so the rules keep matching the table if a
# column is ever resized, and so the "=" and "-" variants cannot
# drift apart.
#
# Note this is wider than the updater's rules (78, the width of its
# own longest line and of the login banner), because this table is
# wider than anything the updater prints.
# ------------------------------------------------------------

# the longest status string the table prints
status_longest="unknown (lookup failed)"
RULE_WIDTH=$(( 22 + 1 + 20 + 1 + 20 + 1 + ${#status_longest} ))
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

# ------------------------------------------------------------
# Root check
#
# This script is read-only, but it still needs to read into six
# other service users' home directories (electrs, btcrpcexplorer,
# rtl, mempool, bos, circuitbreaker) to check their Git
# checkouts. Those directories are mode 750, so an unprivileged
# user cannot traverse into them at all, and Git itself refuses
# to operate on a repository owned by a different user than the
# one running it. `sudo -u <appuser>` (used below) is the only
# way around both, and that in turn needs root. Run this with
# `sudo`.
#
# To avoid typing `sudo` every time, scope a NOPASSWD rule to
# exactly this script (e.g. via `sudo visudo -f
# /etc/sudoers.d/raspibolt-updater`):
#
#   admin ALL=(root) NOPASSWD: /usr/local/bin/update-check
#
# ...then alias `update-check` to go through sudo automatically,
# e.g. in ~/.bashrc:
#
#   alias update-check='sudo /usr/local/bin/update-check'
#
# Do NOT do the same for the updater (raspibolt-updater.sh /
# "update"): a NOPASSWD rule for that one is effectively
# root-equivalent, since it runs apt/systemctl and writes into
# /usr/local/bin. Typing your password for that one is intended.
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root (e.g. 'sudo update-check')."
fi

# ------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------

REQUIRED_COMMANDS=(
    curl
    jq
    git
    sudo
    stat
    sort
    grep
    awk
    systemctl
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Required command not found: $cmd"
done

# ------------------------------------------------------------
# Optional local configuration
#
# The same file the updater reads, so the two cannot drift apart:
# whatever paths, usernames and service names one of them is told
# about, the other sees too. The tables at the top of this script are
# the stock RaspiBolt layout; the config file, if present, overrides
# entries in them:
#
#   /etc/raspibolt-updater.conf   (or wherever $RASPIBOLT_UPDATER_CONF points)
#
# Keys that only make sense for the updater (BITCOIN_ARCH, LND_ARCH,
# LND_SIGNERS, BACKUP_ROOT) are simply ignored here. Since a root
# script sources it, it is refused unless root owns it and nobody
# else can write it. See raspibolt-updater.conf.example.
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
# and however this script happens to be invoked (sudo's
# secure_path includes /usr/local/bin; a bare user shell's PATH
# is not guaranteed to).
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

# Generic: current version of a Git-checkout application is
# whatever tag/commit its working tree currently has checked
# out.
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
# Build the table
# ------------------------------------------------------------

echo
echo "$RULE_HEAVY"
echo " RaspiBolt update check"
echo "$RULE_HEAVY"
echo
info "Looking up installed and latest versions..."
echo

printf "${BOLD}%-22s %-20s %-20s %-s${NC}\n" \
    "APPLICATION" "CURRENT" "LATEST" "STATUS"
printf '%s\n' "$RULE_LIGHT"

UPDATE_COUNT=0
UPTODATE_COUNT=0
UNKNOWN_COUNT=0
MISSING_COUNT=0

for app in "${APP_ORDER[@]}"; do
    name="${APP_NAME[$app]}"

    current="$(get_current_version "$app" || true)"
    latest="$(get_latest_version "$app" || true)"

    current_display="${current:--}"
    latest_display="${latest:--}"

    if [[ -z "$current" ]]; then
        status="${YELLOW}not installed${NC}"
        ((MISSING_COUNT += 1))
    elif [[ -z "$latest" ]]; then
        status="${YELLOW}unknown (lookup failed)${NC}"
        ((UNKNOWN_COUNT += 1))
    elif [[ "$(norm_ver "$current")" == "$(norm_ver "$latest")" ]]; then
        status="${GREEN}up to date${NC}"
        ((UPTODATE_COUNT += 1))
    else
        status="${RED}update available${NC}"
        ((UPDATE_COUNT += 1))
    fi

    printf "%-22s %-20s %-20s " "$name" "$current_display" "$latest_display"
    echo -e "$status"
done

echo
echo "$RULE_LIGHT"
echo
echo "Up to date       : $UPTODATE_COUNT"
echo "Updates available: $UPDATE_COUNT"
echo "Not installed    : $MISSING_COUNT"
echo "Unknown          : $UNKNOWN_COUNT"
echo

if (( UPDATE_COUNT > 0 )); then
    warning "Run raspibolt-updater.sh (e.g. as 'update') to install available updates."
else
    info "Nothing to do."
fi

echo
echo "$RULE_HEAVY"
echo

exit 0
