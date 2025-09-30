#!/bin/sh
# g-guest - access helpers (PF NAT + Netgraph attach + SSH)
# Usage (CLI):
#   lib/access.sh up [--backend netgraph|vale] [--switch LOGICAL] [--host-if IF]
#                    [--host4 CIDR] [--host6 CIDR] [--nat-enable true|false]
#                    [--wan-if IF|default] [--anchor NAME]
#   lib/access.sh down
#   lib/access.sh nat enable|disable [--wan-if IF|default] [--host-if IF] [--anchor NAME]
#   lib/access.sh ssh test [--host IP] [--user USER]
#   lib/access.sh ssh copy-key [--host IP] [--user USER] [--pubkey PATH]
#
set -eu

BASE_DIR="${BASE_DIR:-/usr/local/g-guest}"
CFG_DIR="${CFG_DIR:-${BASE_DIR}/config}"
ROUTER_YAML="${ROUTER_YAML:-${CFG_DIR}/router.yaml}"
SEG_BIN="${SEG_BIN:-${BASE_DIR}/bin/segments.sh}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need awk; need sed; need tr
warn(){ echo "WARN: $*" >&2; }
info(){ echo "INFO: $*"; }
err(){ echo "ERROR: $*" >&2; exit 1; }

_yaml_access_get(){ awk -v k="$1" '$1=="access:"{in=1;next} in&&$1==k":"{print $2;exit}' "$ROUTER_YAML"; }
_yaml_access_nat_get(){ awk -v K="$1" '$1=="access:"{in=1;next} in&&$1=="nat:"{inn=1;next} inn&&$1==K":"{print $2;exit}' "$ROUTER_YAML"; }
_yaml_access_ssh_get(){ awk -v K="$1" '$1=="access:"{in=1;next} in&&$1=="ssh:"{iss=1;next} iss&&$1==K":"{print $2;exit}' "$ROUTER_YAML"; }

kld_ng(){ kldload -nq ng_ether ng_bridge || true; }
ng_next_link(){ sw="$1"; n=2; while ngctl msg "${sw}:" getstats "link${n}" >/dev/null 2>&1; do n=$((n+1)); done; echo "link${n}"; }
ng_host_if_ensure(){
  ifn="$1"
  if ifconfig "$ifn" >/dev/null 2>&1; then echo "$ifn"; return 0; fi
  kld_ng
  ngctl mkpeer eiface ether ether >/dev/null
  ngeth="$(ngctl list | awk '$3=="eiface"{print $1}' | tail -1)"
  [ -n "$ngeth" ] || err "ng_eiface creation failed"
  ngctl name "${ngeth}:" "$ifn" >/dev/null
  ifconfig "$ngeth" name "$ifn" up >/dev/null
  echo "$ifn"
}
ng_switch_ensure(){
  sw="$1"
  if ngctl list -l | awk '{print $2}' | grep -qx "$sw"; then return 0; fi
  tmpif="$(ng_host_if_ensure "_gg_tmp_$$")"
  link="$(ng_next_link "$sw")"
  ngctl mkpeer "${tmpif}:" bridge ether "$link" >/dev/null
  ngctl name "${tmpif}:ether" "$sw" >/dev/null
  ngctl shutdown "${tmpif}:" >/dev/null
}
ng_attach_if_to_switch(){
  sw="$1"; ifn="$2"
  kld_ng
  ng_switch_ensure "$sw"
  ng_host_if_ensure "$ifn" >/dev/null
  lnk="$(ng_next_link "$sw")"
  ngctl connect "${ifn}:" "${sw}:" ether "$lnk" >/dev/null 2>&1 || true
}
ng_detach_if(){ ifn="$1"; ngctl shutdown "${ifn}:" >/dev/null 2>&1 || true; }

vale_switch_name(){ echo "vale-$1"; }
vale_switch_ensure(){ need vale-ctl; sw="$1"; vale-ctl -n "$sw" >/dev/null 2>&1 || true; }
vale_attach_host_if(){ sw="$1"; ifn="$2"; need vale-ctl; vale_switch_ensure "$sw"; vale-ctl -h "${sw}:${ifn}" >/dev/null; }
vale_detach_host_if(){ sw="$1"; ifn="$2"; need vale-ctl; vale-ctl -r "${sw}:${ifn}" >/dev/null 2>&1 || true; }

pf_enabled(){ pfctl -si 2>/dev/null | awk '/Status:/ {print $2}' | grep -qi Enabled; }
pf_root_has_anchor(){ anc="$1"; pfctl -sr | grep -q "anchor \"${anc}\""; }
pf_anchor_load_rules(){
  anc="$1"; wan="$2"; hostif="$3"
  pfctl -a "$anc" -f - <<EOF
nat on ${wan} from (${hostif}) -> (${wan})
pass in on ${hostif}
pass out on ${wan}
EOF
}
pf_nat_enable(){
  anc="$1"; wan_if="$2"; host_if="$3"
  need pfctl
  pf_enabled || { warn "PF disabled (pfctl -e)"; }
  pf_anchor_load_rules "$anc" "$wan_if" "$host_if"
  pf_root_has_anchor "$anc" || warn "Add anchor \"$anc\" in /etc/pf.conf and reload."
  info "NAT via anchor $anc (WAN=$wan_if IF=$host_if)"
}
pf_nat_disable(){ anc="$1"; need pfctl; pfctl -a "$anc" -Fr 2>/dev/null || true; pfctl -a "$anc" -Fn 2>/dev/null || true; }

detect_default_wan(){ route -n get -inet default 2>/dev/null | awk '/interface:/{print $2}' && return 0; route -n get -inet6 default 2>/dev/null | awk '/interface:/{print $2}' && return 0; return 1; }

access::up(){
  backend="${ACCESS_BACKEND:-}"; logical="${ACCESS_SWITCH:-}"; host_if="${ACCESS_HOST_IF:-}"
  host4="${ACCESS_HOST4:-}"; host6="${ACCESS_HOST6:-}"; nat_enable="${ACCESS_NAT_ENABLE:-}"
  wan_if="${ACCESS_WAN_IF:-}"; anchor="${ACCESS_ANCHOR:-}"

  [ -n "$backend" ] || backend="$(_yaml_access_get backend || true 2>/dev/null || echo "")"
  [ -n "$logical" ] || logical="$(_yaml_access_get switch || true 2>/dev/null || echo "")"
  [ -n "$host_if" ] || host_if="$(_yaml_access_get host_if || true 2>/dev/null || echo "")"
  [ -n "$host4" ]   || host4="$(_yaml_access_get host_ipv4 || true 2>/dev/null || echo "")"
  [ -n "$host6" ]   || host6="$(_yaml_access_get host_ipv6 || true 2>/dev/null || echo "")"
  [ -n "$nat_enable" ] || nat_enable="$(_yaml_access_nat_get enable || true 2>/dev/null || echo "")"
  [ -n "$wan_if" ]  || wan_if="$(_yaml_access_nat_get wan_if || true 2>/dev/null || echo "")"
  [ -n "$anchor" ]  || anchor="$(_yaml_access_nat_get anchor || true 2>/dev/null || echo "gguest_nat")"

  [ -n "$backend" ] && [ -n "$logical" ] && [ -n "$host_if" ] || err "access.* incomplete (backend|switch|host_if)"

  case "$backend" in
    netgraph)
      swname="sw-${logical}"
      ng_attach_if_to_switch "$swname" "$host_if"
      ;;
    vale)
      swname="vale-${logical}"
      vale_attach_host_if "$swname" "$host_if"
      warn "Attaching host IF to VALE may bypass host stack."
      ;;
    *) err "unknown backend: $backend" ;;
  esac

  [ -n "$host4" ] && ifconfig "$host_if" inet "$host4" up
  [ -n "$host6" ] && ifconfig "$host_if" inet6 "$host6" up

  if [ "${nat_enable}" = "true" ]; then
    [ -n "$wan_if" ] || wan_if="default"
    [ "$wan_if" = "default" ] && wan_if="$(detect_default_wan || echo "")"
    [ -n "$wan_if" ] && pf_nat_enable "$anchor" "$wan_if" "$host_if" || warn "WAN not detected; NAT skipped."
  fi
  echo "OK access up: backend=$backend switch=$logical if=$host_if"
}

access::down(){
  backend="$(_yaml_access_get backend || echo "")"
  logical="$(_yaml_access_get switch || echo "")"
  host_if="$(_yaml_access_get host_if || echo "")"
  anchor="$(_yaml_access_nat_get anchor || echo "gguest_nat")"
  [ -n "$backend" ] && [ -n "$logical" ] && [ -n "$host_if" ] || err "access.* incomplete"

  pf_nat_disable "$anchor" || true
  case "$backend" in
    netgraph) ng_detach_if "$host_if" ;;
    vale)     vale_detach_host_if "vale-${logical}" "$host_if" ;;
  esac
  ifconfig "$host_if" down || true
  echo "OK access down"
}

access::nat_enable(){
  anchor="${1:-$(_yaml_access_nat_get anchor || echo gguest_nat)}"
  wan_if="${2:-$(_yaml_access_nat_get wan_if || echo default)}"
  host_if="${3:-$(_yaml_access_get host_if || err "host_if missing")}"
  [ "$wan_if" = "default" ] && wan_if="$(detect_default_wan || err "WAN not detected")"
  pf_nat_enable "$anchor" "$wan_if" "$host_if"
}
access::nat_disable(){ anchor="${1:-$(_yaml_access_nat_get anchor || echo gguest_nat)}"; pf_nat_disable "$anchor"; }

access::ssh_test(){
  host="${1:-$(_yaml_access_ssh_get host || echo "")}"
  user="${2:-$(_yaml_access_ssh_get user || echo "")}"
  [ -n "$host" ] && [ -n "$user" ] || err "ssh.host/ssh.user missing"
  need ssh
  ssh -o BatchMode=yes -o ConnectTimeout=3 "${user}@${host}" true && echo "OK SSH" || { echo "SSH KO"; exit 1; }
}
access::ssh_copy_key(){
  host="${1:-$(_yaml_access_ssh_get host || echo "")}"
  user="${2:-$(_yaml_access_ssh_get user || echo "")}"
  pub="${3:-$(_yaml_access_ssh_get pubkey || echo "")}"
  [ -n "$host" ] && [ -n "$user" ] && [ -n "$pub" ] || err "ssh.host/ssh.user/ssh.pubkey required"
  [ -r "$pub" ] || err "pubkey not readable: $pub"
  need ssh
  key="$(cat "$pub")"
  ssh -o ConnectTimeout=5 "${user}@${host}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && (grep -qxF \"$key\" ~/.ssh/authorized_keys 2>/dev/null || echo \"$key\" >> ~/.ssh/authorized_keys) && chmod 600 ~/.ssh/authorized_keys"
  echo "OK key installed"
}

if [ "${0##*/}" = "access.sh" ]; then
  sub="${1:-}"; shift || true
  case "$sub" in
    up)
      while [ $# -gt 0 ]; do
        case "$1" in
          --backend) ACCESS_BACKEND="$2"; shift 2;;
          --switch)  ACCESS_SWITCH="$2"; shift 2;;
          --host-if) ACCESS_HOST_IF="$2"; shift 2;;
          --host4)   ACCESS_HOST4="$2"; shift 2;;
          --host6)   ACCESS_HOST6="$2"; shift 2;;
          --nat-enable) ACCESS_NAT_ENABLE="$2"; shift 2;;
          --wan-if)  ACCESS_WAN_IF="$2"; shift 2;;
          --anchor)  ACCESS_ANCHOR="$2"; shift 2;;
          *) break;;
        esac
      done
      access::up ;;
    down) access::down ;;
    nat)
      act="${1:-}"; shift || true
      case "$act" in
        enable) WAN=""; HOSTIF=""; ANC=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --wan-if) WAN="$2"; shift 2;;
              --host-if) HOSTIF="$2"; shift 2;;
              --anchor) ANC="$2"; shift 2;;
              *) break;;
            esac
          done
          [ -z "$ANC" ] && ANC="$(_yaml_access_nat_get anchor || echo gguest_nat)"
          [ -z "$WAN" ] && WAN="$(_yaml_access_nat_get wan_if || echo default)"
          [ -z "$HOSTIF" ] && HOSTIF="$(_yaml_access_get host_if || err "host_if missing")"
          [ "$WAN" = "default" ] && WAN="$(detect_default_wan || err "WAN not detected")"
          pf_nat_enable "$ANC" "$WAN" "$HOSTIF"
          ;;
        disable) ANC="$(_yaml_access_nat_get anchor || echo gguest_nat)"; pf_nat_disable "$ANC" ;;
        *) err "nat {enable|disable}" ;;
      esac
      ;;
    ssh)
      act="${1:-}"; shift || true
      case "$act" in
        test) access::ssh_test "${1:-}" "${2:-}" ;;
        copy-key) access::ssh_copy_key "${1:-}" "${2:-}" "${3:-}" ;;
        *) err "ssh {test|copy-key}" ;;
      esac
      ;;
    *) echo "Usage: $0 up|down|nat enable|nat disable|ssh test|ssh copy-key" >&2; exit 1 ;;
  esac
fi
