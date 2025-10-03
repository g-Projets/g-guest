#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2025 g-Projets
#
# g-guest - segments manager (VALE & Netgraph)
# Lecture seule: état et plan de cohérence
#
# Usage:
#   segments.sh ensure              # état synthétique (lecture seule)
#   segments.sh plan [--json]       # plan détaillé (texte ou JSON)

set -eu

BASE_DIR="${BASE_DIR:-/usr/local/g-guest}"
CFG_DIR="${CFG_DIR:-$BASE_DIR/config}"
NETWORKS_YAML="${NETWORKS_YAML:-$CFG_DIR/networks.yaml}"

have(){ command -v "$1" >/dev/null 2>&1; }
warn(){ printf "WARN: %s\n" "$*" >&2; }
die(){  printf "ERROR: %s\n" "$*" >&2; exit 1; }

[ -r "$NETWORKS_YAML" ] || die "networks.yaml introuvable: $NETWORKS_YAML"

# ---------------- VALE ----------------
VALECTL=""
detect_vale_ctl(){
  if [ -z "$VALECTL" ]; then
    if have valectl; then VALECTL="valectl"
    elif have vale-ctl; then VALECTL="vale-ctl"
    else VALECTL=""
    fi
  fi
}

# Liste "switch port" (un par ligne) en parsant la sortie sans argument
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
vale_runtime_pairs(){ vale_pairs; }

# ---------------- Netgraph ----------------
NG_LIST_CACHE=""
ng_list_l(){
  if ! have ngctl; then NG_LIST_CACHE=""; return 1; fi
  if [ -z "$NG_LIST_CACHE" ]; then NG_LIST_CACHE="$(ngctl list -l 2>/dev/null || true)"; fi
  [ -n "$NG_LIST_CACHE" ]
}
ng_bridge_exists(){
  br="$1"
  if ! ng_list_l; then return 1; fi
  printf "%s\n" "$NG_LIST_CACHE" | awk -v b="$br" '
    $0 ~ ("(^|[[:space:]])" b "([[:space:]]|$)") && $0 ~ /bridge/ {found=1}
    END{ exit(found?0:1) }
  '
}
ng_link_exists(){ br="$1"; hook="$2"; ngctl msg "${br}:" getstats "$hook" >/dev/null 2>&1; }
ng_link_peer_if(){
  br="$1"; hook="$2"
  peer="$(ngctl show -n "${br}:${hook}" 2>/dev/null | awk 'NR==1{print $2}')"
  [ -n "${peer:-}" ] || { echo ""; return 0; }
  if ng_list_l; then
    printf "%s\n" "$NG_LIST_CACHE" | awk -v p="$peer" '
      index($0,p)>0 && $0 ~ /eiface/ { print $1; found=1; exit }
      END{ if(!found) exit 1 }
    ' 2>/dev/null || true
  else
    echo ""
  fi
}
ng_scan_links(){
  br="$1"
  n=2
  while ng_link_exists "$br" "link$n"; do
    ifn="$(ng_link_peer_if "$br" "link$n" || true)"
    printf "%s %s\n" "link$n" "${ifn:-}"
    n=$((n+1))
  done
}

# ------------- Parse networks.yaml -------------
# VALE: "vale-<logical>|if1,if2,..."
parse_networks_yaml_vale(){
  awk '
    function flush_vale(){
      if (backend=="vale" && name!="") {
        gsub(/"/,"",name)
        print "vale-" name "|" ports
      }
    }
    BEGIN{inlist=0; name=""; backend=""; ports=""; inports=0}
    $1=="networks:" {inlist=1; next}
    inlist && $1=="-" { flush_vale(); name=""; backend=""; ports=""; inports=0; next }
    inlist && $1=="name:" {name=$2; next}
    inlist && $1=="backend:" {backend=$2; next}
    # accepter 'ports:' ou 'interfaces:' côté VALE
    inlist && backend=="vale" && ($1=="ports:" || $1=="interfaces:") {inports=1; next}
    inlist && inports && $1=="-" && $2=="if:" {
      ifn=$3; gsub(/"/,"",ifn); ports=(ports?ports",":"") ifn; next
    }
    END{ flush_vale() }
  ' "$NETWORKS_YAML"
}

# Netgraph: "sw-<logical>|if1,if2,..."
parse_networks_yaml_netgraph(){
  awk '
    function flush_ng(){
      if (backend=="netgraph" && name!="") {
        gsub(/"/,"",name)
        print "sw-" name "|" ifs
      }
    }
    BEGIN{inlist=0; name=""; backend=""; ifs=""; inports=0}
    $1=="networks:" {inlist=1; next}
    inlist && $1=="-" { flush_ng(); name=""; backend=""; ifs=""; inports=0; next }
    inlist && $1=="name:" {name=$2; next}
    inlist && $1=="backend:" {backend=$2; next}
    inlist && backend=="netgraph" && ($1=="interfaces:" || $1=="ports:") {inports=1; next}
    inlist && inports && $1=="-" && $2=="if:" {
      ifn=$3; gsub(/"/,"",ifn); ifs=(ifs?ifs",":"") ifn; next
    }
    END{ flush_ng() }
  ' "$NETWORKS_YAML"
}

# ------------- CSV & JSON helpers -------------
csv_diff(){
  a="$1"; b="$2"
  [ -n "$a" ] || { echo ""; return 0; }
  awk -v A="$a" -v B="$b" '
    BEGIN{
      n=split(A,aa,","); m=split(B,bb,",")
      for(i=1;i<=m;i++){ seen[bb[i]]=1 }
      first=1
      for(i=1;i<=n;i++){
        x=aa[i]
        if(x!="" && !seen[x]){
          if(!first){ printf(",") } ; first=0
          printf("%s", x)
        }
      }
      printf("\n")
    }'
}
json_escape(){ printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
json_array_from_csv(){
  csv="$1"
  [ -n "$csv" ] || { printf "[]"; return 0; }
  printf "["
  oldIFS="$IFS"; IFS=,
  first=1
  for it in $csv; do
    [ -n "$it" ] || continue
    esc="$(json_escape "$it")"
    if [ $first -eq 1 ]; then first=0; else printf ", "; fi
    printf "\"%s\"" "$esc"
  done
  IFS="$oldIFS"
  printf "]"
}

# ------------- ENSURE (texte) -------------
ensure_vale(){
  echo " VALE:"
  detect_vale_ctl
  cfg_vale="$(parse_networks_yaml_vale || true)"
  pairs="$(vale_runtime_pairs || true)"

  if [ -z "$cfg_vale" ]; then
    echo "  (aucun réseau VALE configuré dans $NETWORKS_YAML)"
    if [ -n "$pairs" ]; then
      # montrer ce que le runtime voit pour aider au debug
      echo "  découvert (runtime):"
      printf "%s\n" "$pairs" | awk '{print "   • "$1" -> "$2}'
    fi
    return 0
  fi

  printf "%s\n" "$cfg_vale" | while IFS='|' read -r sw ports; do
    desired_csv="$(printf "%s" "$ports" | tr -d '[:space:]')"
    present_csv="$(printf "%s\n" "$pairs" | awk -v s="$sw" '$1==s{print $2}' | paste -sd, - || true)"
    if [ -z "${present_csv:-}" ]; then
      echo "  - $sw : MISSING"
    else
      miss="$(csv_diff "$desired_csv" "$present_csv")"
      extra="$(csv_diff "$present_csv" "$desired_csv")"
      if [ -n "$miss" ] || [ -n "$extra" ]; then
        echo "  - $sw : DRIFT (missing: ${miss:-none}, extra: ${extra:-none})"
      else
        echo "  - $sw : OK"
      fi
    fi
  done
}

ensure_netgraph(){
  echo " Netgraph:"
  cfg_ng="$(parse_networks_yaml_netgraph || true)"
  if [ -z "$cfg_ng" ]; then
    echo "  (aucun réseau Netgraph configuré dans $NETWORKS_YAML)"
    return 0
  fi
  printf "%s\n" "$cfg_ng" | while IFS='|' read -r br ifs; do
    desired_csv="$(printf "%s" "$ifs" | tr -d '[:space:]')"
    if ! ng_bridge_exists "$br"; then
      echo "  - $br : MISSING"
      continue
    fi
    present_csv="$(ng_scan_links "$br" | awk '{print $2}' | sed '/^$/d' | paste -sd, - || true)"
    miss="$(csv_diff "$desired_csv" "${present_csv:-}")"
    extra="$(csv_diff "${present_csv:-}" "$desired_csv")"
    if [ -n "$miss" ] || [ -n "$extra" ]; then
      echo "  - $br : DRIFT (missing: ${miss:-none}, extra: ${extra:-none})"
    else
      echo "  - $br : OK"
    fi
  done
}

ensure(){
  echo "g-guest_segments: ensure (lecture seule)"
  echo "Segments status (read-only):"
  ensure_vale
  ensure_netgraph
}

# ------------- PLAN (texte & JSON) -------------
plan_text(){
  echo "PLAN:"
  echo " VALE:"
  cfg_vale="$(parse_networks_yaml_vale || true)"
  pairs="$(vale_runtime_pairs || true)"
  if [ -z "$cfg_vale" ]; then
    echo "  (aucun réseau VALE configuré)"
  else
    printf "%s\n" "$cfg_vale" | while IFS='|' read -r sw ports; do
      desired="$(printf "%s" "$ports" | tr -d '[:space:]')"
      present="$(printf "%s\n" "$pairs" | awk -v s="$sw" '$1==s{print $2}' | paste -sd, - || true)"
      miss="$(csv_diff "$desired" "${present:-}")"
      extra="$(csv_diff "${present:-}" "$desired")"
      state="OK"
      [ -z "${present:-}" ] && state="MISSING"
      [ -n "$miss" ] || [ -n "$extra" ] && [ "$state" = "OK" ] && state="DRIFT"
      echo "  - $sw"
      echo "    desired: ${desired:-<none>}"
      echo "    present: ${present:-<none>}"
      echo "    missing: ${miss:-<none>}"
      echo "    extra:   ${extra:-<none>}"
      echo "    state:   $state"
    done
  fi

  echo " Netgraph:"
  cfg_ng="$(parse_networks_yaml_netgraph || true)"
  if [ -z "$cfg_ng" ]; then
    echo "  (aucun réseau Netgraph configuré)"
  else
    printf "%s\n" "$cfg_ng" | while IFS='|' read -r br ifs; do
      desired="$(printf "%s" "$ifs" | tr -d '[:space:]')"
      links="$(ng_scan_links "$br" || true)"
      present="$(printf "%s\n" "$links" | awk '{print $2}' | sed '/^$/d' | paste -sd, - || true)"
      miss="$(csv_diff "$desired" "${present:-}")"
      extra="$(csv_diff "${present:-}" "$desired")"
      state="OK"
      if ! ng_bridge_exists "$br"; then
        state="MISSING"
      else
        [ -n "$miss" ] || [ -n "$extra" ] && state="DRIFT"
      fi
      echo "  - $br"
      echo "    desired: ${desired:-<none>}"
      echo "    present: ${present:-<none>}"
      echo "    missing: ${miss:-<none>}"
      echo "    extra:   ${extra:-<none>}"
      echo "    state:   $state"
      if [ -n "${links:-}" ]; then
        echo "    links:"
        printf "%s\n" "$links" | while read -r hk ifn; do
          echo "      - ${hk}: ${ifn:-<unknown>}"
        done
      fi
    done
  fi
}

plan_json(){
  printf "{"
  printf "\"version\":1,"

  printf "\"vale\":["
  firstv=1
  cfg_vale="$(parse_networks_yaml_vale || true)"
  pairs="$(vale_runtime_pairs || true)"
  if [ -n "$cfg_vale" ]; then
    printf "%s\n" "$cfg_vale" | while IFS='|' read -r sw ports; do
      desired="$(printf "%s" "$ports" | tr -d '[:space:]')"
      present="$(printf "%s\n" "$pairs" | awk -v s="$sw" '$1==s{print $2}' | paste -sd, - || true)"
      miss="$(csv_diff "$desired" "${present:-}")"
      extra="$(csv_diff "${present:-}" "$desired")"
      state="OK"
      [ -z "${present:-}" ] && state="MISSING"
      [ -n "$miss" ] || [ -n "$extra" ] && [ "$state" = "OK" ] && state="DRIFT"
      [ $firstv -eq 1 ] && firstv=0 || printf ","
      printf "{"
      printf "\"switch\":\"%s\"," "$(json_escape "$sw")"
      printf "\"desired_ports\":%s," "$(json_array_from_csv "$desired")"
      printf "\"present_ports\":%s," "$(json_array_from_csv "${present:-}")"
      printf "\"missing_ports\":%s," "$(json_array_from_csv "${miss:-}")"
      printf "\"extra_ports\":%s,"   "$(json_array_from_csv "${extra:-}")"
      printf "\"state\":\"%s\"" "$state"
      printf "}"
    done
  fi
  printf "],"

  printf "\"netgraph\":["
  firstn=1
  cfg_ng="$(parse_networks_yaml_netgraph || true)"
  if [ -n "$cfg_ng" ]; then
    printf "%s\n" "$cfg_ng" | while IFS='|' read -r br ifs; do
      desired="$(printf "%s" "$ifs" | tr -d '[:space:]')"
      links="$(ng_scan_links "$br" || true)"
      present="$(printf "%s\n" "$links" | awk '{print $2}' | sed '/^$/d' | paste -sd, - || true)"
      miss="$(csv_diff "$desired" "${present:-}")"
      extra="$(csv_diff "${present:-}" "$desired")"
      state="OK"
      if ! ng_bridge_exists "$br"; then
        state="MISSING"
      else
        [ -n "$miss" ] || [ -n "$extra" ] && state="DRIFT"
      fi
      [ $firstn -eq 1 ] && firstn=0 || printf ","
      printf "{"
      printf "\"bridge\":\"%s\"," "$(json_escape "$br")"
      printf "\"desired_if\":%s,"  "$(json_array_from_csv "$desired")"
      printf "\"present_if\":%s,"  "$(json_array_from_csv "${present:-}")"
      printf "\"missing_if\":%s,"  "$(json_array_from_csv "${miss:-}")"
      printf "\"extra_if\":%s,"    "$(json_array_from_csv "${extra:-}")"
      printf "\"links\":["
      firstl=1
      if [ -n "${links:-}" ]; then
        printf "%s\n" "$links" | while read -r hk ifn; do
          [ $firstl -eq 1 ] && firstl=0 || printf ","
          printf "{"
          printf "\"hook\":\"%s\"," "$(json_escape "$hk")"
          printf "\"if\":\"%s\""     "$(json_escape "${ifn:-}")"
          printf "}"
        done
      fi
      printf "],"
      printf "\"state\":\"%s\"" "$state"
      printf "}"
    done
  fi
  printf "]"

  printf "}\n"
}

plan(){
  if [ "${1:-}" = "--json" ]; then
    plan_json
  else
    plan_text
  fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  ensure) ensure ;;
  plan)   plan "${1:-}" ;;
  *) echo "Usage: $0 {ensure|plan [--json]}" >&2; exit 1 ;;
esac
