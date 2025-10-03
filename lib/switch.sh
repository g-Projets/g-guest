#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2025 g-Projets
#
# g-guest switchctl — Orchestrateur de switches & ports (VALE / Netgraph)
#
# Fonctions :
#   switch create <vale|netgraph> <logical> [--anchor|--no-anchor]
#   switch delete <vale|netgraph> <logical> [--force]
#   attach <vale|netgraph> <logical> --if IFNAME [--mode host|raw]   # VALE
#   detach <vale|netgraph> <logical> --if IFNAME [--keep-config]
#   ng-ifadd  <logical> [--name IFNAME] [--anchor] [--no-attach]
#   ng-ifdel  <logical> --if IFNAME [--keep-config]
#   ng-detach <logical> --if IFNAME [--keep-config]
#
# Nouvelles commandes (état / export) :
#   list [--json]                 # vue synthétique des switches déclarés
#   status [--json]               # alias de list
#   inspect <vale|netgraph> <logical> [--json]
#
# Synchronisation :
#   - MAJ config/networks.yaml (ajout/suppression d’IF dans le bon bloc)
#   - Journal Netgraph var/db/netgraph_links.csv (bridge;hook;if;timestamp)
#
set -eu

# --- Chemins/Contexte ---
BASE_DIR="${BASE_DIR:-/usr/local/g-guest}"
CFG_DIR="${CFG_DIR:-$BASE_DIR/config}"
VAR_DIR="${VAR_DIR:-$BASE_DIR/var}"
DB_DIR="${DB_DIR:-$VAR_DIR/db}"
LOG_DIR="${LOG_DIR:-$VAR_DIR/logs}"

NETWORKS_YAML="${NETWORKS_YAML:-$CFG_DIR/networks.yaml}"
NG_MAP_DB="${NG_MAP_DB:-$DB_DIR/netgraph_links.csv}"

mkdir -p "$DB_DIR" "$LOG_DIR"

# --- Helpers ---
have(){ command -v "$1" >/dev/null 2>&1; }
info(){ printf "INFO: %s\n" "$*" ; }
warn(){ printf "WARN: %s\n" "$*" >&2; }
err(){  printf "ERROR: %s\n" "$*" >&2; exit 1; }

json_escape(){ printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# --- Lecture YAML (déclaratif) ---
yaml_networks(){
  # imprime "logical backend" pour chaque bloc
  [ -r "$NETWORKS_YAML" ] || return 0
  awk '
    $1=="networks:"{in=1; next}
    in && $1=="-"{n=""; b=""}
    in && $1=="name:"{n=$2}
    in && $1=="backend:"{b=$2; if(n!=""&&b!=""){print n, b}}
  ' "$NETWORKS_YAML"
}

# --- VALE detect ---
VALECTL=""
detect_vale_ctl(){
  if [ -z "$VALECTL" ]; then
    if have valectl; then VALECTL="valectl"
    elif have vale-ctl; then VALECTL="vale-ctl"
    else VALECTL=""
    fi
  fi
}

# --- VALE runtime pairs (switch port) ---
vale_pairs(){
  detect_vale_ctl
  [ -n "$VALECTL" ] || return 1
  out="$("$VALECTL" 2>/dev/null || true)"
  printf "%s" "$out" | awk '
    {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^vale[^:[:space:]]*:[^[:space:]]+$/) {
          split($i, a, ":"); print a[1], a[2];
        }
      }
    }
  ' | sort -u
}

vale_switch_name(){ printf "vale-%s" "$1"; }

vale_switch_exists(){
  detect_vale_ctl; [ -n "$VALECTL" ] || return 1
  vsw="$1"
  vale_pairs | awk -v s="$vsw" '$1==s{f=1}END{exit(f?0:1)}'
}

# --- VALE switch create/delete ---
vale_switch_create(){
  logical="$1"; anchor="${2:-1}"
  detect_vale_ctl; [ -n "$VALECTL" ] || err "valectl/vale-ctl introuvable"
  vsw="$(vale_switch_name "$logical")"
  if vale_switch_exists "$vsw"; then
    info "VALE $vsw déjà présent"
    return 0
  fi
  if [ "$anchor" -eq 1 ]; then
    "$VALECTL" -n "${vsw}:anchor" >/dev/null
    info "VALE $vsw créé (port anchor)"
  else
    warn "Création VALE sans port anchor : le switch reste invisible tant qu’aucun port n’est attaché"
  fi
}

vale_switch_delete(){
  logical="$1"; force="${2:-0}"
  detect_vale_ctl; [ -n "$VALECTL" ] || err "valectl/vale-ctl introuvable"
  vsw="$(vale_switch_name "$logical")"
  if ! vale_switch_exists "$vsw"; then
    info "VALE $vsw inexistant"
    return 0
  fi
  ports="$(vale_pairs | awk -v s="$vsw" '$1==s{print $2}' | tr '\n' ' ')"
  set -- $ports
  if [ $# -eq 0 ]; then
    info "Pas de port sur $vsw (rien à supprimer)"
    return 0
  fi
  if [ $# -eq 1 ] && [ "${1:-}" = "anchor" ]; then
    "$VALECTL" -r "${vsw}:anchor" >/dev/null 2>&1 || true
    info "VALE $vsw anchor retiré"
    return 0
  fi
  [ "$force" -eq 1 ] || err "VALE $vsw non vide (ports: $ports) — utilisez --force"
  for p in $ports; do
    if [ "$p" = "anchor" ]; then
      "$VALECTL" -r "${vsw}:anchor" >/dev/null 2>&1 || true
    else
      "$VALECTL" -d "${vsw}:${p}" >/dev/null 2>&1 || true
    fi
  done
  info "VALE $vsw vidé"
}

# --- VALE attach/detach host/raw ---
vale_attach(){
  logical="$1"; ifn="$2"; mode="${3:-host}"
  detect_vale_ctl; [ -n "$VALECTL" ] || err "valectl/vale-ctl introuvable"
  vsw="$(vale_switch_name "$logical")"
  vale_switch_exists "$vsw" || warn "VALE $vsw sans port — l’attache le matérialisera"
  case "$mode" in
    host) "$VALECTL" -h "${vsw}:${ifn}" >/dev/null ;;
    raw)  "$VALECTL" -a "${vsw}:${ifn}" >/dev/null ;;
    *)    err "mode inconnu (host|raw)" ;;
  esac
  info "VALE attach: ${vsw}:${ifn} ($mode)"
}

vale_detach(){
  logical="$1"; ifn="$2"
  detect_vale_ctl; [ -n "$VALECTL" ] || err "valectl/vale-ctl introuvable"
  vsw="$(vale_switch_name "$logical")"
  "$VALECTL" -d "${vsw}:${ifn}" >/dev/null 2>&1 || true
  info "VALE detach: ${vsw}:${ifn}"
}

# --- Netgraph helpers ---
kld_ng(){ kldload -nq ng_ether ng_bridge || true; }
ngctl_has(){ have ngctl; }

ng_bridge_name(){ printf "sw-%s" "$1"; }

ng_list_l(){ ngctl_has || return 1; ngctl list -l 2>/dev/null || true; }

ng_bridge_exists(){
  br="$1"
  out="$(ng_list_l)"; [ -n "$out" ] || return 1
  printf "%s\n" "$out" | awk -v b="$br" '
    $0 ~ ("(^|[[:space:]])" b "([[:space:]]|$)") && $0 ~ /bridge/ {found=1}
    END{ exit(found?0:1) }'
}

ng_switch_create(){
  logical="$1"
  br="$(ng_bridge_name "$logical")"
  if ng_bridge_exists "$br"; then
    info "Netgraph $br déjà présent"
    return 0
  fi
  kld_ng
  ngctl mkpeer eiface ether ether >/dev/null
  ngeth="$(ngctl list -l | awk '$3=="eiface"{print $2}' | tail -1)"
  ngctl mkpeer "${ngeth}:" bridge ether link2 >/dev/null
  ngctl name "${ngeth}:ether" "$br" >/dev/null
  ngctl shutdown "${ngeth}:" >/dev/null 2>&1 || true
  info "Netgraph $br créé"
}

ng_next_link(){
  br="$1"; n=2
  while ngctl msg "${br}:" getstats "link${n}" >/dev/null 2>&1; do n=$((n+1)); done
  echo "link${n}"
}

ng_if_exists(){ ifconfig "$1" >/dev/null 2>&1; }

ng_eiface_create(){
  ifn="$1"
  kld_ng
  if ng_if_exists "$ifn"; then echo "$ifn"; return 0; fi
  ngctl mkpeer eiface ether ether >/dev/null
  ngeth="$(ngctl list -l | awk '$3=="eiface"{print $2}' | tail -1)"
  ngctl name "${ngeth}:" "$ifn" >/dev/null
  ifconfig "$ngeth" name "$ifn" up >/dev/null
  echo "$ifn"
}

ng_attach_if(){
  br="$1"; ifn="$2"
  hook="$(ng_next_link "$br")"
  ngctl connect "${ifn}:" "${br}:" ether "$hook" >/dev/null
  printf "%s\n" "$hook"
}

ng_link_peer_if(){
  br="$1"; hook="$2"
  peer="$(ngctl show -n "${br}:${hook}" 2>/dev/null | awk 'NR==1{print $2}')"
  [ -n "${peer:-}" ] || { echo ""; return 0; }
  ng_list_l | awk -v p="$peer" 'index($0,p)>0 && $0 ~ /eiface/ {print $1;exit}'
}

ng_scan_links(){
  br="$1"; n=2
  while ngctl msg "${br}:" getstats "link${n}" >/dev/null 2>&1; do
    echo "link${n} $(ng_link_peer_if "$br" "link${n}")"
    n=$((n+1))
  done
}

ng_find_hook_for_if(){ br="$1"; ifn="$2"; ng_scan_links "$br" | awk -v I="$ifn" '$2==I{print $1; exit}'; }

# --- Mapping DB Netgraph ---
ng_map_record_attach(){ printf "%s;%s;%s;%s\n" "$1" "$2" "$3" "$(date -u +%FT%TZ)" >> "$NG_MAP_DB"; }
ng_map_lookup_hook(){
  br="$1"; ifn="$2"
  [ -r "$NG_MAP_DB" ] || return 1
  awk -v B="$br" -v I="$ifn" -F';' '
    {lines[NR]=$0}
    END{
      for (n=NR; n>=1; n--){
        split(lines[n], f, ";")
        if (f[1]==B && f[3]==I) {
          if (f[4]=="DETACHED") { print ""; exit }
          else { print f[2]; exit }
        }
      }
    }' "$NG_MAP_DB"
}
ng_map_mark_detached(){ printf "%s;%s;%s;DETACHED;%s\n" "$1" "$2" "$3" "$(date -u +%FT%TZ)" >> "$NG_MAP_DB"; }

# --- YAML synchronisation ---
yaml_ensure_network_block(){
  logical="$1"; backend="$2"; y="$NETWORKS_YAML"
  [ -r "$y" ] || { warn "$y introuvable — création minimale"; mkdir -p "$(dirname "$y")"; printf "networks:\n" > "$y"; }
  if awk -v L="$logical" -v B="$backend" '
      $1=="networks:"{in=1; next}
      in && $1=="-" {blk=0; ng=0; va=0}
      in && $1=="name:" && $2==L {blk=1}
      blk && $1=="backend:" && $2==B {found=1}
      END{exit(found?0:1)}
    ' "$y"; then return 0; fi
  {
    echo "- name: $logical"
    echo "  backend: $backend"
    echo "  interfaces: []"
  } >> "$y"
}

yaml_list_key_for_backend(){
  logical="$1"; backend="$2"; y="$NETWORKS_YAML"
  if awk -v L="$logical" -v B="$backend" '
      $1=="networks:"{in=1; next}
      in && $1=="-" {blk=0; ng=0}
      in && $1=="name:" && $2==L {blk=1}
      blk && $1=="backend:" && $2==B {ng=1}
      blk && ng && $1=="interfaces:"{print "interfaces"; exit}
      blk && ng && $1=="ports:"{print "ports"; exit}
    ' "$y"; then :; else echo "interfaces"; fi
}

yaml_if_present(){
  logical="$1"; backend="$2"; ifn="$3"; y="$NETWORKS_YAML"
  awk -v L="$logical" -v B="$backend" -v IF="$ifn" '
    $1=="networks:"{in=1; next}
    in && $1=="-" {blk=0; ng=0}
    in && $1=="name:" && $2==L {blk=1}
    blk && $1=="backend:" && $2==B {ng=1}
    blk && ng && $1=="-" && $2=="if:" && $3==IF {f=1}
    END{exit(f?0:1)}
  ' "$y"
}

yaml_add_if(){
  logical="$1"; backend="$2"; ifn="$3"; y="$NETWORKS_YAML"
  yaml_ensure_network_block "$logical" "$backend"
  yaml_if_present "$logical" "$backend" "$ifn" && return 0
  key="$(yaml_list_key_for_backend "$logical" "$backend")"
  tmp="$(mktemp)"
  awk -v L="$logical" -v B="$backend" -v K="$key" -v IF="$ifn" '
    BEGIN{in=0; blk=0; ok=0; done=0}
    $1=="networks:"{in=1}
    in && $1=="-" { if (blk && ok && !done) { print "    - if: " IF; done=1 } blk=0; ok=0 }
    in && $1=="name:" && $2==L {blk=1}
    blk && $1=="backend:" && $2==B {ok=1}
    {print}
    blk && ok && $1==K":" { list=1 }
    END{ if (blk && ok && !done) { if (!list) { print "  " K ":" } print "    - if: " IF } }
  ' "$y" > "$tmp" && mv "$tmp" "$y"
}

yaml_remove_if(){
  logical="$1"; backend="$2"; ifn="$3"; y="$NETWORKS_YAML"
  [ -r "$y" ] || return 0
  tmp="$(mktemp)"
  awk -v L="$logical" -v B="$backend" -v IF="$ifn" '
    BEGIN{in=0; blk=0; ok=0}
    $1=="networks:"{in=1}
    in && $1=="-" {blk=0; ok=0}
    in && $1=="name:" && $2==L {blk=1}
    blk && $1=="backend:" && $2==B {ok=1}
    blk && ok && $1=="-" && $2=="if:" && $3==IF { next }
    { print }
  ' "$y" > "$tmp" && mv "$tmp" "$y"
}

# --- Netgraph ifname auto ---
ng_autoname(){
  logical="$1"; anchor="${2:-0}"
  if [ "$anchor" -eq 1 ]; then printf "n_%s_anchor\n" "$logical"; return; fi
  base="n_${logical}_p"; i=1
  while ifconfig "${base}$(printf '%02d' "$i")" >/dev/null 2>&1; do i=$((i+1)); done
  printf "%s%02d\n" "$base" "$i"
}

# --- Commandes existantes (création, attache, etc.) ---

cmd_switch_create(){
  [ $# -ge 2 ] || err "Usage: $0 switch create <vale|netgraph> <logical> [--anchor|--no-anchor]"
  backend="$1"; logical="$2"; shift 2
  anchor=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-anchor) anchor=0; shift ;;
      --anchor)    anchor=1; shift ;;
      *) break ;;
    esac
  done
  case "$backend" in
    vale)     vale_switch_create "$logical" "$anchor"; yaml_ensure_network_block "$logical" "vale" ;;
    netgraph) ng_switch_create "$logical"; yaml_ensure_network_block "$logical" "netgraph" ;;
    *) err "backend inconnu (vale|netgraph)" ;;
  esac
}

cmd_switch_delete(){
  [ $# -ge 2 ] || err "Usage: $0 switch delete <vale|netgraph> <logical> [--force]"
  backend="$1"; logical="$2"; shift 2
  force=0; [ "${1:-}" = "--force" ] && { force=1; shift; }
  case "$backend" in
    vale) vale_switch_delete "$logical" "$force" ;;
    netgraph)
      br="$(ng_bridge_name "$logical")"
      if ! ng_bridge_exists "$br"; then info "Netgraph $br inexistant"; return 0; fi
      links="$(ng_scan_links "$br" | awk '{print $1}' | wc -l | awk '{print $1}')"
      [ "$links" -gt 0 ] && [ "$force" -ne 1 ] && err "Netgraph $br a ${links} lien(s) — utilisez --force"
      [ "$links" -gt 0 ] && ng_scan_links "$br" | while read -r hk _; do ngctl disconnect "${br}:" "$hk" >/dev/null 2>&1 || true; done
      ngctl shutdown "${br}:" >/dev/null 2>&1 || true
      info "Netgraph $br supprimé"
      ;;
    *) err "backend inconnu (vale|netgraph)" ;;
  esac
}

cmd_attach(){
  [ $# -ge 2 ] || err "Usage: $0 attach <vale|netgraph> <logical> --if IFNAME [--mode host|raw]"
  backend="$1"; logical="$2"; shift 2
  ifn=""; mode="host"
  while [ $# -gt 0 ]; do
    case "$1" in
      --if) ifn="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      *) break ;;
    esac
  done
  [ -n "$ifn" ] || err "--if requis"
  case "$backend" in
    vale) vale_attach "$logical" "$ifn" "$mode"; yaml_add_if "$logical" "vale" "$ifn" ;;
    netgraph)
      br="$(ng_bridge_name "$logical")"; ng_bridge_exists "$br" || err "bridge $br introuvable"
      hk="$(ng_attach_if "$br" "$ifn")" || err "échec attache $ifn -> $br"
      ng_map_record_attach "$br" "$hk" "$ifn"; yaml_add_if "$logical" "netgraph" "$ifn"
      ;;
    *) err "backend inconnu (vale|netgraph)" ;;
  esac
}

cmd_detach(){
  [ $# -ge 2 ] || err "Usage: $0 detach <vale|netgraph> <logical> --if IFNAME [--keep-config]"
  backend="$1"; logical="$2"; shift 2
  ifn=""; keep=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --if) ifn="${2:-}"; shift 2 ;;
      --keep-config) keep=1; shift ;;
      *) break ;;
    esac
  done
  [ -n "$ifn" ] || err "--if requis"
  case "$backend" in
    vale) vale_detach "$logical" "$ifn"; [ $keep -eq 1 ] || yaml_remove_if "$logical" "vale" "$ifn" ;;
    netgraph) cmd_ng_detach "$logical" --if "$ifn" $( [ $keep -eq 1 ] && echo --keep-config || true ) ;;
    *) err "backend inconnu (vale|netgraph)" ;;
  esac
}

cmd_ng_ifadd(){
  logical=""; ifname=""; anchor=0; no_attach=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --name|-n) ifname="${2:-}"; shift 2 ;;
      --anchor)  anchor=1; shift ;;
      --no-attach) no_attach=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: $0 ng-ifadd <logical> [--name IFNAME] [--anchor] [--no-attach]
Crée une eiface Netgraph (auto: n_<logical>_pNN ou --anchor), l'attache à sw-<logical>
(sauf --no-attach), MAJ networks.yaml & mapping.
EOF
        return 0;;
      *) logical="$1"; shift ;;
    esac
  done
  [ -n "$logical" ] || err "logical manquant"
  br="$(ng_bridge_name "$logical")"; ng_bridge_exists "$br" || err "bridge $br introuvable"
  [ -n "$ifname" ] || ifname="$(ng_autoname "$logical" "$anchor")"
  ng_eiface_create "$ifname" >/dev/null || err "échec création eiface $ifname"
  if [ "$no_attach" -eq 0 ]; then
    hk="$(ng_attach_if "$br" "$ifname")" || err "échec attache $ifname -> $br"
    ng_map_record_attach "$br" "$hk" "$ifname"; info "Netgraph: $ifname attaché sur $br:$hk"
  else
    info "Netgraph: $ifname créé (non attaché)"
  fi
  yaml_add_if "$logical" "netgraph" "$ifname"
}

ng_detach_once(){
  logical="$1"; ifn="$2"
  br="$(ng_bridge_name "$logical")"; ng_bridge_exists "$br" || err "bridge $br introuvable"
  hook="$(ng_map_lookup_hook "$br" "$ifn" || true)"; [ -n "${hook:-}" ] || hook="$(ng_find_hook_for_if "$br" "$ifn" || true)"
  [ -n "${hook:-}" ] || err "aucun hook trouvé pour $ifn sur $br"
  ngctl disconnect "${br}:" "$hook" >/dev/null 2>&1 || err "échec ngctl disconnect ${br}: $hook"
  ng_map_mark_detached "$br" "$hook" "$ifn"; info "Netgraph: détaché $ifn de $br:$hook"
}

cmd_ng_detach(){
  logical=""; ifn=""; keep=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --if) ifn="${2:-}"; shift 2 ;;
      --keep-config) keep=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: $0 ng-detach <logical> --if IFNAME [--keep-config]
Détache IFNAME de sw-<logical> (Netgraph) via mapping CSV ou probing live.
EOF
        return 0;;
      *) logical="$1"; shift ;;
    esac
  done
  [ -n "$logical" ] && [ -n "$ifn" ] || err "arguments manquants"
  ng_detach_once "$logical" "$ifn"
  [ $keep -eq 1 ] || yaml_remove_if "$logical" "netgraph" "$ifn"
}

cmd_ng_ifdel(){
  logical=""; ifn=""; keep=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --if) ifn="${2:-}"; shift 2 ;;
      --keep-config) keep=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: $0 ng-ifdel <logical> --if IFNAME [--keep-config]
Détache IFNAME puis détruit l'eiface (ngctl shutdown IFNAME:).
EOF
        return 0;;
      *) logical="$1"; shift ;;
    esac
  done
  [ -n "$logical" ] && [ -n "$ifn" ] || err "arguments manquants"
  ng_detach_once "$logical" "$ifn" || true
  ngctl shutdown "${ifn}:" >/dev/null 2>&1 || true
  [ $keep -eq 1 ] || yaml_remove_if "$logical" "netgraph" "$ifn"
  info "Netgraph: interface $ifn supprimée"
}

# --- État / Export ---

switch_state_vale(){
  # args: logical ; imprime lignes clefs pour usage interne
  logical="$1"; vsw="$(vale_switch_name "$logical")"
  detect_vale_ctl
  if [ -z "$VALECTL" ]; then
    echo "backend=vale name=$vsw state=UNKNOWN anchor=0 ports="
    return 0
  fi
  if ! vale_switch_exists "$vsw"; then
    echo "backend=vale name=$vsw state=MISSING anchor=0 ports="
    return 0
  fi
  ports="$(vale_pairs | awk -v s="$vsw" '$1==s{print $2}')"
  anchor=0; pcount=0
  printf "%s\n" "$ports" | grep -qx "anchor" && anchor=1
  pcount=$(printf "%s\n" "$ports" | awk '$1!="anchor"{c++}END{print c+0}')
  state="EMPTY"; [ "$pcount" -gt 0 ] && state="OK"
  echo "backend=vale name=$vsw state=$state anchor=$anchor ports=$(printf "%s" "$ports" | tr '\n' ',' | sed 's/,$//')"
}

switch_state_netgraph(){
  logical="$1"; br="$(ng_bridge_name "$logical")"
  if ! ngctl_has; then
    echo "backend=netgraph name=$br state=UNKNOWN hooks="
    return 0
  fi
  if ! ng_bridge_exists "$br"; then
    echo "backend=netgraph name=$br state=MISSING hooks="
    return 0
  fi
  lines="$(ng_scan_links "$br")"
  count=$(printf "%s\n" "$lines" | awk 'NF>0{c++}END{print c+0}')
  state="EMPTY"; [ "$count" -gt 0 ] && state="OK"
  hooks="$(printf "%s\n" "$lines" | awk '{print $1"="($2==""?"-":$2)}' | tr '\n' ',' | sed 's/,$//')"
  echo "backend=netgraph name=$br state=$state hooks=$hooks"
}

print_status_text(){
  logical="$1" backend="$2"
  case "$backend" in
    vale)
      eval "$(switch_state_vale "$logical" | sed 's/\([^ =]\+\)=/\1="/g;s/$/"/')"
      printf "%-10s %-9s %-20s %-8s anchor=%s\n" "$logical" "$backend" "$name" "$state" "$anchor"
      if [ -n "${ports:-}" ]; then
        IFS=,; for p in $ports; do [ -n "$p" ] && printf "    port: %s\n" "$p"; done; IFS=' '
      fi
      ;;
    netgraph)
      eval "$(switch_state_netgraph "$logical" | sed 's/\([^ =]\+\)=/\1="/g;s/$/"/')"
      printf "%-10s %-9s %-20s %-8s\n" "$logical" "$backend" "$name" "$state"
      if [ -n "${hooks:-}" ]; then
        IFS=,; for h in $hooks; do [ -n "$h" ] && printf "    %s\n" "$h"; done; IFS=' '
      fi
      ;;
  esac
}

print_switch_json(){
  logical="$1" backend="$2"
  if [ "$backend" = "vale" ]; then
    eval "$(switch_state_vale "$logical" | sed 's/\([^ =]\+\)=/\1="/g;s/$/"/')"
    printf '{'
    printf '"logical":"%s","backend":"vale","name":"%s","state":"%s","anchor":%s,' "$(json_escape "$logical")" "$(json_escape "$name")" "$(json_escape "$state")" "$anchor"
    printf '"ports":['
    first=1
    IFS=,; for p in ${ports:-}; do
      [ -z "$p" ] && continue
      [ $first -eq 1 ] || printf ','
      printf '"%s"' "$(json_escape "$p")"
      first=0
    done
    IFS=' '
    printf ']'
    printf '}'
  else
    eval "$(switch_state_netgraph "$logical" | sed 's/\([^ =]\+\)=/\1="/g;s/$/"/')"
    printf '{'
    printf '"logical":"%s","backend":"netgraph","name":"%s","state":"%s",' "$(json_escape "$logical")" "$(json_escape "$name")" "$(json_escape "$state")"
    printf '"links":['
    first=1
    IFS=,; for kv in ${hooks:-}; do
      [ -z "$kv" ] && continue
      hook="${kv%%=*}"; ifn="${kv#*=}"; [ "$ifn" = "-" ] && ifn=""
      [ $first -eq 1 ] || printf ','
      printf '{"hook":"%s","if":"%s"}' "$(json_escape "$hook")" "$(json_escape "$ifn")"
      first=0
    done
    IFS=' '
    printf ']'
    printf '}'
  fi
}

cmd_list(){
  json=0; [ "${1:-}" = "--json" ] && { json=1; shift; }
  if [ $json -eq 1 ]; then
    printf '{ "switches": ['
  else
    printf "%-10s %-9s %-20s %-8s\n" "LOGICAL" "BACKEND" "NAME" "STATE"
  fi
  first=1
  yaml_networks | while read -r logical backend; do
    [ -n "$logical" ] || continue
    if [ $json -eq 1 ]; then
      [ $first -eq 1 ] || printf ','
      print_switch_json "$logical" "$backend"
      first=0
    else
      print_status_text "$logical" "$backend"
    fi
  done
  if [ $json -eq 1 ]; then
    printf ']}\n'
  fi
}

cmd_inspect(){
  [ $# -ge 2 ] || err "Usage: $0 inspect <vale|netgraph> <logical> [--json]"
  backend="$1"; logical="$2"; shift 2
  json=0; [ "${1:-}" = "--json" ] && { json=1; shift; }
  if [ $json -eq 1 ]; then
    print_switch_json "$logical" "$backend"; printf "\n"
  else
    print_status_text "$logical" "$backend"
  fi
}

# --- Dispatcher ---
usage(){
  cat <<EOF
Usage:
  $0 switch create <vale|netgraph> <logical> [--anchor|--no-anchor]
  $0 switch delete <vale|netgraph> <logical> [--force]
  $0 attach <vale|netgraph> <logical> --if IFNAME [--mode host|raw]
  $0 detach <vale|netgraph> <logical> --if IFNAME [--keep-config]
  $0 ng-ifadd  <logical> [--name IFNAME] [--anchor] [--no-attach]
  $0 ng-detach <logical> --if IFNAME [--keep-config]
  $0 ng-ifdel  <logical> --if IFNAME [--keep-config]
  $0 list [--json]
  $0 status [--json]        # alias de list
  $0 inspect <vale|netgraph> <logical> [--json]
EOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  switch)
    sub="${1:-}"; shift || true
    case "$sub" in
      create) cmd_switch_create "$@" ;;
      delete) cmd_switch_delete "$@" ;;
      *) usage; err "sous-commande switch inconnue" ;;
    esac
    ;;
  attach)     cmd_attach "$@" ;;
  detach)     cmd_detach "$@" ;;
  ng-ifadd)   cmd_ng_ifadd "$@" ;;
  ng-detach)  cmd_ng_detach "$@" ;;
  ng-ifdel)   cmd_ng_ifdel "$@" ;;
  list)       cmd_list "$@" ;;
  status)     cmd_list "$@" ;;
  inspect)    cmd_inspect "$@" ;;
  -h|--help|"") usage ;;
  *) usage; err "commande inconnue: $cmd" ;;
esac
