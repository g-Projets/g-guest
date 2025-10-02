#!/bin/sh

# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2025 g-Projets

# g-guest - segments manager (VALE & Netgraph)
# Commands:
#   [--list-ports] ensure
#   attach-if <backend> <logical> <ifname> [mode]   # mode: a|h|exclusive|shared (default: h/shared)
#   detach-if <backend> <logical> <ifname>

set -eu

BASE_DIR="${BASE_DIR:-/usr/local/g-guest}"
CFG_DIR="${CFG_DIR:-$BASE_DIR/config}"
NETWORKS_YAML="${NETWORKS_YAML:-$CFG_DIR/networks.yaml}"

LIST_PORTS=0

need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
info(){ echo "INFO: $*"; }
warn(){ echo "WARN: $*" >&2; }
err(){ echo "ERROR: $*" >&2; exit 1; }

# --- parse global flags (before subcommand) ---
while [ $# -gt 0 ] && [ "${1#--}" != "$1" ]; do
  case "$1" in
    --list-ports) LIST_PORTS=1; shift;;
    --help|-h)
      cat <<EOF
Usage:
  $0 [--list-ports] ensure
  $0 attach-if <vale|netgraph> <logical> <ifname> [a|h|exclusive|shared]
  $0 detach-if <vale|netgraph> <logical> <ifname>

Options:
  --list-ports   Avec 'ensure', affiche la liste des ports (VALE) / hooks (Netgraph).
EOF
      exit 0
      ;;
    *) err "unknown option: $1";;
  case_esac_dummy
  esac
done

# --- tools required ---
need awk
VALECTL="valectl"      # FreeBSD
need "$VALECTL"
need ngctl

# --- helpers: parse networks.yaml (name + backend) ---
list_networks(){
  awk '
    $1=="networks:" {in=1; next}
    in && $1=="-" {n=""; b=""}
    in && $1=="name:" {n=$2}
    in && $1=="backend:" {b=$2; print n, b}
  ' "$NETWORKS_YAML"
}

# -------- VALE presence (read-only) --------
vale_ports_for_switch(){
  sw="$1"  # ex: vale-mgmt
  $VALECTL 2>/dev/null | awk -F: -v SW="$sw" '($1==SW){print $2}'
}

VALE_ANCHOR_PREFIX="${VALE_ANCHOR_PREFIX:-v_}"
VALE_ANCHOR_SUFFIX="${VALE_ANCHOR_SUFFIX:-_anchor}"

vale_is_anchor(){
  sw="$1"       # ex: vale-mgmt
  logical="$2"  # ex: mgmt
  port="$3"
  [ "$port" = "${VALE_ANCHOR_PREFIX}${sw}${VALE_ANCHOR_SUFFIX}" ] && return 0
  [ "$port" = "${VALE_ANCHOR_PREFIX}${logical}${VALE_ANCHOR_SUFFIX}" ] && return 0
  printf '%s' "$port" | grep -qi 'anchor' && return 0
  return 1
}

vale_switch_state(){
  logical="$1"      # ex: mgmt
  sw="vale-${logical}"
  ports="$(vale_ports_for_switch "$sw" || true)"
  if [ -z "$ports" ]; then
    echo "MISSING ${sw} not found (no ports attached)"
    return 0
  fi
  non_anchor_count="$(echo "$ports" | awk -v SW="$sw" -v L="$logical" -v pre="$VALE_ANCHOR_PREFIX" -v suf="$VALE_ANCHOR_SUFFIX" '
    BEGIN{c=0}
    {
      p=$0
      if (p==pre SW suf || p==pre L suf) next
      if (tolower(p) ~ /anchor/) next
      c++
    }
    END{print c}
  ')"
  if [ "$non_anchor_count" -ge 1 ]; then
    echo "OK ${sw} present (ports: ${non_anchor_count} non-anchor + anchors possible)"
  else
    echo "EMPTY ${sw} present with anchor(s) only"
  fi
}

vale_print_ports(){
  logical="$1"; sw="vale-${logical}"
  ports="$(vale_ports_for_switch "$sw" || true)"
  [ -z "$ports" ] && { echo "    ports: -"; return; }
  non=""; anc=""
  # shellcheck disable=SC2162
  while read p; do
    [ -z "$p" ] && continue
    if vale_is_anchor "$sw" "$logical" "$p"; then
      anc="${anc}${anc:+,}${p}"
    else
      non="${non}${non:+,}${p}"
    fi
  done <<EOF
$ports
EOF
  [ -n "$non" ] && echo "    ports:   $non" || echo "    ports:   -"
  [ -n "$anc" ] && echo "    anchors: $anc"
}

# -------- Netgraph presence (read-only) --------
ng_switch_exists(){
  sw="$1"
  ngctl list -l | awk -v SW="$sw" '($2==SW && $3=="bridge"){ok=1} END{exit(ok?0:1)}'
}
ng_switch_has_links(){
  sw="$1"
  ngctl show -n "${sw}:" 2>/dev/null | awk '
    /^hooks:/ {in=1; next}
    in && /^[[:space:]]*link[0-9]+:/ {cnt++}
    END{exit(cnt>0?0:1)}
  '
}
ng_list_hooks(){
  sw="$1"
  ngctl show -n "${sw}:" 2>/dev/null | awk '
    /^hooks:/ {in=1; next}
    in && /^[[:space:]]*link[0-9]+:/ {
      # Ex: "  link2: ngeth0: ether"
      line=$0
      sub(/^[ \t]+/,"",line)
      print "    " line
    }
  '
}

# -------- ensure (read-only reporting) --------
ensure(){
  printf "%-18s %-10s %-12s %s\n" "NETWORK(LOGICAL)" "BACKEND" "STATE" "DETAILS"
  list_networks | while read -r n b; do
    [ -z "$n" ] && continue
    case "$b" in
      vale)
        state_line="$(vale_switch_state "$n")"
        state="$(printf '%s' "$state_line" | awk '{print $1}')"
        details="$(printf '%s' "$state_line" | cut -d' ' -f2-)"
        printf "%-18s %-10s %-12s %s\n" "$n" "vale" "$state" "$details"
        if [ $LIST_PORTS -eq 1 ]; then
          vale_print_ports "$n"
        fi
        ;;
      netgraph)
        sw="sw-${n}"
        if ng_switch_exists "$sw"; then
          if ng_switch_has_links "$sw"; then
            printf "%-18s %-10s %-12s %s\n" "$n" "netgraph" "OK"    "$sw present with link(s)"
          else
            printf "%-18s %-10s %-12s %s\n" "$n" "netgraph" "EMPTY" "$sw present but no linkN hooks"
          fi
          if [ $LIST_PORTS -eq 1 ]; then
            ng_list_hooks "$sw" || true
          fi
        else
          printf "%-18s %-10s %-12s %s\n" "$n" "netgraph" "MISSING" "$sw node not found"
        fi
        ;;
      *)
        printf "%-18s %-10s %-12s %s\n" "$n" "$b" "UNKNOWN" "backend unsupported"
        ;;
    esac
  done
  echo "NOTE: ensure is read-only. Use provisioning/fix modules to create or wire missing/empty switches."
}

# -------- attach (no auto-create) --------
attach_if(){
  b="$1"; n="$2"; ifn="$3"; mode="${4:-${VALE_ATTACH_MODE:-h}}"
  [ -n "$b" ] && [ -n "$n" ] && [ -n "$ifn" ] || err "attach-if <backend> <logical> <ifname> [a|h|exclusive|shared]"

  case "$b" in
    vale)
      vsw="vale-${n}"
      ports="$(vale_ports_for_switch "$vsw" || true)"
      [ -n "$ports" ] || err "VALE switch $vsw missing (no ports). Create it with your provisioning module."
      ifconfig "$ifn" >/dev/null 2>&1 || err "interface $ifn not found (create it first)"
      case "$mode" in
        a|exclusive) opt="-a" ;;
        h|shared|"" ) opt="-h" ;;
        *) err "invalid mode for VALE (use a|h|exclusive|shared)";;
      esac
      $VALECTL $opt "${vsw}:${ifn}" >/dev/null
      info "attached $ifn to $vsw with mode ${opt}"
      ;;
    netgraph)
      sw="sw-${n}"
      ng_switch_exists "$sw" || err "netgraph bridge $sw missing. Create it with your provisioning module."
      ifconfig "$ifn" >/dev/null 2>&1 || err "interface $ifn not found (create it first)"
      lnk="link2"
      ngctl connect "${ifn}:" "${sw}:" ether "$lnk" >/dev/null 2>&1 || err "ngctl connect failed ($ifn -> $sw:$lnk)"
      info "connected $ifn to $sw ($lnk)"
      ;;
    *)
      err "unknown backend $b"
      ;;
  esac
}

# -------- detach (no destructive create/remove) --------
detach_if(){
  b="$1"; n="$2"; ifn="$3"
  [ -n "$b" ] && [ -n "$n" ] && [ -n "$ifn" ] || err "detach-if <backend> <logical> <ifname>"

  case "$b" in
    vale)
      vsw="vale-${n}"
      ports="$(vale_ports_for_switch "$vsw" || true)"
      if [ -n "$ports" ]; then
        $VALECTL -d "${vsw}:${ifn}" >/dev/null 2>&1 || warn "valectl -d failed (maybe not attached?)"
        info "detached $ifn from $vsw"
      else
        warn "$vsw not present; nothing to detach for $ifn"
      fi
      ;;
    netgraph)
      ngctl shutdown "${ifn}:" >/dev/null 2>&1 || warn "ngctl shutdown ${ifn}: failed (maybe not a netgraph iface?)"
      info "detached (shutdown) netgraph node $ifn"
      ;;
    *)
      err "unknown backend $b"
      ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  ensure) ensure ;;
  attach-if) attach_if "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  detach-if) detach_if "${1:-}" "${2:-}" "${3:-}" ;;
  *) echo "Usage: $0 [--list-ports] ensure | attach-if <backend> <logical> <if> [a|h] | detach-if <backend> <logical> <if>" >&2; exit 1 ;;
esac
