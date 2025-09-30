#!/bin/sh

# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2025 g-Projets


# g-guest - segments manager (VALE & Netgraph)
# Commands:
#   ensure                   # ensure all switches from networks.yaml exist
#   attach-if <backend> <logical> <ifname>
#   detach-if <backend> <logical> <ifname>

set -eu

BASE_DIR="${BASE_DIR:-/usr/local/g-guest}"
CFG_DIR="${CFG_DIR:-$BASE_DIR/config}"
NETWORKS_YAML="${NETWORKS_YAML:-$CFG_DIR/networks.yaml}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
info(){ echo "INFO: $*"; }
warn(){ echo "WARN: $*" >&2; }
err(){ echo "ERROR: $*" >&2; exit 1; }

have_access_lib=0
if [ -r "${BASE_DIR}/lib/access.sh" ]; then
  . "${BASE_DIR}/lib/access.sh"
  have_access_lib=1
fi

kld_ng(){ kldload -nq ng_ether ng_bridge || true; }
ng_next_link(){ sw="$1"; n=2; while ngctl msg "${sw}:" getstats "link${n}" >/dev/null 2>&1; do n=$((n+1)); done; echo "link${n}"; }
ng_switch_ensure_raw(){
  sw="$1"
  if ngctl list -l | awk '{print $2}' | grep -qx "$sw"; then return 0; fi
  kld_ng
  ngctl mkpeer eiface ether ether >/dev/null
  ngeth=$(ngctl list -l | awk '$3=="eiface"{print $2}' | tail -1)
  ngctl mkpeer "${ngeth}:" bridge ether "$(ng_next_link "$sw")" >/dev/null
  ngctl name "${ngeth}:ether" "$sw" >/dev/null
  ngctl shutdown "${ngeth}:" >/dev/null 2>&1 || true
}

ng_host_if_ensure_raw(){
  ifn="$1"
  if ifconfig "$ifn" >/dev/null 2>&1; then echo "$ifn"; return 0; fi
  kld_ng
  ngctl mkpeer eiface ether ether >/dev/null
  ngeth=$(ngctl list -l | awk '$3=="eiface"{print $2}' | tail -1)
  ngctl name "${ngeth}:" "$ifn" >/dev/null
  ifconfig "$ngeth" name "$ifn" up >/dev/null
  echo "$ifn"
}

vale_switch_ensure(){
  need vale-ctl
  sw="$1"
  vale-ctl -n "$sw" >/dev/null 2>&1 || true
}

list_networks(){
  awk '
    $1=="networks:" {in=1; next}
    in && $1=="-" {n=""; b=""}
    in && $1=="name:" {n=$2}
    in && $1=="backend:" {b=$2; print n, b}
  ' "$NETWORKS_YAML"
}

ensure(){
  list_networks | while read -r n b; do
    [ -z "$n" ] && continue
    case "$b" in
      netgraph)
        sw="sw-${n}"
        info "ensure netgraph switch $sw"
        if [ $have_access_lib -eq 1 ]; then
          ng_switch_ensure "$sw"
        else
          ng_switch_ensure_raw "$sw"
        fi
        ;;
      vale)
        vsw="vale-${n}"
        info "ensure VALE switch $vsw"
        vale_switch_ensure "$vsw"
        ;;
      *) warn "unknown backend $b for network $n" ;;
    esac
  done
}

attach_if(){
  b="$1"; n="$2"; ifn="$3"
  [ -n "$b" ] && [ -n "$n" ] && [ -n "$ifn" ] || err "attach-if <backend> <logical> <ifname>"
  case "$b" in
    netgraph)
      sw="sw-${n}"
      if [ $have_access_lib -eq 1 ]; then
        ng_attach_if_to_switch "$sw" "$ifn"
      else
        ng_switch_ensure_raw "$sw"
        ng_host_if_ensure_raw "$ifn" >/dev/null
        lnk="$(ng_next_link "$sw")"
        ngctl connect "${ifn}:" "${sw}:" ether "$lnk" >/dev/null 2>&1 || true
      fi
      ;;
    vale)
      vsw="vale-${n}"
      vale_switch_ensure "$vsw"
      need vale-ctl
      vale-ctl -h "${vsw}:${ifn}" >/dev/null
      ;;
    *) err "unknown backend $b" ;;
  esac
}

detach_if(){
  b="$1"; n="$2"; ifn="$3"
  case "$b" in
    netgraph)
      ngctl shutdown "${ifn}:" >/dev/null 2>&1 || true
      ;;
    vale)
      vsw="vale-${n}"
      need vale-ctl
      vale-ctl -r "${vsw}:${ifn}" >/dev/null 2>&1 || true
      ;;
    *) err "unknown backend $b" ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  ensure) ensure ;;
  attach-if) attach_if "${1:-}" "${2:-}" "${3:-}" ;;
  detach-if) detach_if "${1:-}" "${2:-}" "${3:-}" ;;
  *) echo "Usage: $0 {ensure|attach-if <backend> <logical> <if>|detach-if <backend> <logical> <if>}" >&2; exit 1 ;;
esac
