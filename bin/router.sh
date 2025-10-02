#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2025 g-Projets

# g-guest - router assistant (BSDRP + segments)
# Lecture seule pour les segments (pas de création auto).
# Commandes:
#   plan [--json]       # vérifie les segments et affiche (texte ou JSON) + mapping NIC
#   bhyve-args          # imprime les -s ... à coller pour bhyve (sans exécuter)
#   ensure              # délègue à segments.sh (lecture seule)

set -eu

BASE_DIR="${BASE_DIR:-/usr/local/g-guest}"
CFG_DIR="${CFG_DIR:-$BASE_DIR/config}"
ROUTER_YAML="${ROUTER_YAML:-$CFG_DIR/router.yaml}"
SEGMENTS_SH="${SEGMENTS_SH:-$BASE_DIR/bin/segments.sh}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
info(){ echo "INFO: $*"; }
warn(){ echo "WARN: $*" >&2; }
err(){ echo "ERROR: $*" >&2; exit 1; }

need awk
need ngctl
need valectl
need date

VALECTL="valectl"

# ---------------------------
# Parse router.yaml (minimal)
# ---------------------------
yaml_router_name(){ awk '$1=="name:"{print $2}' "$ROUTER_YAML"; }

yaml_segments(){
  # attend:
  # segments:
  #   - name: mgmt
  #     backend: vale
  #     model: virtio-net
  #     mac: "58:9c:fc:00:01:01"
  awk '
    $1=="segments:" {in=1; next}
    in && $1=="-"{if(n!=""&&b!=""){print n,b,m,mac}; n=""; b=""; m="virtio-net"; mac=""}
    in && $1=="name:"{n=$2}
    in && $1=="backend:"{b=$2}
    in && $1=="model:"{m=$2}
    in && $1=="mac:"{mac=$2}
    END{ if(in && n!="" && b!=""){print n,b,m,mac} }
  ' "$ROUTER_YAML"
}

# ---------------------------
# VALE (lecture seule)
# ---------------------------
VALE_ANCHOR_PREFIX="${VALE_ANCHOR_PREFIX:-v_}"
VALE_ANCHOR_SUFFIX="${VALE_ANCHOR_SUFFIX:-_anchor}"

vale_ports_for_switch(){
  sw="$1"
  $VALECTL 2>/dev/null | awk -F: -v SW="$sw" '($1==SW){print $2}'
}

vale_is_anchor(){
  sw="$1"; logical="$2"; port="$3"
  [ "$port" = "${VALE_ANCHOR_PREFIX}${sw}${VALE_ANCHOR_SUFFIX}" ] && return 0
  [ "$port" = "${VALE_ANCHOR_PREFIX}${logical}${VALE_ANCHOR_SUFFIX}" ] && return 0
  printf '%s' "$port" | grep -qi 'anchor' && return 0
  return 1
}

vale_state(){
  logical="$1"; sw="vale-${logical}"
  ports="$(vale_ports_for_switch "$sw" || true)"
  if [ -z "$ports" ]; then
    echo "MISSING ${sw} not found (no ports attached)"
    return
  fi
  non_anchors=$(echo "$ports" | awk -v SW="$sw" -v L="$logical" -v pre="$VALE_ANCHOR_PREFIX" -v suf="$VALE_ANCHOR_SUFFIX" '
    BEGIN{c=0}
    {
      p=$0
      if (p==pre SW suf || p==pre L suf) next
      if (tolower(p) ~ /anchor/) next
      c++
    }
    END{print c}
  ')
  if [ "$non_anchors" -ge 1 ]; then
    echo "OK ${sw} with ${non_anchors} non-anchor port(s)"
  else
    echo "EMPTY ${sw} anchors only"
  fi
}

# ---------------------------
# Netgraph (lecture seule)
# ---------------------------
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

ng_next_link(){
  sw="$1"
  n=2
  while ngctl msg "${sw}:" getstats "link${n}" >/dev/null 2>&1; do n=$((n+1)); done
  echo "link${n}"
}

# version lisible + suggestion peerhook
ng_state_and_peerhook(){
  logical="$1"; sw="sw-${logical}"
  if ng_switch_exists "$sw"; then
    peer="$(ng_next_link "$sw")"
    if ng_switch_has_links "$sw"; then
      echo "OK ${sw} (next=${peer})"
    else
      echo "EMPTY ${sw} (next=${peer})"
    fi
  else
    echo "MISSING ${sw} not found"
  fi
}

# ---------------------------
# Génération MAC + portname
# ---------------------------
mac_from_name(){
  nm="$1"
  hex=$(printf "%s" "$nm" | md5 | tr -d '\n' | cut -c1-6)
  a=$(echo "$hex" | cut -c1-2)
  b=$(echo "$hex" | cut -c3-4)
  c=$(echo "$hex" | cut -c5-6)
  printf "58:9c:fc:%s:%s:%s\n" "$a" "$b" "$c"
}

portname_from_router_seg(){
  r="$1"; seg="$2"
  printf "g_%s_%s\n" "$r" "$seg" | tr -c '[:alnum:]_-' '_'
}

# ---------------------------
# Affichage plan (texte)
# ---------------------------
plan_text(){
  router="$(yaml_router_name)"
  [ -n "$router" ] || err "router.name manquant dans $ROUTER_YAML"

  printf "%-10s %-10s %-12s %-8s %-30s %s\n" "SEGMENT" "BACKEND" "STATE" "MODEL" "BHYVE-BACKEND" "MAC"
  idx=0
  yaml_segments | while read -r seg backend model mac; do
    [ -z "$seg" ] && continue
    [ -z "$model" ] && model="virtio-net"
    case "$backend" in
      vale)
        st_line="$(vale_state "$seg")"
        st="$(printf '%s' "$st_line" | awk '{print $1}')"
        vsw="vale-${seg}"
        port="$(portname_from_router_seg "$router" "$seg")"
        be="${vsw}:${port}"
        [ -z "$mac" ] && mac="$(mac_from_name "${router}_${seg}")"
        printf "%-10s %-10s %-12s %-8s %-30s %s\n" "$seg" "vale" "$st" "$model" "$be" "$mac"
        ;;
      netgraph)
        st_line="$(ng_state_and_peerhook "$seg")"
        st="$(printf '%s' "$st_line" | awk '{print $1}')"
        sw="sw-${seg}"
        case "$st" in
          OK|EMPTY) peer="$(printf '%s' "$st_line" | sed -n 's/.*(next=\([^)]*\)).*/\1/p')" ;;
          *)        peer="link?" ;;
        esac
        be="netgraph,path=${sw}:,peerhook=${peer}"
        [ -z "$mac" ] && mac="$(mac_from_name "${router}_${seg}")"
        printf "%-10s %-10s %-12s %-8s %-30s %s\n" "$seg" "netgraph" "$st" "$model" "$be" "$mac"
        ;;
      *)
        printf "%-10s %-10s %-12s %-8s %-30s %s\n" "$seg" "$backend" "UNKNOWN" "$model" "-" "-"
        ;;
    esac
    idx=$((idx+1))
  done
  echo
  echo "NOTE: aucun switch ou hook n'est créé par ce script. Corrige MISSING/EMPTY via tes modules de provisioning, puis relance 'plan'."
}

# ---------------------------
# Plan JSON
# ---------------------------
json_escape(){
  # échappe \ et " et transforme retours à la ligne
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/\n/\\n/g'
}

plan_json(){
  router="$(yaml_router_name)"
  [ -n "$router" ] || err "router.name manquant dans $ROUTER_YAML"

  ts="$(date -u +%FT%TZ)"
  echo "{"
  echo "  \"router\": \"$(json_escape "$router")\","
  echo "  \"generated_at\": \"${ts}\","
  echo "  \"segments\": ["

  idx=0
  out_first=1
  yaml_segments | while read -r seg backend model mac; do
    [ -z "$seg" ] && continue
    [ -z "$model" ] && model="virtio-net"
    [ -z "$mac" ] && mac="$(mac_from_name "${router}_${seg}")"

    be=""; sarg=""; state=""; details=""; peer=""

    case "$backend" in
      vale)
        st_line="$(vale_state "$seg")"
        state="$(printf '%s' "$st_line" | awk '{print $1}')"
        details="${st_line#${state} }"
        vsw="vale-${seg}"
        port="$(portname_from_router_seg "$router" "$seg")"
        be="${vsw}:${port}"
        if [ "$state" != "MISSING" ]; then
          bus=$((2 + (idx/8))); slot=$((idx % 8)); func=0
          sarg="-s ${bus}:${slot}:${func},${model},${be},mac=${mac}"
        fi
        ;;
      netgraph)
        st_line="$(ng_state_and_peerhook "$seg")"
        state="$(printf '%s' "$st_line" | awk '{print $1}')"
        details="${st_line#${state} }"
        sw="sw-${seg}"
        if [ "$state" = "OK" ] || [ "$state" = "EMPTY" ]; then
          peer="$(printf '%s' "$st_line" | sed -n 's/.*(next=\([^)]*\)).*/\1/p')"
          [ -z "$peer" ] && peer="$(ng_next_link "$sw")"
          be="netgraph,path=${sw}:,peerhook=${peer}"
          bus=$((2 + (idx/8))); slot=$((idx % 8)); func=0
          sarg="-s ${bus}:${slot}:${func},${model},${be},mac=${mac}"
        else
          be="netgraph,path=${sw}:,peerhook=?"
        fi
        ;;
      *)
        state="UNKNOWN"
        details="backend unsupported"
        ;;
    esac

    # impression JSON segment
    [ $out_first -eq 0 ] && echo "    ,"
    echo "    {"
    echo "      \"name\": \"$(json_escape "$seg")\","
    echo "      \"backend\": \"$(json_escape "$backend")\","
    echo "      \"state\": \"$(json_escape "$state")\","
    echo "      \"details\": \"$(json_escape "$details")\","
    echo "      \"model\": \"$(json_escape "$model")\","
    echo "      \"mac\": \"$(json_escape "$mac")\","
    echo "      \"backend_arg\": \"$(json_escape "$be")\","
    if [ -n "${sarg}" ]; then
      echo "      \"pci\": {\"bus\": ${bus}, \"slot\": ${slot}, \"func\": ${func}},"
      echo "      \"bhyve_arg\": \"$(json_escape "$sarg")\""
    else
      echo "      \"pci\": null,"
      echo "      \"bhyve_arg\": null"
    fi
    echo "    }"
    out_first=0
    idx=$((idx+1))
  done

  echo "  ]"
  echo "}"
}

# ---------------------------
# -s ... (sans exécuter)
# ---------------------------
bhyve_args(){
  router="$(yaml_router_name)"
  [ -n "$router" ] || err "router.name manquant dans $ROUTER_YAML"

  idx=0
  yaml_segments | while read -r seg backend model mac; do
    [ -z "$seg" ] && continue
    [ -z "$model" ] && model="virtio-net"
    case "$backend" in
      vale)
        st="$(vale_state "$seg" | awk '{print $1}')"
        [ "$st" = "MISSING" ] && { warn "VALE vale-${seg} MISSING → ignore"; idx=$((idx+1)); continue; }
        vsw="vale-${seg}"
        port="$(portname_from_router_seg "$router" "$seg")"
        be="${vsw}:${port}"
        ;;
      netgraph)
        st_line="$(ng_state_and_peerhook "$seg")"
        st="$(printf '%s' "$st_line" | awk '{print $1}')"
        [ "$st" = "MISSING" ] && { warn "netgraph sw-${seg} MISSING → ignore"; idx=$((idx+1)); continue; }
        peer="$(printf '%s' "$st_line" | sed -n 's/.*(next=\([^)]*\)).*/\1/p')"
        [ -z "$peer" ] && peer="link2"
        be="netgraph,path=sw-${seg}:,peerhook=${peer}"
        ;;
      *)
        warn "backend '$backend' non supporté → ignore"
        idx=$((idx+1)); continue
        ;;
    esac
    [ -z "$mac" ] && mac="$(mac_from_name "${router}_${seg}")"
    bus=$((2 + (idx/8))); slot=$((idx % 8)); func=0
    echo "-s ${bus}:${slot}:${func},${model},${be},mac=${mac}"
    idx=$((idx+1))
  done
}

# ---------------------------
# ensure → segments.sh
# ---------------------------
ensure_cmd(){
  if [ -x "$SEGMENTS_SH" ]; then
    exec "$SEGMENTS_SH" ensure
  else
    err "segments.sh introuvable ($SEGMENTS_SH)"
  fi
}

# ---------------------------
# Main
# ---------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  plan)
    if [ "${1:-}" = "--json" ]; then
      plan_json
    else
      plan_text
    fi
    ;;
  bhyve-args)  bhyve_args ;;
  ensure)      ensure_cmd ;;
  ""|help|-h|--help)
    cat <<EOF
Usage:
  $0 plan [--json]  # vérifie les segments (OK/EMPTY/MISSING) et propose le mapping NIC
  $0 bhyve-args     # imprime uniquement les arguments -s ... à coller pour bhyve
  $0 ensure         # délégué à segments.sh (lecture seule)

Notes:
  - Aucun switch/bridge n'est créé ou modifié par ce script.
  - Corrige MISSING/EMPTY via tes modules de provisioning, puis relance 'plan'/'bhyve-args'.
EOF
    ;;
  *)
    err "commande inconnue: $cmd"
    ;;
esac
