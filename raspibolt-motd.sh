#!/bin/bash
# /etc/systemd/system/raspibolt-pulse.sh
set -u

# make executable and copy script to /etc/update-motd.d/
# user must be able to execute bitcoin-cli and lncli

# Script configuration
# ------------------------------------------------------------------------------

# set datadir
bitcoin_dir="/mnt/ext/bitcoin"    # Raspibolt 1.x, 2.x
if [ -d "/data/bitcoin" ]; then
  bitcoin_dir="/data/bitcoin"     # Raspibolt 3.x
fi

# determine second drive info
#drivecount=$(lsblk --output MOUNTPOINT | grep / | grep -v /boot | sort | wc -l)
#if [ $drivecount -gt 1 ]; then
#ext_storage2nd=$(lsblk --output MOUNTPOINT | grep / | grep -v /boot | sort | sed -n 2p)
#else
#  ext_storage2nd=""
#fi
ext_storage2nd=$(df --output=avail -h /mnt/lxc-btc-data 2>/dev/null | tail -1 | tr -d ' ')
# expected service names... common alternate values supported
sn_bitcoin="bitcoind"
sn_lnd="lnd"
sn_cln="lightningd"                     # cln, lightningd
sn_btcrpcexplorer="btcrpcexplorer"
sn_electrs="electrs"
sn_fulcrum="fulcrum"
sn_rtl="rtl"                            # rtl, ridethelightning
sn_thunderhub="thunderhub"
sn_mempool="mempool"
sn_circuitbreaker="circuitbreaker"
sn_bostelegram="bos-telegram"           # optional; bos itself is a CLI tool, not a persistent service

# Helper functionality
# ------------------------------------------------------------------------------

# set colors
color_red='\033[0;31m'
color_green='\033[0;32m'
color_yellow='\033[0;33m'
color_grey='\033[0;37m'
color_orange='\033[38;5;208m'
color_magenta='\033[0;35m'

# Group a number with European-style thousands separators ("." every
# 3 digits, e.g. 16749875 -> "16.749.875"); used for sat amounts and
# for the block height. Values under 1000 are left as-is. Implemented
# without relying on locale-aware printf ("%'d"), since the LXC's
# locale isn't guaranteed to group digits with "." rather than ",".
fmt_num() {
  local n="${1//[^0-9]/}"
  [ -z "$n" ] && { printf '0'; return; }
  awk -v n="$n" 'BEGIN {
    out = ""; c = 0
    for (i = length(n); i >= 1; i--) {
      out = substr(n, i, 1) out
      c++
      if (c % 3 == 0 && i != 1) out = "." out
    }
    print out
  }'
}

# Run a command as one of the application users.
#
# Root (the usual case: /etc/update-motd.d runs this at login, and so
# does `sudo raspibolt`) can just switch user. An unprivileged admin
# cannot: `sudo -u bos ...` is not covered by the NOPASSWD rule the
# README suggests, which is scoped to this script's own path, so sudo
# would demand a password mid-banner -- and with stderr discarded the
# caller only sees the app reported as missing. So when not root, drop
# sudo and run the command directly, which works for anything the
# caller can already read and execute; that is exactly what adding the
# admin account to the app's group (`usermod -aG bos admin`, then log
# in again) buys. `-n` keeps even the root path from ever blocking on
# a prompt.
run_as_app_user() {
  local user="$1"
  shift
  if [ "$(id -u)" -eq 0 ]; then
    sudo -n -u "$user" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

# Read a Git checkout that belongs to another user.
#
# Git refuses to operate on a repository owned by someone else
# ("detected dubious ownership"), which is why the root path runs git
# as the owning user rather than directly. A non-root caller cannot
# use sudo here either, so it waives that check for this one command
# with `-c safe.directory=<dir>`; the repository still has to be
# readable, again via the app's group.
git_in_repo() {
  local user="$1" dir="$2"
  shift 2
  if [ "$(id -u)" -eq 0 ]; then
    sudo -n -u "$user" git -C "$dir" "$@" 2>/dev/null
  else
    git -c safe.directory="$dir" -C "$dir" "$@" 2>/dev/null
  fi
}

# controlled abort on Ctrl-C
trap_ctrlC() {
  echo -e "\r"
  printf "%0.s " {1..80}
  printf "\n"
  exit
}

trap trap_ctrlC SIGINT SIGTERM

# print usage information for script
usage() {
  echo "RaspiBolt Welcome: system status overview
usage: $(basename "$0") [--help] [--mock]

This script can be run on startup: make it executable and
copy the script to /etc/update-motd.d/
"
}

# check script arguments
mockmode=0
if [[ ${#} -gt 0 ]]; then
  if [[ "${1}" == "-m" ]] || [[ "${1}" == "--mock" ]]; then
    mockmode=1
  else
    usage
    exit 0
  fi
fi


# Print first welcome message
# ------------------------------------------------------------------------------
printf "
${color_yellow}RaspiBolt %s:${color_grey} Sovereign \033[1m"₿"\033[22mitcoin full node
${color_yellow}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
" "3"

# Gather system data
# ------------------------------------------------------------------------------
printf "%0.s#" {1..40}
echo -ne '\r### Loading System data \r'

# get uptime & load
load=$(w|head -1|sed -E 's/.*load average: (.*)/\1/')
uptime=$(w|head -1|sed -E 's/.*up (.*),.*user.*/\1/'|sed -E 's/([0-9]* days).*/\1/')

# get highest reported temperature
temp="N/A"
color_temp="${color_grey}"
hitemp=$(grep . /sys/class/hwmon/*/* /sys/class/thermal/*/* 2>/dev/null | grep "temp" | grep "input" | awk '{split($0,a,":"); print a[2]}' | sort -r | head -n 1)
if (( hitemp > 0 )); then
  temp=$((hitemp/1000))
  if [ ${temp} -gt 68 ]; then
    color_temp="${color_red}\e[7m"
  elif [ ${temp} -gt 55 ]; then
    color_temp="${color_yellow}"
  else
    color_temp="${color_green}"
  fi
  temp="${temp}""°C"
fi

# get memory
ram_avail=$(free --mebi | grep Mem | awk '{ print $7 }')

if [ "${ram_avail}" -lt 100 ]; then
  color_ram="${color_red}\e[7m"
else
  color_ram=${color_green}
fi

# get storage
storage_free_ratio=$(printf "%.0f" "$(df | grep "/$" | awk '{ print $4/$2*100 }')") 2>/dev/null
storage=$(printf "%s" "$(df -h|grep '/$'|awk '{print $4}')") 2>/dev/null

if [ "${storage_free_ratio}" -lt 10 ]; then
  color_storage="${color_red}\e[7m"
else
  color_storage=${color_green}
fi

# Convert to GB as a number
size="${ext_storage2nd^^}"   # uppercase for unit consistency (G, M, T)
num=$(echo "$size" | grep -o '[0-9.]\+')  # extract numeric part
unit=$(echo "$size" | grep -o '[A-Z]\+')  # extract unit

# Convert to GB
case "$unit" in
  T) storage2nd_gb=$(echo "$num * 1024" | bc | cut -d'.' -f1) ;;
  G) storage2nd_gb=$(echo "$num" | cut -d'.' -f1) ;;
  M) storage2nd_gb=$(echo "$num / 1024" | bc | cut -d'.' -f1) ;;
  K) storage2nd_gb=$(echo "$num / 1024 / 1024" | bc | cut -d'.' -f1) ;;
  *) storage2nd_gb=0 ;;
esac

# Set display string
storage2nd="${ext_storage2nd} free"

# Determine color
if [ "$storage2nd_gb" -lt 20 ]; then
  color_storage2nd=${color_red}
elif [ "$storage2nd_gb" -lt 50 ]; then
  color_storage2nd=${color_yellow}
else
  color_storage2nd=${color_green}
fi

# get network traffic (sums from all devices but excludes the loopback named 'lo')
network_rx=$(ip -j -s link show | jq '.[] | [(select(.ifname!="lo") | .stats64.rx.bytes)//0] | add' | awk -v OFMT='%.0f' '{sum+=$0} END{print sum}' | numfmt --to=iec)
network_tx=$(ip -j -s link show | jq '.[] | [(select(.ifname!="lo") | .stats64.tx.bytes)//0] | add' | awk -v OFMT='%.0f' '{sum+=$0} END{print sum}' | numfmt --to=iec)

# Gather application versions
# ------------------------------------------------------------------------------
gitstatusfile="${HOME}/.raspibolt.versions.json"

save_raspibolt_versions() {
  # write to json file
  cat >${gitstatusfile} <<EOF
{
  "githubversions": {
    "bitcoin": "${btcgit}",
    "lnd": "${lndgit}",
    "cln": "${clngit}",
    "electrs": "${electrsgit}",
    "blockexplorer": "${btcrpcexplorergit}",
    "rtl": "${rtlgit}",
    "fulcrum": "${fulcrumgit}",
    "thunderhub": "${thunderhubgit}",
    "mempool": "${mempoolgit}",
    "bos": "${bosgit}",
    "circuitbreaker": "${circuitbreakergit}"
  }
}
EOF
}

load_raspibolt_versions() {
  btcgit=$(cat ${gitstatusfile} | jq -r '.githubversions.bitcoin')
  lndgit=$(cat ${gitstatusfile} | jq -r '.githubversions.lnd')
  clngit=$(cat ${gitstatusfile} | jq -r '.githubversions.cln')
  electrsgit=$(cat ${gitstatusfile} | jq -r '.githubversions.electrs')
  btcrpcexplorergit=$(cat ${gitstatusfile} | jq -r '.githubversions.blockexplorer')
  rtlgit=$(cat ${gitstatusfile} | jq -r '.githubversions.rtl')
  fulcrumgit=$(cat ${gitstatusfile} | jq -r '.githubversions.fulcrum')
  thunderhubgit=$(cat ${gitstatusfile} | jq -r '.githubversions.thunderhub')
  mempoolgit=$(cat ${gitstatusfile} | jq -r '.githubversions.mempool')
  bosgit=$(cat ${gitstatusfile} | jq -r '.githubversions.bos')
  circuitbreakergit=$(cat ${gitstatusfile} | jq -r '.githubversions.circuitbreaker')
}

fetch_githubversion_bitcoin() {
  btcgit=$(curl -s --connect-timeout 5 https://api.github.com/repos/bitcoin/bitcoin/releases/latest | jq -r '.tag_name | select(.!=null)')
}
fetch_githubversion_lightning() {
  ln_git_version=$(curl -s --connect-timeout 5 $ln_git_repo_url | jq -r '.tag_name | select(.!=null)')
}
fetch_githubversion_electrs() {
  # electrs has no GitHub Releases (only tags), so /releases/latest
  # comes back empty/stale; list tags via git ls-remote (not
  # rate-limited like the REST API) and pick the highest vX.Y.Z tag
  # instead, same as raspibolt-updater-check.sh does.
  electrsgit=$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote --tags --refs "https://github.com/romanz/electrs.git" 2>/dev/null | awk '{sub("^refs/tags/", "", $2); print $2}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
}
fetch_githubversion_btcrpcexplorer() {
  btcrpcexplorergit=$(curl -s --connect-timeout 5 https://api.github.com/repos/janoside/btc-rpc-explorer/releases/latest | jq -r '.tag_name | select(.!=null)')
}
fetch_githubversion_rtl() {
  rtlgit=$(curl -s --connect-timeout 5 https://api.github.com/repos/Ride-The-Lightning/RTL/releases/latest | jq -r '.tag_name | select(.!=null)')
}
fetch_githubversion_fulcrum() {
  fulcrumgit=$(curl -s --connect-timeout 5 https://api.github.com/repos/cculianu/Fulcrum/releases/latest | jq -r '.tag_name | select(.!=null)')
}
fetch_githubversion_thunderhub() {
  thunderhubgit=$(curl -s --connect-timeout 5 https://api.github.com/repos/apotdevin/thunderhub/releases/latest | jq -r '.tag_name | select(.!=null)')
}
fetch_githubversion_lnd() {
  lndgit=$(curl -s --connect-timeout 5 https://api.github.com/repos/lightningnetwork/lnd/releases/latest | jq -r '.tag_name | select(.!=null)')
}
fetch_githubversion_cln() {
  clngit=$(curl -s --connect-timeout 5 https://api.github.com/repos/ElementsProject/lightning/releases/latest | jq -r '.tag_name | select(.!=null)')
}
fetch_githubversion_mempool() {
  mempoolgit=$(curl -s --connect-timeout 5 https://api.github.com/repos/mempool/mempool/releases/latest | jq -r '.tag_name | select(.!=null)')
}
fetch_githubversion_bos() {
  # balanceofsatoshis has no GitHub Releases (only tags), so
  # /releases/latest always comes back empty for it; use the tags
  # via git ls-remote (not rate-limited like the REST API) and pick
  # the highest vX.Y.Z tag instead, same as raspibolt-updater-check.sh does.
  bosgit=$(GIT_TERMINAL_PROMPT=0 timeout 10 git ls-remote --tags --refs "https://github.com/alexbosworth/balanceofsatoshis.git" 2>/dev/null | awk '{sub("^refs/tags/", "", $2); print $2}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
}
fetch_githubversion_circuitbreaker() {
  # Circuit Breaker has no tagged releases upstream; it tracks the master
  # branch, so use the short commit hash of the latest master commit instead.
  circuitbreakergit=$(curl -s --connect-timeout 5 https://api.github.com/repos/lightningequipment/circuitbreaker/commits/master | jq -r '.sha[0:7] | select(.!=null)')
}


# Check if we should update with latest versions from github (limit to once every 6 hours)
gitupdate="0"
if [ ! -f "$gitstatusfile" ]; then
  gitupdate="1"
else
  gitupdate=$(find "${gitstatusfile}" -mmin +360 | wc -l)
fi

# Fetch or load
if [ "${gitupdate}" -eq "1" ]; then
  # Calls to github
  fetch_githubversion_bitcoin
  fetch_githubversion_lnd
  fetch_githubversion_cln
  fetch_githubversion_electrs
  fetch_githubversion_btcrpcexplorer
  fetch_githubversion_rtl
  fetch_githubversion_fulcrum
  fetch_githubversion_thunderhub
  fetch_githubversion_mempool
  fetch_githubversion_bos
  fetch_githubversion_circuitbreaker
  # write to json file
  save_raspibolt_versions
else
  # load from file
  load_raspibolt_versions
fi

# Sanity check values
#
# `jq -r` prints the literal text "null" (not empty) for a key that
# doesn't exist in the cache file -- which happens for every key added
# to save_raspibolt_versions() after $gitstatusfile was first written.
# A plain `-z` check would miss that and keep the bogus "null" value
# until the 6-hour cache fully expires, so treat "null" as missing too.
is_missing_version() {
  [ -z "$1" ] || [ "$1" = "null" ]
}

resaveraspibolt="0"
if is_missing_version "$btcgit"; then
  fetch_githubversion_bitcoin
  resaveraspibolt="1"
fi
if is_missing_version "$lndgit"; then
  fetch_githubversion_lnd
  resaveraspibolt="1"
fi
if is_missing_version "$clngit"; then
  fetch_githubversion_cln
  resaveraspibolt="1"
fi
if is_missing_version "$electrsgit"; then
  fetch_githubversion_electrs
  resaveraspibolt="1"
fi
if is_missing_version "$btcrpcexplorergit"; then
  fetch_githubversion_btcrpcexplorer
  resaveraspibolt="1"
fi
if is_missing_version "$rtlgit"; then
  fetch_githubversion_rtl
  resaveraspibolt="1"
fi
if is_missing_version "$fulcrumgit"; then
  fetch_githubversion_fulcrum
  resaveraspibolt="1"
fi
if is_missing_version "$thunderhubgit"; then
  fetch_githubversion_thunderhub
  resaveraspibolt="1"
fi
if is_missing_version "$mempoolgit"; then
  fetch_githubversion_mempool
  resaveraspibolt="1"
fi
if is_missing_version "$bosgit"; then
  fetch_githubversion_bos
  resaveraspibolt="1"
fi
if is_missing_version "$circuitbreakergit"; then
  fetch_githubversion_circuitbreaker
  resaveraspibolt="1"
fi
if [ "${resaveraspibolt}" -eq "1" ]; then
  save_raspibolt_versions
fi



# Gather Bitcoin Core data
# ------------------------------------------------------------------------------
printf "%0.s#" {1..50}
echo -ne '\r### Loading Bitcoin Core data \r'

bitcoind_running=$(systemctl is-active ${sn_bitcoin} 2>&1)
bitcoind_color="${color_green}"
if [ -z "${bitcoind_running##*inactive*}" ]; then
  bitcoind_running="down"
  bitcoind_color="${color_red}\e[7m"
else
  bitcoind_running="up"
fi
btc_path=$(command -v bitcoin-cli)
if [ -n "${btc_path}" ]; then

  # Reduce number of calls to bitcoin by doing once and caching
  bitcoincli_getblockchaininfo=$(bitcoin-cli -datadir=${bitcoin_dir} getblockchaininfo 2>&1)
  bitcoincli_getmempoolinfo=$(bitcoin-cli -datadir=${bitcoin_dir} getmempoolinfo 2>&1)
  bitcoincli_getnetworkinfo=$(bitcoin-cli -datadir=${bitcoin_dir} getnetworkinfo 2>&1)
  bitcoincli_getpeerinfo=$(bitcoin-cli -datadir=${bitcoin_dir} getpeerinfo 2>&1)

  chain="$(echo ${bitcoincli_getblockchaininfo} | jq -r '.chain')"
  btc_title="itcoin"
  btc_title="${btc_title} (${chain}net)"

  # create variable btcversion
  btcpi=$(bitcoin-cli -version |sed -n 's/^.*version //p')
  case "${btcpi}" in
    *"${btcgit}"*)
      btcversion="$btcpi"
      btcversion_color="${color_green}"
      ;;
    *)
      btcversion="${btcpi} > ${btcgit}"
      btcversion_color="${color_red}"
      ;;
  esac

  # get sync status
  block_chain="$(echo ${bitcoincli_getblockchaininfo} | jq -r '.headers')"
  block_verified="$(echo ${bitcoincli_getblockchaininfo} | jq -r '.blocks')"
  if [ -n "${block_chain}" ]; then
    block_diff=$(("${block_chain}" - "${block_verified}"))
  else
    block_diff=999999
  fi

  progress="$(echo ${bitcoincli_getblockchaininfo} | jq -r '.verificationprogress')"
  sync_percentage=$(printf "%.2f%%" "$(echo "${progress}" | awk '{print 100 * $1}')")

  if [ "${block_diff}" -eq 0 ]; then      # fully synced
    sync="OK"
    sync_color="${color_green}"
    sync_behind="[#$(fmt_num "${block_chain}")]"
  elif [ "${block_diff}" -eq 1 ]; then    # fully synced
    sync="OK"
    sync_color="${color_green}"
    sync_behind="-1 block"
  elif [ "${block_diff}" -le 10 ]; then   # <= 10 blocks behind
    sync="Behind"
    sync_color="${color_red}"
    sync_behind="-${block_diff} blocks"
  else
    sync="In progress"
    sync_color="${color_red}"
    sync_behind="${sync_percentage}"
  fi

  # get mem pool transactions
  mempool=$(echo ${bitcoincli_getmempoolinfo} | jq -r '.size')

  # Fee to get into the next block. estimatesmartfee answers in
  # BTC/kvB, and 1 BTC/kvB is 100000 sat/vB. Target 1 is the "fast"
  # tier; Core answers with an "errors" array and no feerate at all
  # when it has too little data for that target (shortly after a
  # restart, say), hence the fallback rather than a bare jq value.
  # The result is written with a decimal comma, to go with the "."
  # thousands separator fmt_num uses elsewhere in the banner.
  bitcoincli_estimatesmartfee=$(bitcoin-cli -datadir=${bitcoin_dir} estimatesmartfee 1 2>&1)
  fastfee_btc=$(echo ${bitcoincli_estimatesmartfee} | jq -r '.feerate // empty' 2>/dev/null)
  if [ -n "${fastfee_btc}" ]; then
    fastfee="$(awk -v f="${fastfee_btc}" 'BEGIN { printf "%.1f", f * 100000 }' | tr '.' ',') sat/vB"
  else
    fastfee="n/a"
  fi

  # get connection info
  connections=$(echo ${bitcoincli_getnetworkinfo} | jq -r '.connections')
  inbound=$(echo ${bitcoincli_getpeerinfo} | jq '.[] | select(.inbound == true)' | jq -s 'length')
  outbound=$(echo ${bitcoincli_getpeerinfo} | jq '.[] | select(.inbound == false)' | jq -s 'length')

  # create variable btcversion
  btcpi=$(bitcoin-cli -version |sed -n 's/^.*version //p')
  case "${btcpi}" in
    *"${btcgit}"*)
      btcversion="$btcpi"
      btcversion_color="${color_green}"
      ;;
    *)
      btcversion="${btcpi} > ${btcgit}"
      btcversion_color="${color_red}"
      ;;
  esac
else
  # bitcoin-cli was not found
  btc_title="Bitcoin not active"
  btcversion="Is Bitcoin installed?"
  btcversion_color="${color_red}"
  connections="0"
  fastfee="n/a"
  inbound="0"
  mempool="0"
  outbound="0"
  sync="Not synching"
  sync_color="${color_red}"
  sync_behind=""
fi

# Gather LN data based on preferred implementation
# ------------------------------------------------------------------------------
printf "%0.s#" {1..60}

load_lightning_data() {
  lnd_infofile="${HOME}/.raspibolt.lndata.json"
  ln_file_content=$(cat $lnd_infofile)
  ln_color="$(echo $ln_file_content | jq -r '.ln_color')"
  ln_version_color="$(echo $ln_file_content | jq -r '.ln_version_color')"
  alias_color="$(echo $ln_file_content | jq -r '.alias_color')"
  ln_running="$(echo $ln_file_content | jq -r '.ln_running')"
  ln_version="$(echo $ln_file_content | jq -r '.ln_version')"
  ln_walletbalance="$(echo $ln_file_content | jq -r '.ln_walletbalance')"
  ln_channelbalance="$(echo $ln_file_content | jq -r '.ln_channelbalance')"
  ln_pendinglocal="$(echo $ln_file_content | jq -r '.ln_pendinglocal')"
  ln_sum_balance="$(echo $ln_file_content | jq -r '.ln_sum_balance')"
  ln_channels_online="$(echo $ln_file_content | jq -r '.ln_channels_online')"
  ln_channels_total="$(echo $ln_file_content | jq -r '.ln_channels_total')"
  ln_channel_db_size="$(echo $ln_file_content | jq -r '.ln_channel_db_size')"
  ln_connect_guidance="$(echo $ln_file_content | jq -r '.ln_connect_guidance')"
  ln_alias="$(echo $ln_file_content | jq -r '.ln_alias')"
  ln_sync_note1="$(echo $ln_file_content | jq -r '.ln_sync_note1')"
  ln_sync_note1_color="$(echo $ln_file_content | jq -r '.ln_sync_note1_color')"
  ln_sync_note2="$(echo $ln_file_content | jq -r '.ln_sync_note2')"
  ln_sync_note2_color="$(echo $ln_file_content | jq -r '.ln_sync_note2_color')"
}

# Prepare Lightning output data (name, version, data lines)
# ------------------------------------------------------------------------------
echo -ne '\r### Loading Lightning data \r'
lserver_found=0
lserver_label="No Lightning Server"
lserver_running=""
lserver_color="${color_red}\e[7m"
lserver_version=""
lserver_version_color="${color_red}"
# Raw figures behind the Lightning block. It's rendered as its own
# standalone block below Bitcoin Core now (see "Render output" below),
# not interleaved row-by-row with the coin art, so these are just
# plain values rather than pre-rendered fixed-width strings. Defaulted
# here so `set -u` doesn't trip when no Lightning server is found.
ln_sync_note1=""
ln_sync_note1_color="${color_grey}"
ln_sync_note2=""
ln_sync_note2_color="${color_grey}"
ln_walletbalance=""
ln_channelbalance=""
ln_inboundbalance=""
ln_pendinglocal=""
ln_sum_balance=""
ln_channels_online=""
ln_channels_total=""
ln_channel_db_size=""
ln_dbsize_label="Channel.db size:"

ln_footer=""
lnd_status=$(systemctl is-enabled $sn_lnd 2>&1)
cln_status=$(systemctl is-enabled $sn_cln 2>&1)
if [ "$cln_status" != "enabled" ]; then # fallback from lightningd to cln for service name
  sn_cln="cln"
  cln_status=$(systemctl is-enabled $sn_cln 2>&1)
fi
# Mock specific
if [ "${mockmode}" -eq 1 ]; then
  ln_alias="MyRaspiBolt-version3"
  ln_walletbalance="100000"
  ln_channelbalance="200000"
  ln_inboundbalance="150000"
  ln_pendinglocal="50000"
  ln_sum_balance="350000"
  ln_channels_online="34"
  ln_channels_total="36"
  ln_channel_db_size="615M"
  ln_connect_guidance="lncli connect cdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd@version3onionaddressgobbLedegookLookingL3ttersandnumbers.onion:9735"
  lserver_label="Lightning (MOCK)"
  lserver_running="up"
  lserver_color="${color_green}"
  lserver_version="v0.6.15"
  lserver_version_color="${color_green}"
  alias_color="${color_magenta}"
  ln_footer=$(printf "For others to connect to this lightning node: ${alias_color}${ln_alias}${color_grey}\n${ln_connect_guidance}")
  ln_sync_note1="ready"
  ln_sync_note1_color="${color_grey}"
# LND specific
elif [ "$lnd_status" = "enabled" ]; then
  lnd_status=$(systemctl is-active $sn_lnd 2>&1)
  lserver_found=1
  lserver_label="Lightning (LND)"
  lserver_running="down"
  if [ "$lnd_status" = "active" ]; then
    lserver_running="up"
    lserver_color="${color_green}"
    # version specific stuff
    "$(dirname "$0")/get_LND_data.sh" $chain $color_green $color_red $lndgit
    load_lightning_data
    # Inbound liquidity: the remote side of the open channels, which
    # is what caps what this node can receive. get_LND_data.sh does
    # not report it, so ask lnd directly -- but which lncli
    # invocation works depends on where LND keeps its data and on who
    # is running the banner. On a RaspiBolt box LND lives in
    # /data/lnd owned by the lnd user: the admin account reaches it
    # through a ~/.lnd symlink, while root has no ~/.lnd of its own
    # and a bare lncli cannot find the macaroon (it fails quietly,
    # leaving the row reading 0 sat). So try the plain call first,
    # then the usual data directories, and stop at the first one that
    # answers.
    ln_channelbalance_json=""
    if command -v lncli >/dev/null 2>&1; then
      for lnd_dir_candidate in "" "${HOME}/.lnd" "/data/lnd" "/home/lnd/.lnd" "/mnt/ext/lnd"; do
        if [ -z "${lnd_dir_candidate}" ]; then
          ln_channelbalance_json=$(lncli channelbalance 2>/dev/null)
        elif [ -d "${lnd_dir_candidate}" ]; then
          ln_channelbalance_json=$(lncli --lnddir="${lnd_dir_candidate}" channelbalance 2>/dev/null)
        fi
        if [ -n "${ln_channelbalance_json}" ]; then
          break
        fi
      done
    fi
    # Recent LND reports remote_balance as an {sat,msat} object,
    # older ones as a bare number.
    ln_inboundbalance=$(echo "${ln_channelbalance_json}" | jq -r 'if (.remote_balance | type) == "object" then .remote_balance.sat else .remote_balance end // empty' 2>/dev/null)
    lserver_version="$(echo $ln_file_content | jq -r '.ln_version')"
    lserver_version_color="$(echo $ln_file_content | jq -r '.ln_version_color')"
    # get_LND_data.sh already compared against $lndgit and picked the
    # color accordingly; reuse that instead of re-deriving it here.
    if [ "$lserver_version_color" = "$color_red" ]; then
      # get_LND_data.sh already appends " Update!" to an outdated
      # version itself; strip that before adding our own "> latest".
      lserver_version="${lserver_version% Update!} > ${lndgit}"
    fi
    ln_footer=$(printf "For others to connect to this lightning node: ${alias_color}${ln_alias}${color_grey}\n${ln_connect_guidance}")
  fi
# Core Lightning specific
elif [ "$cln_status" = "enabled" ];  then
  cln_status=$(systemctl is-active $sn_cln 2>&1)
  lserver_found=1
  lserver_label="Lightning (CLN)"
  lserver_running="down"
  if [ "$cln_status" = "active" ]; then
    lserver_running="up"
    lserver_color="${color_green}"
    # version specific stuff
    "$(dirname "$0")/get_CLN_data.sh" $chain $color_green $color_red $clngit
    load_lightning_data
    lserver_version="$(echo $ln_file_content | jq -r '.ln_version')"
    lserver_version_color="$(echo $ln_file_content | jq -r '.ln_version_color')"
    # get_CLN_data.sh already compared against $clngit and picked the
    # color accordingly; reuse that instead of re-deriving it here.
    if [ "$lserver_version_color" = "$color_red" ]; then
      # get_CLN_data.sh already appends " Update!" to an outdated
      # version itself; strip that before adding our own "> latest".
      lserver_version="${lserver_version% Update!} > ${clngit}"
    fi
    ln_footer=$(printf "For others to connect to this lightning node: ${alias_color}${ln_alias}${color_grey}\n${ln_connect_guidance}")
    # CLN has no separate "pending local" figure the way LND does, and
    # its DB is labeled differently.
    ln_pendinglocal=""
    ln_dbsize_label="Lightning DB size:"
  fi
# ... add any future supported lightning server implementation checks here
fi
if [ "$lserver_found" -eq 0 ]; then
  lserver_color="${color_grey}"
fi



# Gather Electrs or Fulcrum data
# ------------------------------------------------------------------------------
printf "%0.s#" {1..65}
echo -ne '\r### Loading Electrum Server data \r'
eserver_found=0
eserver_label="No Electrum Server"
eserver_running=""
eserver_color="${color_red}\e[7m"
eserver_version=""
eserver_version_color="${color_red}"
electrs_status=$(systemctl is-enabled ${sn_electrs} 2>&1)
fulcrum_status=$(systemctl is-enabled ${sn_fulcrum} 2>&1)
# Electrs specific
if [ "$electrs_status" = "enabled" ]; then
  electrs_status=$(systemctl is-active ${sn_electrs} 2>&1)
  eserver_found=1
  eserver_label="Electrs"
  eserver_running="down"
  if [ "$electrs_status" = "active" ]; then
    eserver_running="up"
    eserver_color="${color_green}"
    # Request params are client_name, protocol_version. Example result being parsed: ["Electrs 0.9.10", "1.4"]
    electrspi=$(echo '{"jsonrpc": "2.0", "method": "server.version", "params": [ "raspibolt", "1.4" ], "id": 0}' | netcat 127.0.0.1 50001 -q 1 | jq -r '.result[0]' | awk '{print "v"substr($1,9)}')
    if [ "$electrspi" = "$electrsgit" ]; then
      eserver_version="$electrspi"
      eserver_version_color="${color_green}"
    else
      eserver_version="${electrspi} > ${electrsgit}"
    fi
  fi
# Fulcrum specific
elif [ "$fulcrum_status" = "enabled" ];  then
  fulcrum_status=$(systemctl is-active ${sn_fulcrum} 2>&1)
  eserver_found=1
  eserver_label="Fulcrum"
  eserver_running="down"
  if [ "$fulcrum_status" = "active" ]; then
    eserver_running="up"
    eserver_color="${color_green}"
    fulcrumpi=$(Fulcrum --version | grep Fulcrum | awk '{print "v"$2}')
    if [ "$fulcrumpi" = "$fulcrumgit" ]; then
      eserver_version="$fulcrumpi"
      eserver_version_color="${color_green}"
    else
      eserver_version="${fulcrumpi} > ${fulcrumgit}"
    fi
  fi
# ... add any future supported electrum server implementation checks here
fi
if [ "$eserver_found" -eq 0 ]; then
  eserver_color="${color_grey}"
fi



# Gather Bitcoin Explorer data
# ------------------------------------------------------------------------------
printf "%0.s#" {1..70}
echo -ne '\r### Loading Block Explorer data \r'
bserver_found=0
bserver_label="No Block Explorer"
bserver_running=""
bserver_color="${color_red}\e[7m"
bserver_version=""
bserver_version_color="${color_red}"
btcrpcexplorer_status=$(systemctl is-enabled ${sn_btcrpcexplorer} 2>&1)
# BTC RPC Explorer specific
if [ "$btcrpcexplorer_status" = "enabled" ]; then
  un_btcrpcexplorer=$(systemctl show -pUser ${sn_btcrpcexplorer} | awk '{split($0,a,"="); print a[2]}')
  btcrpcexplorer_status=$(systemctl is-active ${sn_btcrpcexplorer} 2>&1)
  bserver_found=1
  bserver_label="Bitcoin Explorer"
  bserver_running="down"
  if [ "$btcrpcexplorer_status" = "active" ]; then
    bserver_running="up"
    bserver_color="${color_green}"
    btcrpcexplorerpi=v$(cd /home/${un_btcrpcexplorer}/btc-rpc-explorer; npm version | grep -oP "'btc-rpc-explorer': '\K(.*)(?=')")
    if [ "$btcrpcexplorerpi" = "$btcrpcexplorergit" ]; then
      bserver_version="$btcrpcexplorerpi"
      bserver_version_color="${color_green}"
    else
      bserver_version="${btcrpcexplorerpi} > ${btcrpcexplorergit}"
    fi
  fi
# ... add any future supported blockchain explorer implementation checks here
fi
if [ "$bserver_found" -eq 0 ]; then
  bserver_color="${color_grey}"
fi



# Gather Lightning Web App data
# ------------------------------------------------------------------------------
printf "%0.s#" {1..75}
echo -ne '\r### Loading Lightning Web App \r'

lwserver_found=0
lwserver_label="No Lightning Web App"
lwserver_running=""
lwserver_color="${color_red}\e[7m"
lwserver_version=""
lwserver_version_color="${color_red}"
rtl_status=$(systemctl is-enabled ${sn_rtl} 2>&1)
if [ "$rtl_status" != "enabled" ]; then  # fallback from rtl to ridethelightning for service name
  sn_rtl="ridethelightning"
  rtl_status=$(systemctl is-enabled ${sn_rtl} 2>&1)
fi
thunderhub_status=$(systemctl is-enabled ${sn_thunderhub} 2>&1)
# Ride the Ligthning specific
if [ "$rtl_status" = "enabled" ]; then
  un_rtl=$(systemctl show -pUser ${sn_rtl} | awk '{split($0,a,"="); print a[2]}')
  rtl_status=$(systemctl is-active ${sn_rtl} 2>&1)
  lwserver_found=1
  lwserver_label="Ride the Lightning"
  lwserver_running="down"
  if [ "$rtl_status" = "active" ]; then
    lwserver_running="up"
    lwserver_color="${color_green}"
    rtlpi=v$(cd /home/${un_rtl}/RTL; npm version | grep -oP "rtl: '\K(.*)(?=-beta')")
    if [ "$rtlpi" = "$rtlgit" ]; then
      lwserver_version="$rtlpi"
      lwserver_version_color="${color_green}"
    else
      lwserver_version="${rtlpi} > ${rtlgit}"
    fi
  fi
# Thunderhub specific
elif [ "$thunderhub_status" = "enabled" ]; then
  un_thunderhub=$(systemctl show -pUser ${sn_thunderhub} | awk '{split($0,a,"="); print a[2]}')
  thunderhub_status=$(systemctl is-active ${sn_thunderhub} 2>&1)
  lwserver_found=1
  lwserver_label="Thunderhub"
  lwserver_running="down"
  if [ "$thunderhub_status" = "active" ]; then
    lwserver_running="up"
    lwserver_color="${color_green}"
    thunderhubpi=v$(cd /home/${un_thunderhub}/thunderhub; npm version | grep -oP "thunderhub: '\K(.*)(?=-beta')")
    if [ "$thunderhubpi" = "$thunderhubgit" ]; then
      lwserver_version="$thunderhubpi"
      lwserver_version_color="${color_green}"
    else
      lwserver_version="${thunderhubpi} > ${thunderhubgit}"
    fi
  fi
# ... add any future supported lightning web app implementation checks here
fi
if [ "$lwserver_found" -eq 0 ]; then
  lwserver_color="${color_grey}"
fi


# Gather Mempool data
# ------------------------------------------------------------------------------
printf "%0.s#" {1..78}
echo -ne '\r### Loading Mempool data \r'
mempool_found=0
mempool_label="No Mempool"
mempool_running=""
mempool_color="${color_grey}"
mempool_version=""
mempool_version_color="${color_red}"
mempool_status=$(systemctl is-enabled ${sn_mempool} 2>&1)
if [ "$mempool_status" = "enabled" ]; then
  mempool_status=$(systemctl is-active ${sn_mempool} 2>&1)
  mempool_found=1
  mempool_label="Mempool"
  mempool_running="down"
  mempool_color="${color_red}\e[7m"
  if [ "$mempool_status" = "active" ]; then
    mempool_running="up"
    mempool_color="${color_green}"
    mempoolpi=$(git_in_repo mempool /home/mempool/mempool describe --tags --always)
    if [ "$mempoolpi" = "$mempoolgit" ]; then
      mempool_version="$mempoolpi"
      mempool_version_color="${color_green}"
    else
      mempool_version="${mempoolpi} > ${mempoolgit}"
    fi
  fi
fi

# Gather Balance of Satoshis data
# ------------------------------------------------------------------------------
printf "%0.s#" {1..80}
echo -ne '\r### Loading Balance of Satoshis data \r'
bos_found=0
bos_label="No Balance of Satoshis"
bos_running=""
bos_color="${color_grey}"
bos_version=""
bos_version_color="${color_red}"
# Run as the bos user via `bos -V` directly (confirmed working:
# `bos -V` => "23.1.6", no "v" prefix) rather than a plain -d test
# plus `npm version` parsing as root, which sidesteps any
# permission/ownership mismatch between root and the bos-owned
# install directory. Resolve the actual binary path instead of
# relying on `bash -lc` to assemble bos's PATH: Debian's default
# ~/.bashrc returns immediately for non-interactive shells (`[ -z
# "$PS1" ] && return`), so PATH additions living there (where
# npm-local installs are commonly exposed) never take effect for a
# `bash -lc "..."` call, even though it's technically a login shell.
bos_bin=""
for bos_candidate in \
  "/usr/local/bin/bos" \
  "/home/bos/balanceofsatoshis/bos" \
  "/home/bos/balanceofsatoshis/node_modules/.bin/bos" \
  "/home/bos/.balanceofsatoshis/node_modules/.bin/bos"
do
  if [ -x "$bos_candidate" ]; then
    bos_bin="$bos_candidate"
    break
  fi
done

if [ -z "$bos_bin" ]; then
  # None of the guessed locations matched (e.g. nvm-managed node,
  # a differently-named clone directory): search for it instead of
  # guessing further.
  bos_bin=$(find /home/bos -maxdepth 6 -type f -name bos -perm -u+x 2>/dev/null | head -n1)
fi

if [ -n "$bos_bin" ]; then
  bospi=$(run_as_app_user bos "$bos_bin" -V)
elif [ "$(id -u)" -eq 0 ]; then
  # Last resort: a full simulated login (`sudo -i`, not `bash -lc`)
  # so ~bos's own profile/rc chain runs the way it would on a real
  # interactive login, in case `bos` only resolves via PATH there
  # (e.g. an nvm PATH export).
  bospi=$(sudo -n -i -u bos bos -V 2>/dev/null)
else
  # Same idea without sudo: whatever `bos` the caller's own PATH
  # resolves to, if any.
  bospi=$(bos -V 2>/dev/null)
fi
if [ -n "$bospi" ]; then
  bospi="v${bospi}"
  bos_found=1
  bos_label="Balance of Satoshis"
  if [ "$bospi" = "$bosgit" ]; then
    bos_version="$bospi"
    bos_version_color="${color_green}"
  else
    bos_version="${bospi} > ${bosgit}"
  fi
  # bos itself is a CLI tool, not a persistent service; report the
  # optional Telegram bot service status if configured, else "cli"
  bostelegram_status=$(systemctl is-enabled ${sn_bostelegram} 2>&1)
  if [ "$bostelegram_status" = "enabled" ]; then
    bostelegram_status=$(systemctl is-active ${sn_bostelegram} 2>&1)
    if [ "$bostelegram_status" = "active" ]; then
      bos_running="up"
      bos_color="${color_green}"
    else
      bos_running="down"
      bos_color="${color_red}\e[7m"
    fi
  else
    bos_running="cli"
    bos_color="${color_grey}"
  fi
fi

# Gather Circuit Breaker data
# ------------------------------------------------------------------------------
printf "%0.s#" {1..82}
echo -ne '\r### Loading Circuit Breaker data \r'
circuitbreaker_found=0
circuitbreaker_label="No Circuit Breaker"
circuitbreaker_running=""
circuitbreaker_color="${color_grey}"
circuitbreaker_version=""
circuitbreaker_version_color="${color_red}"
circuitbreaker_status=$(systemctl is-enabled ${sn_circuitbreaker} 2>&1)
if [ "$circuitbreaker_status" = "enabled" ]; then
  circuitbreaker_status=$(systemctl is-active ${sn_circuitbreaker} 2>&1)
  circuitbreaker_found=1
  circuitbreaker_label="Circuit Breaker"
  circuitbreaker_running="down"
  circuitbreaker_color="${color_red}\e[7m"
  if [ "$circuitbreaker_status" = "active" ]; then
    circuitbreaker_running="up"
    circuitbreaker_color="${color_green}"
    # Circuit Breaker tracks master and has no tagged releases, so
    # compare by short commit hash instead of by version string.
    circuitbreakerpi=$(git_in_repo circuitbreaker /home/circuitbreaker/circuitbreaker rev-parse --short HEAD)
    if [ "$circuitbreakerpi" = "$circuitbreakergit" ]; then
      circuitbreaker_version="$circuitbreakerpi"
      circuitbreaker_version_color="${color_green}"
    else
      circuitbreaker_version="${circuitbreakerpi} > ${circuitbreakergit}"
    fi
  fi
fi


# Render output
# ------------------------------------------------------------------------------

# Fixed-width space fillers, so the left column (Bitcoin Core art,
# then the Lightning block below it) always totals the same visible
# width (49 columns) before the right column (Electrs, Mempool,
# Bitcoin Explorer, then RTL, BoS, Circuit Breaker) begins. Computed
# rather than hand-typed, since miscounting literal spaces is exactly
# what caused the alignment issues earlier in this file's history.
#
# fill3 tops up the label rows (22 + %-20s + %-4s = 46), fill5 the
# balance rows (22 + icon + space + %16s + " sat" = 44).
fill3="$(printf '%*s' 3 '')"
fill5="$(printf '%*s' 5 '')"

# Balance-row icons. Each one MUST be a glyph the terminal draws in a
# single cell, and each is emitted as a literal rather than passed as
# a printf argument, because bash's printf cannot line these up on
# its own: it pads %Ns by BYTE count, and every one of these is a
# 3-byte UTF-8 character, so %2s and %3s pad them identically -- that
# is, not at all (confirmed: `printf '[%3s]' '₿'` prints "[₿]", not
# "[  ₿]"). Whatever the glyph's own display width turns out to be is
# therefore what the rest of the row is offset by.
#
# That is why ⚡ (U+26A1) and ⏳ (U+23F3) are not used here: both
# default to emoji presentation, which terminals draw two cells wide,
# so those two rows sat one column right of the ₿ and ∑ rows.
#
# Single-cell alternatives, should a glyph be missing from your
# terminal font (a tofu box) or render double-width anyway:
#   on-chain  ₿ (U+20BF)   B
#   channels  ϟ (U+03DF)   ↯ (U+21AF)   Ϟ (U+03DE)
#   pending   ◷ (U+25F7)   ⧗ (U+29D7)   ◔ (U+25D4)
#   total     ∑ (U+2211)   Σ (U+03A3)
# To check one in your own terminal, print each followed by a
# marker and see whether the markers land in the same column:
#   for c in ₿ ϟ ◷ ∑; do echo "$c|"; done
icon_onchain="₿"
icon_channels="ϟ"
icon_pending="◷"
icon_total="∑"
# Direction markers for the two channel rows: outbound (what this
# node can send) and inbound (what it can receive). Both are East
# Asian Ambiguous, i.e. one cell outside a CJK locale -- the Peers
# line above has been drawing them at that width all along.
icon_outbound="↑"
icon_inbound="↓"

# Left margin for the rest of the Lightning block, once the art has
# ended: the art glyphs stop and Bitcoin's own title text begins at
# column 22, so this continues at the same column rather than
# starting flush at column 0.
indent22="$(printf '%*s' 22 '')"

# A four-part Bitcoin phrase, centered over the coin art: parts 1-2
# sit above it, parts 3-4 below, one of these picked at random on
# every login. Keep each part at 10 columns or less so it stays
# visibly centered on the art, and spell a leading B as ₿ (U+20BF)
# where it still reads as one -- it ties the phrase to the coin.
logo_phrases=(
  "₿E|YOUR|OWN|₿ANK"
  "NOT YOUR|KEYS|NOT YOUR|COINS"
  "FIX THE|MONEY|FIX THE|WORLD"
  "STAY|HUMBLE|STACK|SATS"
  "TICK|TOCK|NEXT|₿LOCK"
  "RUN|YOUR OWN|FULL|NODE"
  "21|MILLION|NO|MORE"
  "IN|CODE|WE|TRUST"
  "TRUST|NO ONE|VERIFY|EVERYTHING"
  "PROOF OF|WORK|NOT|PROMISES"
  "SELF|CUSTODY|OR|NOTHING"
  "HODL|STACK|VERIFY|REPEAT"
  "YOUR NODE|YOUR RULES|YOUR KEYS|YOUR COINS"
  "FREEDOM|MONEY|FOR|EVERYONE"
  "ONE|₿ITCOIN|IS ONE|₿ITCOIN"
)

# Display width of a string in terminal columns, deliberately not
# using a bare ${#s}: that counts bytes unless the locale happens to
# be a UTF-8 one, and ₿ is three bytes wide but one column (the same
# measuring trap the icon block above documents). Forcing LC_ALL=C
# for the duration of the function makes the count reliably a byte
# count, and dropping the UTF-8 continuation bytes (0x80-0xBF) first
# leaves exactly one count per character, in any locale.
disp_width() {
  local LC_ALL=C label="$1" stripped
  stripped="${label//[$'\x80'-$'\xbf']/}"
  printf '%s' "${#stripped}"
}

# Center a phrase part in the 22-column left block, so that it lines
# up with the plain indent22 rows and with the art.
center22() {
  local label="$1" width left right
  width="$(disp_width "$label")"
  (( width > 22 )) && width=22
  left=$(( (22 - width) / 2 ))
  right=$(( 22 - width - left ))
  printf '%*s%s%*s' "${left}" '' "${label}" "${right}" ''
}

IFS='|' read -r logo_top1 logo_top2 logo_bot1 logo_bot2 <<<"${logo_phrases[RANDOM % ${#logo_phrases[@]}]}"
logo_top1="$(center22 "${logo_top1}")"
logo_top2="$(center22 "${logo_top2}")"
logo_bot1="$(center22 "${logo_bot1}")"
logo_bot2="$(center22 "${logo_bot2}")"

echo -ne "\033[2K"

# ------------------------------------------------------------
# Left column: a blank row, the phrase's first two lines, another
# blank row, then the first five rows of the coin art (it continues
# into the next printf below). Right column, top to bottom: Bitcoin
# Core, Electrs, Mempool, Lightning and Bitcoin Explorer -- unchanged
# by the logo living beside it, since every left-hand cell here is
# exactly 22 columns wide, whether it holds a phrase line, art, or
# the plain indent22 filler.
# ------------------------------------------------------------
printf "${color_grey}cpu temp: ${color_temp}%-4s${color_grey}  tx: %-10s storage:   ${color_storage}%-11s ${color_grey}  load: %s${color_grey}
${color_grey}up: %-10s  rx: %-10s 2nd drive: ${color_storage2nd}%-11s${color_grey}   available mem: ${color_ram}%sM${color_grey}
${color_yellow}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${color_grey}
${indent22}${color_orange}"₿"${color_yellow}%-19s${bitcoind_color}%-4s${color_grey}   ${color_yellow}%-20s${eserver_color}%-4s${color_grey}
${color_yellow}${logo_top1}${btcversion_color}%-26s ${eserver_version_color}%-24s${color_grey}
${color_yellow}${logo_top2}${color_grey}Sync    ${sync_color}%-18s ${color_grey}
${indent22}${color_grey}Mempool %-18s ${color_yellow}%-20s${mempool_color}%-4s${color_grey}
${color_green}     .~~.   .~~.      ${color_grey}Peers   %-22s ${mempool_version_color}%-24s${color_grey}
${color_green}    '. \ ' ' / .'     ${color_grey}Fee     %-18s ${color_grey}
${color_red}     .~ .~~~${color_yellow}.${color_red}.~.      ${color_grey}%-27s${color_yellow}%-20s${bserver_color}%-4s${color_grey}
${color_red}    : .~.'${color_yellow}／/${color_red}~. :     ${color_yellow}%-20s${lserver_color}%-4s${color_grey}${fill3}${bserver_version_color}%-24s${color_grey}
${color_red}   ~ (  ${color_yellow}／ /_____${color_red}~    ${lserver_version_color}%-24s${color_grey}${fill3}${color_grey}
" \
"${temp}" "${network_tx}" "${storage} free" "${load}" \
"${uptime}" "${network_rx}" "${storage2nd}" "$(fmt_num "${ram_avail}")" \
"${btc_title}" "${bitcoind_running}" "${eserver_label}" "${eserver_running}" \
"${btcversion}" "${eserver_version}" \
"${sync} ${sync_behind}" \
"${mempool} tx" "${mempool_label}" "${mempool_running}" \
"${connections} (↓${inbound} / ↑${outbound})" "${mempool_version}" \
"${fastfee}" \
"" "${bserver_label}" "${bserver_running}" \
"${lserver_label}" "${lserver_running}" "${bserver_version}" \
"${lserver_version}"

# ------------------------------------------------------------
# Left column continued: the last four rows of the coin art, a blank
# row, then the phrase's last two lines, centered under the art the
# same way its first two are centered over it. Right column, top to
# bottom: the Lightning balances, Ride The Lightning, Balance of
# Satoshis and Circuit Breaker.
# ------------------------------------------------------------
printf "${color_red}  ( : ${color_yellow}／____   ／${color_red} )   ${color_grey}Sync${ln_sync_note1_color}%9s${ln_sync_note2_color}%9s${color_grey}${fill5}${color_yellow}%-20s${lwserver_color}%-4s${color_grey}
${color_red}   ~ .~ (  ${color_yellow}/ ／${color_red}. ~    ${color_orange}${icon_onchain}${color_grey}   %14s sat${fill5}${lwserver_version_color}%-24s${color_grey}
${color_red}    (  : '${color_yellow}/／${color_red}:  )     ${color_yellow}${icon_channels} ${icon_outbound}${color_grey} %14s sat${fill5}
${color_red}     '~ .~${color_yellow}°${color_red}~. ~'      ${color_grey}${icon_pending}   %14s sat${fill5}${color_yellow}%-20s${bos_color}%-4s${color_grey}
${indent22}${color_grey}${icon_total}   %14s sat${fill5}${bos_version_color}%-24s${color_grey}
${color_yellow}${logo_bot1}${color_yellow}${icon_channels} ${icon_inbound}${color_grey} %14s sat${fill5}
${color_yellow}${logo_bot2}${color_grey}%-27s${color_yellow}%-20s${circuitbreaker_color}%-4s${color_grey}
${indent22}${color_grey}%-27s${circuitbreaker_version_color}%-24s${color_grey}

${color_grey}%s

" \
"${ln_sync_note1}" "${ln_sync_note2}" "${lwserver_label}" "${lwserver_running}" \
"$(fmt_num "${ln_walletbalance}")" "${lwserver_version}" \
"$(fmt_num "${ln_channelbalance}")" \
"$(fmt_num "${ln_pendinglocal}")" "${bos_label}" "${bos_running}" \
"$(fmt_num "${ln_sum_balance}")" "${bos_version}" \
"$(fmt_num "${ln_inboundbalance}")" \
"${ln_channels_online}/${ln_channels_total} channels" "${circuitbreaker_label}" "${circuitbreaker_running}" \
"${ln_dbsize_label} ${ln_channel_db_size}" "${circuitbreaker_version}" \
"${ln_footer}"
