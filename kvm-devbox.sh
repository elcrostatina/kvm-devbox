#!/usr/bin/env bash
# kvm-devbox.sh — isolated per-client development VMs on libvirt/KVM
set -euo pipefail

# ===================== Settings =====================
PREFIX="dev-"                                   # VMs managed by this script
IMG_DIR=/var/lib/libvirt/images
BASE_DIR=$IMG_DIR/base                          # downloaded base images (never modified)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/kvm-devbox"
CONFIG="$CONFIG_DIR/config.json"
SUBNET_PREFIX="10.10"                           # networks 10.10.N.0/24
MEMORY=12288
VCPUS=4
DISK_SIZE=60G                                   # for cloud images
CLOUD_USER=dev                                  # user created in cloud images

UBUNTU_DIR=https://cloud-images.ubuntu.com/releases/resolute/release
ROCKY_URL=https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2

GFS=(sudo LIBGUESTFS_BACKEND=direct)            # libguestfs without going through libvirt

# ===================== Development tools catalog =====================
TOOL_KEYS=(node python java php dotnet docker ollama lmstudio claude kimi)
declare -A TOOL_LABEL=(
  [node]="Node.js (nvm)"              [python]="Python (uv + Poetry)"
  [java]="Java JDK (SDKMAN, Temurin)" [php]="PHP + Composer"
  [dotnet]=".NET SDK / C#"            [docker]="Docker + Docker Compose"
  [ollama]="Ollama"                   [lmstudio]="LM Studio (headless llmster)"
  [claude]="Claude Code (npm)"        [kimi]="Kimi Code"
)
declare -A TOOL_DEFAULT=([node]="24 22" [python]="3.14 3.13" [java]="25 21" [php]="8.4 8.3" [dotnet]="10.0 8.0")
declare -A TOOL_HINT=(
  [node]="e.g. 24 22 20 or lts/*" [python]="e.g. 3.14 3.13 3.12" [java]="e.g. 25 21 17 11 8"
  [php]="e.g. 8.4 8.3 8.2"        [dotnet]="e.g. 10.0 9.0 8.0"
)
declare -A SEL=()

# Commands run inside the guest disk by virt-customize
SSHD_INSTALL='if [ ! -x /usr/sbin/sshd ]; then
  if command -v apt-get >/dev/null; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server;
  else dnf install -y openssh-server && systemctl enable sshd; fi; fi'
NET_FIX='if [ -d /etc/netplan ] && ! grep -qs NetworkManager /etc/netplan/*.yaml; then
  rm -f /etc/netplan/*.yaml
  printf "network:\n  version: 2\n  ethernets:\n    all:\n      match:\n        name: e*\n      dhcp4: true\n" > /etc/netplan/01-dhcp.yaml
  chmod 600 /etc/netplan/01-dhcp.yaml
elif [ ! -d /etc/netplan ] && [ -d /etc/NetworkManager/system-connections ]; then
  printf "[connection]\nid=dhcp\ntype=ethernet\nautoconnect=true\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n" > /etc/NetworkManager/system-connections/dhcp.nmconnection
  chmod 600 /etc/NetworkManager/system-connections/dhcp.nmconnection
fi'

# ===================== Colors & glyphs =====================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'
  YEL=$'\e[33m'; BLU=$'\e[34m'; MAG=$'\e[35m'; CYN=$'\e[36m'; R=$'\e[0m'
else
  B=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; R=""
fi
if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]]; then
  BX_TL="╭"; BX_TR="╮"; BX_BL="╰"; BX_BR="╯"; BX_H="─"; BX_V="│"; BX_ML="├"; BX_MR="┤"
  ARROW="❯"; CHK="✓"; CRS="✗"; BUL="•"; RUN="●"; OFF="○"
else
  BX_TL="+"; BX_TR="+"; BX_BL="+"; BX_BR="+"; BX_H="-"; BX_V="|"; BX_ML="+"; BX_MR="+"
  ARROW=">"; CHK="+"; CRS="x"; BUL="*"; RUN="*"; OFF="o"
fi
UI_W=$(tput cols 2>/dev/null || echo 80)
[ "$UI_W" -gt 90 ] && UI_W=90
[ "$UI_W" -lt 60 ] && UI_W=60

# ===================== UI helpers =====================
rep()     { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }
vis_len() { local s; s=$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'); echo "${#s}"; }
BOX_C=$CYN
box_top() {      # title [color]
  local t=" $1 " fill
  BOX_C=${2:-$CYN}
  fill=$((UI_W - 3 - $(vis_len "$t"))); [ $fill -lt 0 ] && fill=0
  printf '%s%s%s%s%s%s%s%s%s\n' "$BOX_C" "$BX_TL" "$BX_H" "$R$B" "$t" "$R$BOX_C" "$(rep "$BX_H" $fill)" "$BX_TR" "$R"
}
box_line() {
  local s="${1:-}" pad
  pad=$((UI_W - 4 - $(vis_len "$s"))); [ $pad -lt 0 ] && pad=0
  printf '%s%s%s %s%*s %s%s%s\n' "$BOX_C" "$BX_V" "$R" "$s" "$pad" "" "$BOX_C" "$BX_V" "$R"
}
box_sep()    { printf '%s%s%s%s%s\n' "$BOX_C" "$BX_ML" "$(rep "$BX_H" $((UI_W - 2)))" "$BX_MR" "$R"; }
box_bottom() { printf '%s%s%s%s%s\n' "$BOX_C" "$BX_BL" "$(rep "$BX_H" $((UI_W - 2)))" "$BX_BR" "$R"; }
menu_item()  { box_line "$(printf "${B}${CYN}%2s${R}  %s" "$1" "$2")"; }

banner() {
  echo
  printf '%s%s' "$CYN" "$B"
  cat <<'ART'
   _                           _            _
  | | ____   ___ __ ___     __| | _____   _| |__   _____  __
  | |/ /\ \ / / '_ ` _ \   / _` |/ _ \ \ / / '_ \ / _ \ \/ /
  |   <  \ V /| | | | | | | (_| |  __/\ V /| |_) | (_) >  <
  |_|\_\  \_/ |_| |_| |_|  \__,_|\___| \_/ |_.__/ \___/_/\_\
ART
  printf '%s' "$R"
  printf '  %sIsolated per-client development VMs %s libvirt/KVM%s\n\n' "$DIM" "$BUL" "$R"
}

# ===================== Helpers =====================
die()  { echo "${RED}${B}${CRS} ERROR:${R} $*" >&2; exit 1; }
warn() { echo "${YEL}${B}! WARNING:${R} $*" >&2; }
info() { echo "${BLU}${B}${ARROW}${R} $*" >&2; }
ok()   { echo "${GRN}${B}${CHK}${R} $*" >&2; }
ask()  { local r; read -rp "${CYN}${ARROW}${R} ${B}$1${R}${2:+ ${DIM}[$2]${R}}: " r; echo "${r:-${2:-}}"; }
yes_no() { local r; read -rp "${CYN}${ARROW}${R} ${B}$1${R} ${DIM}[y/N]${R}: " r; [[ "$r" =~ ^[yY] ]]; }

state_color() {
  case "$1" in
    running)    echo "$GRN" ;;
    "shut off") echo "$DIM" ;;
    paused)     echo "$YEL" ;;
    *)          echo "$RED" ;;
  esac
}
state_icon() { [ "$1" = running ] && echo "$RUN" || echo "$OFF"; }

TMPS=(); PARTIAL=""
cleanup() {
  [ -t 1 ] && printf '\e[?25h'    # make sure the cursor is visible again
  [ -n "$PARTIAL" ] && sudo rm -f "$PARTIAL"
  [ ${#TMPS[@]} -gt 0 ] && rm -f "${TMPS[@]}"
  return 0
}
trap cleanup EXIT
newtmp() { local -n _ref=$1; _ref=$(mktemp); TMPS+=("$_ref"); }

check_deps() {
  local miss=() c
  for c in virsh virt-install qemu-img ssh scp ssh-keygen jq curl sha256sum virt-cat virt-customize guestfish; do
    command -v "$c" >/dev/null || miss+=("$c")
  done
  [ ${#miss[@]} -eq 0 ] || die "missing commands: ${miss[*]}
  sudo apt install libvirt-clients virtinst qemu-utils guestfs-tools libguestfs-tools jq curl openssh-client"
  [ -e /dev/kvm ] || warn "/dev/kvm not found, VMs will be very slow"
  sudo -v
}

# ===================== KVM queries =====================
net_n() {        # N of a 10.10.N.0/24 network, empty if not one of ours
  local ip
  ip=$(sudo virsh net-dumpxml "$1" 2>/dev/null | grep -oE "<ip address=['\"][0-9.]+" \
       | head -1 | grep -oE '[0-9.]+$') || true
  [[ "$ip" == "$SUBNET_PREFIX".*.1 ]] && echo "$ip" | cut -d. -f3 || true
}
dom_net()  { sudo virsh domiflist "$1" 2>/dev/null | awk '$2=="network"{print $3; exit}'; }
dom_nets() {
  local n
  n=$(sudo virsh domiflist "$1" 2>/dev/null | awk 'NR>2 && $3!="" {print $3}' | paste -sd, -)
  echo "${n:--}"
}
dom_disk() { sudo virsh domblklist "$1" --details 2>/dev/null | awk '$2=="disk"{print $4; exit}'; }
dom_state() { sudo virsh domstate "$1" 2>/dev/null || echo "unknown"; }
ssh_cfg_user() {
  awk -v h="$1" '$1=="Host"&&$2==h{f=1;next} f&&$1=="Host"{exit} f&&$1=="User"{print $2;exit}' \
    "$HOME/.ssh/config" 2>/dev/null || true
}
base_in_use() {  # is this file attached directly to a running VM?
  local d
  for d in $(sudo virsh list --name); do
    sudo virsh domblklist "$d" --details | grep -qF "$1" && return 0
  done
  return 1
}
has_ovmf() {     # UEFI firmware for VMs installed?
  compgen -G '/usr/share/OVMF/OVMF_CODE*.fd' >/dev/null \
    || compgen -G '/usr/share/edk2/ovmf/OVMF_CODE*.fd' >/dev/null \
    || grep -qs '"uefi"' /usr/share/qemu/firmware/*.json
}
root_dev() {     # root filesystem device of an image, e.g. /dev/sda1
  "${GFS[@]}" guestfish --ro -a "$1" run : inspect-os 2>/dev/null | head -1 || true
}

# ===================== Local config =====================
init_config() {
  mkdir -p "$CONFIG_DIR"
  [ -s "$CONFIG" ] || echo '{"last_n":0,"vms":{},"unmanaged":[]}' > "$CONFIG"
  jq -e '.vms' "$CONFIG" >/dev/null 2>&1 \
    || die "invalid config: $CONFIG (delete it, it will be rebuilt from KVM)"
}
save_config() { local t; t=$(mktemp); jq "$@" "$CONFIG" > "$t" && mv "$t" "$CONFIG"; }

sync_config() {
  local all=() live=() others=() cfg=() vm net n ip changed=0 old new
  mapfile -t all < <(sudo virsh list --all --name | sed '/^$/d')
  for vm in "${all[@]}"; do
    if [[ "$vm" == "$PREFIX"* ]]; then live+=("$vm"); else others+=("$vm"); fi
  done

  # managed VMs: KVM -> config
  for vm in "${live[@]}"; do
    net=$(dom_net "$vm"); n=$(net_n "$net"); ip=""
    [ -n "$n" ] && ip="$SUBNET_PREFIX.$n.10"
    if ! jq -e --arg v "$vm" '.vms[$v]' "$CONFIG" >/dev/null; then
      info "Found in KVM but not in config, added: ${B}$vm${R}"
      save_config --arg v "$vm" --arg net "$net" --arg n "$n" --arg ip "$ip" \
        --arg u "$(ssh_cfg_user "$vm")" --arg d "$(dom_disk "$vm")" \
        '.vms[$v] = {network:$net, n:($n|tonumber? // null), ip:$ip, os:"unknown", user:$u, disk:$d}'
      changed=1
    elif ! jq -e --arg v "$vm" --arg net "$net" --arg ip "$ip" \
           '.vms[$v] | .network==$net and .ip==$ip' "$CONFIG" >/dev/null; then
      info "Network differs from config, updated: ${B}$vm${R}"
      save_config --arg v "$vm" --arg net "$net" --arg n "$n" --arg ip "$ip" \
        '.vms[$v] += {network:$net, n:($n|tonumber? // null), ip:$ip}'
      changed=1
    fi
  done

  # managed VMs: config -> KVM
  mapfile -t cfg < <(jq -r '.vms | keys[]' "$CONFIG")
  for vm in "${cfg[@]}"; do
    if ! printf '%s\n' "${live[@]}" | grep -qx "$vm"; then
      info "In config but no longer in KVM, removed: ${B}$vm${R}"
      save_config --arg v "$vm" 'del(.vms[$v])'
      changed=1
    fi
  done

  # other VMs
  old=$(jq -c '.unmanaged // []' "$CONFIG")
  new=$(printf '%s\n' "${others[@]}" | jq -R . | jq -sc 'map(select(. != "")) | sort')
  if ! jq -en --argjson a "$old" --argjson b "$new" '($a|sort) == $b' >/dev/null; then
    jq -rn --argjson a "$old" --argjson b "$new" '($b - $a)[]' | while read -r vm; do
      info "New non-managed VM: ${B}$vm${R}"; done
    jq -rn --argjson a "$old" --argjson b "$new" '($a - $b)[]' | while read -r vm; do
      info "Non-managed VM no longer in KVM: ${B}$vm${R}"; done
    save_config --argjson b "$new" '.unmanaged = $b'
    changed=1
  fi

  if [ $changed -eq 0 ]; then ok "Config in sync with KVM"; else ok "Config updated: $CONFIG"; fi
}

VMS=()
list_vms() {
  local i=0 vm n ip os st nets others=() w
  mapfile -t VMS < <(jq -r '.vms | keys[]' "$CONFIG" | sort)
  mapfile -t others < <(jq -r '.unmanaged[]?' "$CONFIG" | sort)

  echo
  box_top "Managed dev VMs (${PREFIX}*)  ${DIM}${#VMS[@]} total${R}"
  if [ ${#VMS[@]} -eq 0 ]; then
    box_line "${DIM}none yet ${ARROW} choose 'Create a new VM' to add one${R}"
  else
    box_line "$(printf "${DIM}%-3s %-22s %-3s %-13s %-16s %s${R}" "#" NAME N IP OS STATE)"
    for vm in "${VMS[@]}"; do
      i=$((i+1))
      IFS=$'\t' read -r n ip os < <(jq -r --arg v "$vm" '.vms[$v] |
        [(.n // "-"), (if (.ip // "") == "" then "-" else .ip end), (.os // "-")] | @tsv' "$CONFIG")
      st=$(dom_state "$vm")
      box_line "$(printf "${B}${CYN}%-3s${R} %-22s %-3s %-13s %-16s %s%s %s${R}" \
        "$i" "${vm:0:22}" "$n" "$ip" "${os:0:16}" "$(state_color "$st")" "$(state_icon "$st")" "$st")"
    done
  fi
  box_sep
  box_line "${B}Other VMs in KVM${R}  ${DIM}read-only, not managed by this script${R}"
  if [ ${#others[@]} -eq 0 ]; then
    box_line "${DIM}none${R}"
  else
    w=$((UI_W - 4 - 26 - 13 - 2)); [ $w -lt 8 ] && w=8
    for vm in "${others[@]}"; do
      st=$(dom_state "$vm"); nets=$(dom_nets "$vm")
      box_line "$(printf "${DIM}%-3s${R} %-22s %s%s %-10s${R} ${DIM}%s${R}" \
        "-" "${vm:0:22}" "$(state_color "$st")" "$(state_icon "$st")" "$st" "${nets:0:$w}")"
    done
  fi
  box_bottom
}

pick_vm() {      # asks for a managed VM number, prints its name
  local i
  [ ${#VMS[@]} -gt 0 ] || die "no managed VMs"
  i=$(ask "$1")
  [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le ${#VMS[@]} ] || die "invalid choice"
  echo "${VMS[$((i-1))]}"
}

next_n() {       # max(N in use in KVM, last_n) + 1; if exhausted, first free one
  local nets=() used=() net n max
  mapfile -t nets < <(sudo virsh net-list --all --name | sed '/^$/d')
  for net in "${nets[@]}"; do n=$(net_n "$net"); [ -n "$n" ] && used+=("$n"); done
  max=$(jq -r '.last_n // 0' "$CONFIG")
  for n in "${used[@]}"; do [ "$n" -gt "$max" ] && max=$n; done
  if [ $((max+1)) -le 254 ]; then echo $((max+1)); return; fi
  for n in $(seq 1 254); do
    printf '%s\n' "${used[@]}" | grep -qx "$n" || { echo "$n"; return; }
  done
  die "no free subnet left in $SUBNET_PREFIX.1-254"
}

# ===================== Base images =====================
latest_base() {
  sudo find "$BASE_DIR" -maxdepth 1 -name "$1-*.qcow2" -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d' ' -f2-
}

get_base() {     # $1 = ubuntu|rocky — prints the base image path
  local os=$1 cur url sum line dl dest
  cur=$(latest_base "$os")
  if [ -n "$cur" ] && ! yes_no "Cached $os image found ($(basename "$cur")). Download a newer one?"; then
    echo "$cur"; return
  fi
  case $os in
    ubuntu)
      line=$(curl -fsSL "$UBUNTU_DIR/SHA256SUMS" | grep -E 'server-cloudimg-amd64\.img$' | head -1) \
        || die "cannot read the Ubuntu image list from $UBUNTU_DIR"
      sum=${line%% *}; url="$UBUNTU_DIR/${line##*[ *]}" ;;
    rocky)
      url=$ROCKY_URL
      sum=$(curl -fsSL "$url.CHECKSUM" | grep -oE '= [0-9a-f]{64}' | cut -c3-) \
        || die "cannot read the Rocky checksum" ;;
  esac
  [ -n "$sum" ] || die "checksum not found for $url"

  dl=$(mktemp); trap "rm -f '$dl'" EXIT
  info "Downloading $url"
  curl -fL --progress-bar -o "$dl" "$url" >&2
  echo "$sum  $dl" | sha256sum -c --quiet - >&2 || die "checksum mismatch, download is corrupted"

  dest="$BASE_DIR/$os-$(date +%Y%m%d-%H%M).qcow2"
  sudo mkdir -p "$BASE_DIR"
  sudo qemu-img convert -O qcow2 "$dl" "$dest"
  sudo chmod 444 "$dest"
  ok "Base image saved: $dest"
  echo "$dest"
}

# ===================== Tool selection =====================
select_tools() { # fills SEL; returns 1 if nothing was selected
  local i k v pick nums=()
  SEL=()
  echo
  box_top "Development tools"
  i=0
  for k in "${TOOL_KEYS[@]}"; do
    i=$((i+1))
    box_line "$(printf "${B}${CYN}%2d${R}  %-30s ${DIM}%s${R}" "$i" "${TOOL_LABEL[$k]}" \
      "${TOOL_DEFAULT[$k]:+default: ${TOOL_DEFAULT[$k]}}")"
  done
  box_sep
  box_line "${DIM}numbers separated by spaces ${BUL} 'a' = all ${BUL} Enter = none${R}"
  box_bottom
  pick=$(ask "Tools to install")
  [ -n "$pick" ] || return 1
  if [[ "$pick" =~ ^[aA]$ ]]; then
    mapfile -t nums < <(seq 1 ${#TOOL_KEYS[@]})
  else
    read -ra nums <<<"${pick//,/ }"
  fi
  for i in "${nums[@]}"; do
    [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le ${#TOOL_KEYS[@]} ] || die "invalid tool number: $i"
    SEL[${TOOL_KEYS[$((i-1))]}]=yes
  done

  for k in "${TOOL_KEYS[@]}"; do
    [ -n "${SEL[$k]:-}" ] && [ -n "${TOOL_DEFAULT[$k]:-}" ] || continue
    v=$(ask "${TOOL_LABEL[$k]} versions ${DIM}(${TOOL_HINT[$k]}; first = default)${R}" "${TOOL_DEFAULT[$k]}")
    read -ra nums <<<"${v//,/ }"; v="${nums[*]}"
    [[ "$v" =~ ^[A-Za-z0-9./*_-]+( [A-Za-z0-9./*_-]+)*$ ]] || die "invalid version list: $v"
    SEL[$k]=$v
  done

  if [ -n "${SEL[claude]:-}" ] && [ -z "${SEL[node]:-}" ]; then
    SEL[node]="lts/*"; info "Claude Code needs Node.js: adding the Node.js LTS via nvm"
  fi
  if { [ -n "${SEL[ollama]:-}" ] || [ -n "${SEL[lmstudio]:-}" ]; } && [ "$MEMORY" -lt 16384 ]; then
    warn "local LLMs run on CPU here and need a lot of RAM: consider raising MEMORY (now ${MEMORY} MB)"
  fi

  echo
  box_top "Selected tools" "$GRN"
  for k in "${TOOL_KEYS[@]}"; do
    [ -n "${SEL[$k]:-}" ] || continue
    if [ "${SEL[$k]}" = yes ]; then box_line "${GRN}${CHK}${R} ${TOOL_LABEL[$k]}"
    else box_line "${GRN}${CHK}${R} $(printf '%-30s' "${TOOL_LABEL[$k]}") ${B}${SEL[$k]}${R}"; fi
  done
  box_bottom
  return 0
}

# ===================== Provisioning (runs inside the VM) =====================
remote_script() {
cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
B=$'\e[1m'; BLU=$'\e[34m'; CYN=$'\e[36m'; GRN=$'\e[32m'; RED=$'\e[31m'; YEL=$'\e[33m'; R=$'\e[0m'
log()  { printf '\n%s%s==[ %s ]%s\n' "$CYN" "$B" "$*" "$R"; }
note() { printf '%s! %s%s\n' "$YEL" "$*" "$R"; }

. /etc/os-release
case " $ID ${ID_LIKE:-} " in
  *" debian "*|*" ubuntu "*)            PM=apt ;;
  *" rhel "*|*" fedora "*|*" centos "*) PM=dnf ;;
  *) echo "Unsupported distribution: $ID" >&2; exit 1 ;;
esac
IS_UBUNTU=0
case " $ID ${ID_LIKE:-} " in *" ubuntu "*) IS_UBUNTU=1 ;; esac
ME=$(id -un)

pkg() {
  if [ "$PM" = apt ]; then sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"
  else sudo dnf install -y -q "$@"; fi
}

ENVF="$HOME/.devbox_env"
MARKF="$HOME/.devbox_installed"
add_env() { grep -qxF -- "$1" "$ENVF" 2>/dev/null || printf '%s\n' "$1" >> "$ENVF"; }
mark() {
  touch "$MARKF"
  { grep -v "^$1=" "$MARKF" || true; printf '%s=%s\n' "$1" "$2"; } > "$MARKF.tmp"
  mv "$MARKF.tmp" "$MARKF"
}

setup_env() {   # one env file, loaded by interactive and non-interactive shells
  local line='[ -f "$HOME/.devbox_env" ] && . "$HOME/.devbox_env"'
  touch "$HOME/.bashrc" "$HOME/.profile"
  if [ ! -s "$ENVF" ]; then
    printf '%s\n' '# kvm-devbox: tool environment (loaded by ~/.bashrc and ~/.profile)' \
      '[ -n "${DEVBOX_ENV_LOADED:-}" ] && return' 'DEVBOX_ENV_LOADED=1' > "$ENVF"
  fi
  if ! grep -qF '.devbox_env' "$HOME/.bashrc"; then   # at the top: before the non-interactive early return
    { printf '%s\n' "$line"; cat "$HOME/.bashrc"; } > "$HOME/.bashrc.devbox"
    mv "$HOME/.bashrc.devbox" "$HOME/.bashrc"
  fi
  grep -qF '.devbox_env' "$HOME/.profile" || printf '%s\n' "$line" >> "$HOME/.profile"
  mkdir -p "$HOME/.local/bin"
  add_env 'export PATH="$HOME/.local/bin:$PATH"'
}

step_base() {
  if [ "$PM" = apt ]; then
    sudo apt-get update -q
    pkg curl git unzip zip tar xz-utils zstd ca-certificates gnupg build-essential software-properties-common
  else
    pkg git unzip zip tar xz zstd gcc gcc-c++ make which dnf-plugins-core
  fi
}

step_node() {
  local vers=() v first=""
  read -ra vers <<<"$NODE_VERSIONS"
  [ -d "$HOME/.nvm/.git" ] || git clone -q https://github.com/nvm-sh/nvm.git "$HOME/.nvm"
  ( cd "$HOME/.nvm" && git fetch -q --tags origin \
      && git -c advice.detachedHead=false checkout -q \
         "$(git describe --abbrev=0 --tags --match 'v[0-9]*' "$(git rev-list --tags --max-count=1)")" )
  add_env 'export NVM_DIR="$HOME/.nvm"'
  add_env '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
  add_env '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"'
  set +euo pipefail
  export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"
  for v in "${vers[@]}"; do
    nvm install "$v" || exit 1
    [ -n "$first" ] || first=$v
  done
  nvm alias default "$first" || exit 1
  mark node "${vers[*]}"
}

step_python() {
  local vers=()
  read -ra vers <<<"$PY_VERSIONS"
  export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh
  uv python install "${vers[@]}"
  ln -sf "$(uv python find "${vers[0]}")" "$HOME/.local/bin/python"
  uv tool install poetry
  mark python "${vers[*]}"
}

step_java() {
  local vers=() v id list first=""
  read -ra vers <<<"$JAVA_VERSIONS"
  [ -d "$HOME/.sdkman" ] || curl -fsSL "https://get.sdkman.io?rcupdate=false" | bash
  sed -i 's/^sdkman_auto_answer=.*/sdkman_auto_answer=true/' "$HOME/.sdkman/etc/config"
  add_env 'export SDKMAN_DIR="$HOME/.sdkman"'
  add_env '[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && . "$SDKMAN_DIR/bin/sdkman-init.sh"'
  list=$(curl -fsSL "https://api.sdkman.io/2/candidates/java/linuxx64/versions/list?installed=")
  set +euo pipefail
  export SDKMAN_DIR="$HOME/.sdkman"; . "$SDKMAN_DIR/bin/sdkman-init.sh"
  for v in "${vers[@]}"; do
    id=$(grep -oE "\b${v}(\.[0-9]+)*-tem\b" <<<"$list" | head -1)
    if [ -z "$id" ]; then echo "No Temurin build found for Java $v" >&2; exit 1; fi
    sdk install java "$id" </dev/null || [ -d "$SDKMAN_DIR/candidates/java/$id" ] || exit 1
    [ -n "$first" ] || first=$id
  done
  sdk default java "$first" </dev/null || exit 1
  mark java "${vers[*]}"
}

step_php() {
  local vers=() v vv first="" use_ppa=0
  read -ra vers <<<"$PHP_VERSIONS"
  if [ "$PM" = apt ]; then
    if [ $IS_UBUNTU = 1 ]; then
      if grep -rqs 'ondrej/php' /etc/apt/sources.list.d/ || sudo add-apt-repository -y -n ppa:ondrej/php; then
        if sudo apt-get update -q; then
          use_ppa=1
        else
          note "ppa:ondrej/php does not support this Ubuntu release yet: removing it"
          sudo add-apt-repository -y -r ppa:ondrej/php || true
          sudo apt-get update -q
        fi
      fi
    fi
    if [ $use_ppa = 1 ]; then
      for v in "${vers[@]}"; do
        pkg "php$v-cli" "php$v-common" "php$v-mbstring" "php$v-xml" "php$v-curl" "php$v-zip" \
            "php$v-intl" "php$v-bcmath" "php$v-gd" "php$v-mysql" "php$v-pgsql" "php$v-sqlite3"
        [ -n "$first" ] || first=$v
      done
      sudo update-alternatives --set php "/usr/bin/php$first"
      mark php "${vers[*]}"
    else
      note "Installing the distribution's PHP (single version) instead of: ${vers[*]}"
      pkg php-cli php-common php-mbstring php-xml php-curl php-zip php-intl php-bcmath php-gd \
          php-mysql php-pgsql php-sqlite3
      mark php "distro"
    fi
  else
    pkg epel-release
    pkg "https://rpms.remirepo.net/enterprise/remi-release-${VERSION_ID%%.*}.rpm"
    for v in "${vers[@]}"; do
      vv=${v//./}
      pkg "php$vv-php-cli" "php$vv-php-mbstring" "php$vv-php-xml" "php$vv-php-pdo" "php$vv-php-mysqlnd" \
          "php$vv-php-pgsql" "php$vv-php-intl" "php$vv-php-pecl-zip" "php$vv-php-bcmath" "php$vv-php-gd"
      [ -n "$first" ] || first=$vv
    done
    sudo ln -sf "/usr/bin/php$first" /usr/local/bin/php
    mark php "${vers[*]}"
  fi
  # Composer (installer signature verified)
  curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
  [ "$(curl -fsSL https://composer.github.io/installer.sig)" = \
    "$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")" ] \
    || { echo "Composer installer signature mismatch" >&2; exit 1; }
  php /tmp/composer-setup.php --quiet --install-dir="$HOME/.local/bin" --filename=composer
  rm -f /tmp/composer-setup.php
}

step_dotnet() {
  local chans=() c icu
  read -ra chans <<<"$DOTNET_CHANNELS"
  if [ "$PM" = apt ]; then
    icu=$(apt-cache pkgnames libicu | grep -E '^libicu[0-9]+$' | sort -V | tail -1 || true)
    [ -z "$icu" ] || pkg "$icu"
  else
    pkg libicu
  fi
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  for c in "${chans[@]}"; do
    bash /tmp/dotnet-install.sh --channel "$c" --install-dir "$HOME/.dotnet"
  done
  rm -f /tmp/dotnet-install.sh
  add_env 'export DOTNET_ROOT="$HOME/.dotnet"'
  add_env 'export PATH="$DOTNET_ROOT:$DOTNET_ROOT/tools:$PATH"'
  add_env 'export DOTNET_CLI_TELEMETRY_OPTOUT=1'
  mark dotnet "${chans[*]}"
}

step_docker() {
  if [ "$PM" = apt ]; then
    local distro=debian codename=${VERSION_CODENAME:-}
    if [ $IS_UBUNTU = 1 ]; then distro=ubuntu; codename=${UBUNTU_CODENAME:-$codename}; fi
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$distro $codename stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    if sudo apt-get update -q && apt-cache policy docker-ce | grep -q 'Candidate: [0-9]'; then
      pkg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      note "Docker's repository does not support '$codename' yet: using the distribution packages"
      sudo rm -f /etc/apt/sources.list.d/docker.list
      sudo apt-get update -q
      pkg docker.io docker-compose-v2
    fi
  else
    sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    pkg docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$ME"
  mark docker yes
}

step_ollama() {
  curl -fsSL https://ollama.com/install.sh | sh
  mark ollama yes
}

step_lmstudio() {
  curl -fsSL https://lmstudio.ai/install.sh | bash
  add_env 'export PATH="$HOME/.lmstudio/bin:$PATH"'
  mark lmstudio yes
}

step_claude() {
  set +euo pipefail
  export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh" || exit 1
  nvm use default >/dev/null || exit 1
  npm install -g @anthropic-ai/claude-code || exit 1
  mark claude yes
}

step_kimi() {
  curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash
  mark kimi yes
}

OK=(); FAIL=()
run_step() {    # label function — each step runs isolated, a failure does not stop the others
  local label=$1 fn=$2 rc
  log "$label"
  set +e; ( set -e; "$fn" ); rc=$?; set -e
  if [ $rc -eq 0 ]; then OK+=("$label"); printf '%s[ok] %s%s\n' "$GRN" "$label" "$R"
  else FAIL+=("$label"); printf '%s[failed] %s%s\n' "$RED" "$label" "$R"; fi
}

log "Base packages"
step_base
setup_env

if [ -n "$NODE_VERSIONS" ];   then run_step "Node.js $NODE_VERSIONS (nvm)" step_node; fi
if [ -n "$PY_VERSIONS" ];     then run_step "Python $PY_VERSIONS (uv + Poetry)" step_python; fi
if [ -n "$JAVA_VERSIONS" ];   then run_step "Java $JAVA_VERSIONS (SDKMAN, Temurin)" step_java; fi
if [ -n "$PHP_VERSIONS" ];    then run_step "PHP $PHP_VERSIONS + Composer" step_php; fi
if [ -n "$DOTNET_CHANNELS" ]; then run_step ".NET SDK $DOTNET_CHANNELS" step_dotnet; fi
if [ -n "$WANT_DOCKER" ];     then run_step "Docker + Docker Compose" step_docker; fi
if [ -n "$WANT_OLLAMA" ];     then run_step "Ollama" step_ollama; fi
if [ -n "$WANT_LMSTUDIO" ];   then run_step "LM Studio (llmster)" step_lmstudio; fi
if [ -n "$WANT_CLAUDE" ];     then run_step "Claude Code" step_claude; fi
if [ -n "$WANT_KIMI" ];       then run_step "Kimi Code" step_kimi; fi

log "Summary"
for s in "${OK[@]}";   do printf '  %s[ok]%s     %s\n' "$GRN" "$R" "$s"; done
for s in "${FAIL[@]}"; do printf '  %s[failed]%s %s\n' "$RED" "$R" "$s"; done
echo
note "Open a new SSH session to load the updated PATH."
if [ -n "$WANT_DOCKER" ];   then note "Docker: log out and back in to use docker without sudo."; fi
if [ -n "$WANT_LMSTUDIO" ]; then note "LM Studio: start the daemon with 'lms daemon up'."; fi
[ ${#FAIL[@]} -eq 0 ]
REMOTE
}

wait_ssh() {
  local i
  info "Waiting for SSH on $1..."
  for i in $(seq 1 60); do
    if ssh -o BatchMode=yes -o ConnectTimeout=3 "$1" true 2>/dev/null; then ok "SSH is up"; return 0; fi
    sleep 3
  done
  die "SSH on $1 did not come up within 3 minutes"
}

provision_run() { # $1 = VM name, uses SEL
  local vm=$1 PROV rc installed tools_json
  if [ "$(dom_state "$vm")" != running ]; then
    info "Starting $vm"; sudo virsh start "$vm" >/dev/null
  fi
  wait_ssh "$vm"

  newtmp PROV
  {
    echo '#!/usr/bin/env bash'
    printf 'NODE_VERSIONS=%q\n'   "${SEL[node]:-}"
    printf 'PY_VERSIONS=%q\n'     "${SEL[python]:-}"
    printf 'JAVA_VERSIONS=%q\n'   "${SEL[java]:-}"
    printf 'PHP_VERSIONS=%q\n'    "${SEL[php]:-}"
    printf 'DOTNET_CHANNELS=%q\n' "${SEL[dotnet]:-}"
    printf 'WANT_DOCKER=%q\n'     "${SEL[docker]:+1}"
    printf 'WANT_OLLAMA=%q\n'     "${SEL[ollama]:+1}"
    printf 'WANT_LMSTUDIO=%q\n'   "${SEL[lmstudio]:+1}"
    printf 'WANT_CLAUDE=%q\n'     "${SEL[claude]:+1}"
    printf 'WANT_KIMI=%q\n'       "${SEL[kimi]:+1}"
    remote_script
  } > "$PROV"

  echo
  box_top "Provisioning $vm" "$MAG"
  box_line "Installing the selected tools inside the VM. This can take a while."
  box_bottom
  scp -q "$PROV" "$vm:/tmp/kvm-devbox-provision.sh"
  set +e
  ssh -t "$vm" 'bash /tmp/kvm-devbox-provision.sh; rc=$?; rm -f /tmp/kvm-devbox-provision.sh; exit $rc'
  rc=$?
  set -e

  installed=$(ssh -o BatchMode=yes "$vm" 'cat ~/.devbox_installed 2>/dev/null' || true)
  tools_json=$(printf '%s\n' "$installed" \
    | jq -R 'select(length > 0) | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}' | jq -s 'add // {}')
  save_config --arg v "$vm" --argjson t "$tools_json" '.vms[$v].tools = $t'

  if [ $rc -eq 0 ]; then ok "Development tools installed on $vm"
  else warn "some tools failed on $vm: see the output above, then run 'Install development tools' again to retry"; fi
}

provision_existing() {
  local vm current
  vm=$(pick_vm "Number of the VM to provision")
  current=$(jq -r --arg v "$vm" '.vms[$v].tools // {} | to_entries | map("\(.key)=\(.value)") | join(", ")' "$CONFIG")
  [ -z "$current" ] || info "Already installed on $vm: ${DIM}$current${R}"
  select_tools || { warn "nothing selected"; return; }
  provision_run "$vm"
}

# ===================== Create =====================
create_vm() {
  local name VM NET BR N IP MAC KEY DISK BASE OS GUSER XML ROOTDEV uefi=0 kind do_tools=0
  local PW PW2 PWFILE="" size_arg=() cust=() tools
  echo
  box_top "Create a new VM"
  box_line "Each VM gets its own disk, network, SSH key and identity."
  box_line "${DIM}The name is prefixed with '${PREFIX}', e.g. acme ${ARROW} ${PREFIX}acme${R}"
  box_bottom
  name=$(ask "VM name")
  name=${name#"$PREFIX"}
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "name: only a-z 0-9 -, max 31 characters"
  VM="$PREFIX$name"; NET="net-$name"
  DISK="$IMG_DIR/client-$name.qcow2"; KEY="$HOME/.ssh/client-$name"
  sudo virsh dominfo "$VM" &>/dev/null && die "VM $VM already exists"

  echo
  box_top "Operating system"
  menu_item 1 "Ubuntu Server 26.04 LTS   ${DIM}cloud image, no desktop${R}"
  menu_item 2 "Rocky Linux 10            ${DIM}GenericCloud, no desktop${R}"
  menu_item 3 "Local qcow2 file          ${DIM}your own base image${R}"
  box_bottom
  case "$(ask "Choice" 1)" in
    1) kind=cloud; OS=ubuntu-26.04; GUSER=$CLOUD_USER; BASE=$(get_base ubuntu) ;;
    2) kind=cloud; OS=rocky-10;     GUSER=$CLOUD_USER; BASE=$(get_base rocky) ;;
    3) kind=custom
       BASE=$(sudo realpath -e "$(ask "Path to the qcow2 file")" 2>/dev/null) || die "file not found"
       sudo qemu-img info "$BASE" | grep -q '^file format: qcow2' || die "the file is not in qcow2 format"
       base_in_use "$BASE" && die "$BASE is used by a running VM: shut it down first"
       GUSER=$(ask "Existing user in the image" dev)
       "${GFS[@]}" virt-cat -a "$BASE" /etc/passwd 2>/dev/null | grep -q "^$GUSER:" \
         || die "user '$GUSER' not found in the image (or the image is not readable by libguestfs)"
       OS="custom:$(basename "$BASE")"
       warn "from now on $BASE must never be booted or modified, or the VM disks based on it will be corrupted" ;;
    *) die "invalid choice" ;;
  esac

  # Optional console password (empty = SSH key only)
  read -rsp "${CYN}${ARROW}${R} ${B}Console password for $GUSER${R} ${DIM}(empty = SSH key only)${R}: " PW; echo >&2
  if [ -n "$PW" ]; then
    read -rsp "${CYN}${ARROW}${R} ${B}Repeat password${R}: " PW2; echo >&2
    [ "$PW" = "$PW2" ] || die "passwords do not match"
    newtmp PWFILE; printf '%s' "$PW" > "$PWFILE"
  fi

  # Development tools (installed after the first boot)
  if select_tools; then do_tools=1; fi

  # Inspect the base image (checked before creating anything)
  info "Inspecting the base image..."
  ROOTDEV=$(root_dev "$BASE")
  [ -n "$ROOTDEV" ] || die "no Linux root filesystem found in $BASE"
  if "${GFS[@]}" virt-cat -a "$BASE" /etc/fstab 2>/dev/null | grep -q '/boot/efi'; then
    uefi=1
    has_ovmf || die "UEFI image: install the firmware with 'sudo apt install ovmf'"
  fi

  # 1. Dedicated SSH key
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  [ -f "$KEY" ] || ssh-keygen -t ed25519 -f "$KEY" -C "client-$name"

  # 2. Isolated network (reuses one left over by a failed run)
  if sudo virsh net-info "$NET" &>/dev/null; then
    N=$(net_n "$NET"); [ -n "$N" ] || die "network $NET exists but is not a $SUBNET_PREFIX.N.0/24 network"
    info "Reusing existing network $NET (subnet $N)"
  else
    N=$(next_n)
  fi
  BR="virbr-c$N"; IP="$SUBNET_PREFIX.$N.10"; MAC=$(printf '52:54:00:0a:%02x:10' "$N")
  if ! sudo virsh net-info "$NET" &>/dev/null; then
    newtmp XML
    cat > "$XML" <<EOF
<network>
  <name>$NET</name>
  <forward mode='nat'/>
  <bridge name='$BR' stp='on' delay='0'/>
  <ip address='$SUBNET_PREFIX.$N.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='$SUBNET_PREFIX.$N.100' end='$SUBNET_PREFIX.$N.200'/>
      <host mac='$MAC' name='$VM' ip='$IP'/>
    </dhcp>
  </ip>
</network>
EOF
    sudo virsh net-define "$XML" >/dev/null
    sudo virsh net-autostart "$NET" >/dev/null
    ok "Network $NET created ($SUBNET_PREFIX.$N.0/24)"
  fi
  sudo virsh net-info "$NET" | grep -q '^Active:.*yes' || sudo virsh net-start "$NET" >/dev/null
  save_config --argjson n "$N" '.last_n = ([(.last_n // 0), $n] | max)'

  # 3. Overlay disk, fully prepared before first boot (no cloud-init)
  if sudo test -e "$DISK"; then
    yes_no "$DISK already exists with no VM attached. Overwrite it?" || die "aborted"
    sudo rm -f "$DISK"
  fi
  PARTIAL="$DISK.partial"; sudo rm -f "$PARTIAL"
  [ "$kind" = cloud ] && size_arg=("$DISK_SIZE")
  sudo qemu-img create -f qcow2 -b "$BASE" -F qcow2 "$PARTIAL" "${size_arg[@]}" >/dev/null

  cust=(--hostname "$VM"
        --run-command "$SSHD_INSTALL"
        --run-command 'truncate -s 0 /etc/machine-id'
        --run-command 'rm -f /etc/ssh/ssh_host_* && ssh-keygen -A'
        --run-command 'if [ -d /etc/cloud ]; then touch /etc/cloud/cloud-init.disabled; fi'
        --run-command "$NET_FIX")
  if [ "$kind" = cloud ]; then
    cust+=(--run-command "id $GUSER >/dev/null 2>&1 || useradd -m -s /bin/bash $GUSER"
           --run-command "printf '%s ALL=(ALL) NOPASSWD:ALL\n' $GUSER > /etc/sudoers.d/90-$GUSER && chmod 0440 /etc/sudoers.d/90-$GUSER")
    if [[ "$ROOTDEV" =~ ^/dev/sda([0-9]+)$ ]]; then
      cust+=(--run-command "{ growpart /dev/sda ${BASH_REMATCH[1]} && { resize2fs $ROOTDEV || xfs_growfs /; }; } || echo 'WARNING: could not grow the root filesystem'")
    else
      warn "root filesystem on $ROOTDEV: it will not be grown to $DISK_SIZE"
    fi
  fi
  cust+=(--ssh-inject "$GUSER:file:$KEY.pub")
  [ -n "$PWFILE" ] && cust+=(--password "$GUSER:file:$PWFILE")
  cust+=(--selinux-relabel)

  info "Preparing the disk (user, SSH, network, disk size)..."
  "${GFS[@]}" virt-customize -a "$PARTIAL" "${cust[@]}"
  sudo mv "$PARTIAL" "$DISK"; PARTIAL=""
  ok "Disk ready: $DISK"

  # 4. VM
  local args=(--name "$VM" --memory "$MEMORY" --vcpus "$VCPUS" --cpu host-passthrough
    --disk "$DISK",bus=virtio --import --osinfo detect=on,require=off
    --network network="$NET",model=virtio,mac="$MAC"
    --graphics spice,listen=none --video virtio --noautoconsole)
  [ $uefi -eq 1 ] && args+=(--boot uefi)
  sudo virt-install "${args[@]}" >/dev/null
  ok "VM $VM started"

  # 5. SSH shortcut (always replaces an old entry with the same name)
  touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
  ssh-keygen -R "$IP" &>/dev/null || true
  ssh_cfg_remove "$VM"
  cat >> "$HOME/.ssh/config" <<EOF

Host $VM
    HostName $IP
    User $GUSER
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF

  # 6. Local config
  save_config --arg v "$VM" --arg net "$NET" --argjson n "$N" --arg ip "$IP" --arg os "$OS" \
    --arg u "$GUSER" --arg d "$DISK" --arg b "$BASE" --arg k "$KEY" --arg c "$(date -Iseconds)" \
    '.vms[$v] = {network:$net, n:$n, ip:$ip, os:$os, user:$u, disk:$d, base:$b, key:$k, created:$c}'

  # 7. Development tools
  if [ $do_tools -eq 1 ]; then provision_run "$VM"; fi

  tools=$(jq -r --arg v "$VM" '.vms[$v].tools // {} | keys | join(", ")' "$CONFIG")
  echo
  box_top "Ready" "$GRN"
  box_line "${GRN}${CHK}${R} ${B}$VM${R} is up and running"
  box_sep
  box_line "$(printf '%-11s %s' "SSH" "${B}ssh $VM${R}")"
  box_line "$(printf '%-11s %s' "Address" "$IP")"
  box_line "$(printf '%-11s %s' "User" "$GUSER")"
  box_line "$(printf '%-11s %s' "Key" "$KEY")"
  box_line "$(printf '%-11s %s' "OS" "$OS")"
  box_line "$(printf '%-11s %s' "Tools" "${tools:-none}")"
  box_sep
  box_line "${DIM}JetBrains Gateway: host $VM with 'Parse config file ~/.ssh/config'${R}"
  box_bottom
}

# ===================== Start / stop =====================
# Checklist: a ticked VM should be running, an unticked one should be off.
# Space toggles, arrows/j/k move, 'a' toggles all, Enter applies, q/Esc cancels.
PW_CUR=0; PW_STATE=(); PW_WANT=()
power_draw() {
  local i vm mark ptr act st
  box_top "Start / stop VMs" "$MAG"
  for i in "${!VMS[@]}"; do
    vm=${VMS[$i]}; st=${PW_STATE[$i]}
    if [ "${PW_WANT[$i]}" = 1 ]; then mark="${GRN}${B}[x]${R}"; else mark="${DIM}[ ]${R}"; fi
    if [ "$i" -eq "$PW_CUR" ]; then ptr="${CYN}${B}${ARROW}${R}"; else ptr=" "; fi
    act=""
    if   [ "${PW_WANT[$i]}" = 1 ] && [ "$st" != running ]; then act="${GRN}${ARROW} start${R}"
    elif [ "${PW_WANT[$i]}" = 0 ] && [ "$st" = running ];  then act="${RED}${ARROW} stop${R}"; fi
    box_line "$(printf '%s %s %-22s %s%s %-9s%s %s' "$ptr" "$mark" "${vm:0:22}" \
      "$(state_color "$st")" "$(state_icon "$st")" "$st" "$R" "$act")"
  done
  box_sep
  box_line "${DIM}space = select ${BUL} a = all ${BUL} Enter = apply ${BUL} q = cancel${R}"
  box_bottom
}

power_vms() {
  local n=${#VMS[@]} i key rest st vm lines todo=0 waited
  [ "$n" -gt 0 ] || { warn "no managed VMs"; return; }
  [ -t 0 ] && [ -t 1 ] || die "this menu needs an interactive terminal"
  PW_CUR=0; PW_STATE=(); PW_WANT=()
  for i in "${!VMS[@]}"; do
    st=$(dom_state "${VMS[$i]}"); PW_STATE[$i]=$st
    if [ "$st" = running ]; then PW_WANT[$i]=1; else PW_WANT[$i]=0; fi
  done

  lines=$((n + 4))
  echo
  printf '\e[?25l'
  power_draw
  while :; do
    IFS= read -rsn1 key || key=q
    if [ "$key" = $'\e' ]; then
      read -rsn2 -t 0.05 rest || rest=""
      key+=$rest
    fi
    case "$key" in
      $'\e[A'|k) PW_CUR=$(( (PW_CUR - 1 + n) % n )) ;;
      $'\e[B'|j) PW_CUR=$(( (PW_CUR + 1) % n )) ;;
      ' ')       PW_WANT[$PW_CUR]=$(( 1 - PW_WANT[PW_CUR] )) ;;
      a|A)       key=1
                 for i in "${!VMS[@]}"; do [ "${PW_WANT[$i]}" = 1 ] || key=0; done
                 for i in "${!VMS[@]}"; do PW_WANT[$i]=$(( 1 - key )); done ;;
      '')        break ;;
      q|Q|$'\e') printf '\e[?25h'; warn "cancelled"; return ;;
      *)         continue ;;
    esac
    printf '\e[%dA' "$lines"
    power_draw
  done
  printf '\e[?25h'
  echo

  for i in "${!VMS[@]}"; do
    vm=${VMS[$i]}; st=${PW_STATE[$i]}
    if [ "${PW_WANT[$i]}" = 1 ]; then
      case "$st" in
        running) ;;
        paused)  info "Resuming $vm";  sudo virsh resume "$vm" >/dev/null; todo=1 ;;
        *)       info "Starting $vm";  sudo virsh start "$vm" >/dev/null;  todo=1 ;;
      esac
    elif [ "$st" = running ]; then
      info "Shutting down $vm"; sudo virsh shutdown "$vm" >/dev/null; todo=1
    fi
  done
  [ $todo -eq 1 ] || { ok "Nothing to change"; return; }

  # shutdown is asynchronous: wait up to 60 s for the guests to power off
  for waited in $(seq 1 30); do
    todo=0
    for i in "${!VMS[@]}"; do
      [ "${PW_WANT[$i]}" = 0 ] && [ "${PW_STATE[$i]}" = running ] \
        && [ "$(dom_state "${VMS[$i]}")" = running ] && todo=1
    done
    [ $todo -eq 0 ] && break
    sleep 2
  done

  for i in "${!VMS[@]}"; do
    vm=${VMS[$i]}; st=$(dom_state "$vm")
    if [ "${PW_WANT[$i]}" = 1 ]; then
      [ "$st" = running ] && ok "$vm is running ${DIM}(ssh $vm)${R}" || warn "$vm is $st"
    elif [ "${PW_STATE[$i]}" = running ]; then
      if [ "$st" = running ]; then
        warn "$vm is still running: the guest ignored the shutdown request (force it with: sudo virsh destroy $vm)"
      else ok "$vm is off"; fi
    fi
  done
}

# ===================== Delete =====================
ssh_cfg_remove() {
  local cfg="$HOME/.ssh/config" t
  [ -f "$cfg" ] || return 0
  t=$(mktemp)
  awk -v h="$1" '
    $1=="Host" && $2==h {skip=1; next}
    skip && ($0 ~ /^[[:space:]]/ || $0 == "") {next}
    {skip=0; print}' "$cfg" | cat -s > "$t"
  cat "$t" > "$cfg"; rm -f "$t"
}

delete_vm() {
  [ ${#VMS[@]} -gt 0 ] || { warn "no managed VMs to delete"; return; }
  local vm name net disk ip key
  vm=$(pick_vm "Number of the VM to delete"); name=${vm#"$PREFIX"}
  net=$(dom_net "$vm"); [ -n "$net" ] || net="net-$name"
  disk=$(dom_disk "$vm")
  ip=$(jq -r --arg v "$vm" '.vms[$v].ip // empty' "$CONFIG")
  key=$(jq -r --arg v "$vm" '.vms[$v].key // empty' "$CONFIG"); [ -n "$key" ] || key="$HOME/.ssh/client-$name"

  echo
  box_top "Delete $vm" "$RED"
  box_line "${RED}${B}This cannot be undone.${R} The following will be removed:"
  box_sep
  box_line "$(printf '%-11s %s' "VM" "${B}$vm${R}")"
  box_line "$(printf '%-11s %s' "Disk" "${disk:-(none)}")"
  box_line "$(printf '%-11s %s' "Network" "$net")"
  box_line "$(printf '%-11s %s' "SSH entry" "'$vm' in ~/.ssh/config")"
  box_bottom
  [ "$(ask "Type '$vm' to confirm")" = "$vm" ] || { warn "aborted"; return; }

  sudo virsh destroy "$vm" &>/dev/null || true
  sudo virsh undefine "$vm" --nvram &>/dev/null || sudo virsh undefine "$vm" >/dev/null
  ok "VM deleted"

  # only delete client-*.qcow2 disks: never base images
  if [[ "$disk" == "$IMG_DIR"/client-*.qcow2 ]]; then
    sudo rm -f "$disk"; ok "Disk deleted"
  elif [ -n "$disk" ]; then
    warn "disk $disk NOT deleted (not a client-*.qcow2 disk)"
  fi

  if [[ "$net" == net-* ]] && sudo virsh net-info "$net" &>/dev/null; then
    sudo virsh net-destroy "$net" &>/dev/null || true
    sudo virsh net-undefine "$net" >/dev/null
    ok "Network deleted"
  fi

  ssh_cfg_remove "$vm"
  [ -n "$ip" ] && ssh-keygen -R "$ip" &>/dev/null || true
  ssh-keygen -R "$vm" &>/dev/null || true
  ok "SSH entry removed"
  if [ -f "$key" ] && yes_no "Also delete the SSH key $key?"; then
    rm -f "$key" "$key.pub"; ok "SSH key deleted"
  fi

  save_config --arg v "$vm" 'del(.vms[$v])'
  echo
  box_top "Done" "$GRN"
  box_line "${GRN}${CHK}${R} ${B}$vm${R} has been deleted"
  box_bottom
}

# ===================== Main =====================
main() {
  banner
  check_deps
  init_config
  info "Reading VMs from KVM and syncing the local config"
  sync_config
  list_vms
  echo
  box_top "What do you want to do?"
  menu_item 1 "Create a new VM"
  menu_item 2 "Install development tools on a VM"
  menu_item 3 "Start / stop VMs"
  menu_item 4 "Delete a VM"
  menu_item 5 "Quit"
  box_bottom
  case "$(ask "Choice" 5)" in
    1) create_vm ;;
    2) provision_existing ;;
    3) power_vms ;;
    4) delete_vm ;;
    *) exit 0 ;;
  esac
}
main "$@"