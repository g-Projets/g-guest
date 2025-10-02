#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2025 g-Projets
#
# g-guest - segments manager (VALE & Netgraph) - lecture/plan
#
# Commands:
#   ensure                      # état synthétique (lecture seule)
#   plan [--json]               # plan de cohérence (VALE + Netgraph présents/absents/surplus)

set -eu

BASE_DIR="${BASE_DIR:-/usr/local/g-guest}"
CFG_DIR="${CFG_DIR:-$BASE_DIR/config}"
NETWORKS_YAML="${NETWORKS_YAML:-$CFG_DIR/networks.yaml}"

have(){ command -v "$1" >/dev/null 2>&1; }
err(){ echo "ERROR: $*" >&2; exit 1; }
warn(){ echo "WARN: $*" >&2; }
info(){ echo "INFO: $*"; }

# ---------- VALE ctl detection ----------
VALECTL=""
detect_vale_ctl(){
  if [ -z "${VALECTL}" ]; then
    if have valectl; then VALECTL="valectl"
    elif have vale-ctl; then VALECTL="vale-ctl"
    else VALECTL=""
    fi
  fi
}

# ---------- YAML parsing (minimal) ----------
# Sorties:
#  - parse_networks_yaml_vale    -> "vale-<name>|if1,if2"
#  - parse_networks_yaml_netgraph-> "sw-<name>|if1,if2"
parse_networks_yaml_vale(){
  awk '
    BEGIN{ inN=0; inItem=0; haveName=0; haveBackend=0; inPorts=0; list="" }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1=="networks:" { inN=1; next }
    inN && $1=="-" { if(inItem && haveName && haveBackend=="vale"){ gsub(/[[:space:]]*$/,"",list); gsub(/^,*/,"",list); printf("vale-%s|%s\n", name, list) } inItem=1; name=""; haveName=0; backend=""; haveBackend=0; inPorts=0; list=""; next }
    inN && inItem && $1=="name:" { name=$2; haveName=1; next }
    inN && inItem && $1=="backend:" { backend=$2; haveBackend=backend; next }
    inN && inItem && ($1=="ports:" || $1=="interfaces:") { inPorts=1; next }
    inN && inItem && inPorts && $1=="-" && $2=="if:" { ifname=$3; gsub(/[[:space:]]*$/,"",ifname); list = list (length(list)? "," : "") ifname; next }
    END{ if(inItem && haveName && haveBackend=="vale"){ gsub(/[[:space:]]*$/,"",list); gsub(/^,*/,"",list); printf("vale-%s|%s\n", name, list) } }
  ' "$NETWORKS_YAML" 2>/dev/null || true
}

parse_networks_yaml_netgraph(){
  awk '
    BEGIN{ inN=0; inItem=0; haveName=0; haveBackend=0; inPorts=0; list="" }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    $1=="networks:" { inN=1; next }
    inN && $1=="-" { if(inItem && haveName && haveBackend=="netgraph"){ gsub(/[[:space:]]*$/,"",list); gsub(/^,*/,"",list); printf("sw-%s|%s\n", name, list) } inItem=1; name=""; haveName=0; backend=""; haveBackend=0; inPorts=0; list=""; next }
    inN && inItem && $1=="name:" { name=$2; haveName=1; next }
    inN && inItem && $1=="backend:" { backend=$2; haveBackend=backend; next }
    inN && inItem && ($1=="ports:" || $1=="interfaces:") { inPorts=1; next }
    inN && inItem && inPorts && $1=="-" && $2=="if:" { ifname=$3; gsub(/[[:space:]]*$/,"",ifname); list = list (length(list)? "," : "") ifname; next }
    END{ if(inItem && haveName && haveBackend=="netgraph"){ gsub(/[[:space:]]*$/,"",list); gsub(/^,*/,"",list); printf("sw-%s|%s\n", name, list) } }
  ' "$NETWORKS_YAML" 2>/dev/null || true
}

# ---------- Runtime VALE ----------
# Produit lignes "switch port"
vale_runtime_pairs(){
  detect_vale_ctl
  [ -n "$VALECTL" ] || return 0
  if "$VALECTL" -l >/dev/null 2>&1; then
    "$VALECTL" -l 2>/dev/null | awk '
      {
        for(i=1;i<=NF;i++){
          if($i ~ /^vale[-0-9A-Za-z_]*:[^ ]+$/){
            split($i, a, ":"); sw=a[1]; pt=a[2];
            print sw, pt;
          }
        }
      }' | sort -u
  fi
}

# Construit map: VALE_RT_<switch> = "port1,port2"
build_vale_runtime_map(){
  VALE_RT_KEYS=""
  tmp="$(mktemp)"; vale_runtime_pairs > "$tmp" || true
  awk '{print $1}' "$tmp" | sort -u | while read -r sw; do
    [ -n "$sw" ] || continue
    csv="$(awk -v s="$sw" '$1==s{print $2}' "$tmp" | paste -sd, -)"
    eval "VALE_RT_${sw}='${csv}'"
    VALE_RT_KEYS="${VALE_RT_KEYS} ${sw}"
  done
  rm -f "$tmp"
}

# ---------- Runtime Netgraph ----------
# Dump: "bridge linkN ifname" pour chaque hook; construit aussi map IF csv.
netgraph_runtime_dump(){
  have ngctl || return 0
  ngctl list -l | awk '$3=="bridge"{print $2}' | while read -r br; do
    [ -n "$br" ] || continue
    n=2
    while ngctl msg "${br}:" getstats "link${n}" >/dev/null 2>&1; do
      peer="$(ngctl show -n "${br}:link${n}" 2>/dev/null | awk 'NR==1{print $2}')"
      ifname=""
      if [ -n "$peer" ]; then
        ifname="$(ngctl list -l | awk -v p="$peer" '$2==p{print $1}' | head -1)"
      fi
      printf "%s %s %s\n" "$br" "link${n}" "$ifname"
      n=$((n+1))
    done
  done
}

# Maps:
#  NET_RT_<bridge> = "if1,if2"
# fichiers temporaires:
#  NET_RT_LINKS_TMP : lignes "bridge linkN ifname" (pour JSON links)
build_netgraph_runtime_maps(){
  NET_RT_KEYS=""
  NET_RT_LINKS_TMP="$(mktemp)"
  netgraph_runtime_dump > "$NET_RT_LINKS_TMP" || true

  # par bridge, agrège ifnames uniques
  awk '{print $1}' "$NET_RT_LINKS_TMP" | sort -u | while read -r br; do
    [ -n "$br" ] || continue
    csv="$(awk -v b="$br" '$1==b{print $3}' "$NET_RT_LINKS_TMP" | awk 'NF' | sort -u | paste -sd, -)"
    eval "NET_RT_${br}='${csv}'"
    NET_RT_KEYS="${NET_RT_KEYS} ${br}"
  done
}

# ---------- CSV helpers ----------
csv_contains(){ echo ",$1," | grep -q ",$2,"; }
csv_diff(){ a="$1"; b="$2"; out=""; OLDIFS="$IFS"; IFS=","; for x in $a; do [ -z "$x" ] && continue; echo ",$b," | grep -q ",$x," || out="${out}${out:+,}$x"; done; IFS="$OLDIFS"; echo "$out"; }
csv_inter(){ a="$1"; b="$2"; out=""; OLDIFS="$IFS"; IFS=","; for x in $a; do [ -z "$x" ] && continue; echo ",$b," | grep -q ",$x," && out="${out}${out:+,}$x"; done; IFS="$OLDIFS"; echo "$out"; }

# ---------- PLAN JSON ----------
plan_json(){
  # Desired
  DESIRED_VALE="$(parse_networks_yaml_vale || true)"
  DESIRED_NG="$(parse_networks_yaml_netgraph || true)"

  # Runtime
  build_vale_runtime_map
  build_netgraph_runtime_maps

  echo '{'
  echo '  "version": 1,'

  # VALE
  echo '  "vale": ['
  first=1
  echo "$DESIRED_VALE" | while IFS='|' read -r sw ports; do
    [ -n "$sw" ] || continue
    desired_csv="$(echo "$ports" | tr -d '[:space:]')"
    eval "actual_csv=\"\${VALE_RT_${sw}:-}\""
    if [ -z "${actual_csv:-}" ]; then
      state="MISSING"; present_csv=""; missing_csv="$desired_csv"; extra_csv=""
    else
      present_csv="$(csv_inter "$desired_csv" "$actual_csv")"
      missing_csv="$(csv_diff  "$desired_csv" "$actual_csv")"
      extra_csv="$(csv_diff  "$actual_csv"  "$desired_csv")"
      if [ -n "$missing_csv" ] || [ -n "$extra_csv" ]; then state="DRIFT"; else state="OK"; fi
    fi

    [ $first -eq 1 ] || echo '    ,'; first=0
    echo '    {'
    printf '      "switch": "%s",\n' "$sw"
    printf '      "desired_ports": [%s],\n' "$( [ -n "$desired_csv" ] && echo "\"$(echo "$desired_csv" | sed 's/,/","/g')\"" )"
    printf '      "actual_ports":  [%s],\n' "$( [ -n "$actual_csv" ]  && echo "\"$(echo "$actual_csv"  | sed 's/,/","/g')\"" )"
    printf '      "present_ports": [%s],\n' "$( [ -n "$present_csv" ] && echo "\"$(echo "$present_csv" | sed 's/,/","/g')\"" )"
    printf '      "missing_ports": [%s],\n' "$( [ -n "$missing_csv" ] && echo "\"$(echo "$missing_csv" | sed 's/,/","/g')\"" )"
    printf '      "extra_ports":   [%s],\n' "$( [ -n "$extra_csv" ]   && echo "\"$(echo "$extra_csv"   | sed 's/,/","/g')\"" )"
    printf '      "state": "%s"\n' "$state"
    echo '    }'
  done
  echo '  ],'

  # NETGRAPH
  echo '  "netgraph": ['
  first=1
  echo "$DESIRED_NG" | while IFS='|' read -r br desired_ports; do
    [ -n "$br" ] || continue
    desired_csv="$(echo "$desired_ports" | tr -d '[:space:]')"
    eval "actual_csv=\"\${NET_RT_${br}:-}\""

    # collect links JSON-friendly
    links_json=""
    if [ -n "${NET_RT_LINKS_TMP:-}" ] && [ -r "$NET_RT_LINKS_TMP" ]; then
      # build an array of link objects only for this bridge
      lj_tmp="$(mktemp)"
      awk -v b="$br" '$1==b{print $2,$3}' "$NET_RT_LINKS_TMP" > "$lj_tmp"
      # dump as JSON
      links_json="$(awk 'BEGIN{f=1}
        {
          if(f==1){ printf("["); f=0 } else { printf(",") }
          printf("{\"hook\":\"%s\",\"if\":\"%s\"}", $1, $2)
        }
        END{ if(f==1) printf("[]"); else printf("]") }' "$lj_tmp")"
      rm -f "$lj_tmp"
    else
      links_json="[]"
    fi

    if [ -z "${actual_csv:-}" ]; then
      state="MISSING"; present_csv=""; missing_csv="$desired_csv"; extra_csv=""
    else
      present_csv="$(csv_inter "$desired_csv" "$actual_csv")"
      missing_csv="$(csv_diff  "$desired_csv" "$actual_csv")"
      extra_csv="$(csv_diff  "$actual_csv"  "$desired_csv")"
      if [ -n "$missing_csv" ] || [ -n "$extra_csv" ]; then state="DRIFT"; else state="OK"; fi
    fi

    [ $first -eq 1 ] || echo '    ,'; first=0
    echo '    {'
    printf '      "bridge": "%s",\n' "$br"
    printf '      "desired_if":   [%s],\n' "$( [ -n "$desired_csv" ] && echo "\"$(echo "$desired_csv" | sed 's/,/","/g')\"" )"
    printf '      "actual_if":    [%s],\n' "$( [ -n "$actual_csv" ]  && echo "\"$(echo "$actual_csv"  | sed 's/,/","/g')\"" )"
    printf '      "present_if":   [%s],\n' "$( [ -n "$present_csv" ] && echo "\"$(echo "$present_csv" | sed 's/,/","/g')\"" )"
    printf '      "missing_if":   [%s],\n' "$( [ -n "$missing_csv" ] && echo "\"$(echo "$missing_csv" | sed 's/,/","/g')\"" )"
    printf '      "extra_if":     [%s],\n' "$( [ -n "$extra_csv" ]   && echo "\"$(echo "$extra_csv"   | sed 's/,/","/g')\"" )"
    printf '      "links": %s,\n' "$links_json"
    printf '      "state": "%s"\n' "$state"
    echo '    }'
  done
  echo '  ]'

  echo '}'
}

# ---------- PLAN texte ----------
plan_text(){
  tmp="$(mktemp)"
  plan_json > "$tmp"

  echo "== VALE =="
  total=$(awk -F'"' '/"switch":/{c++} END{print c+0}' "$tmp")
  ok=$(awk -F'"' '/"vale".*"state": "OK"/{c++} END{print c+0}' "$tmp")
  drift=$(awk -F'"' '/"vale".*"state": "DRIFT"/{c++} END{print c+0}' "$tmp")
  missing=$(awk -F'"' '/"vale".*"state": "MISSING"/{c++} END{print c+0}' "$tmp")
  echo "total=$total ok=$ok drift=$drift missing=$missing"
  echo
  awk '
    BEGIN{sect=""}
    /"vale": \[/ {sect="vale"}
    /"switch":/ && sect=="vale" {sw=$4}
    /"state":/  && sect=="vale" {st=$4}
    /"missing_ports": \[/ && sect=="vale" {getline; gsub(/[", \[\]]/,"",$0); miss=$0}
    /"extra_ports": \[/   && sect=="vale" {getline; gsub(/[", \[\]]/,"",$0); extra=$0; printf("- %s : %s\n", sw, st); if(miss!="") printf("    missing: %s\n", miss); if(extra!="") printf("    extra  : %s\n", extra); miss=""; extra=""}
  ' "$tmp"

  echo
  echo "== Netgraph =="
  total=$(awk -F'"' '/"bridge":/{c++} END{print c+0}' "$tmp")
  ok=$(awk -F'"' '/"netgraph".*"state": "OK"/{c++} END{print c+0}' "$tmp")
  drift=$(awk -F'"' '/"netgraph".*"state": "DRIFT"/{c++} END{print c+0}' "$tmp")
  missing=$(awk -F'"' '/"netgraph".*"state": "MISSING"/{c++} END{print c+0}' "$tmp")
  echo "total=$total ok=$ok drift=$drift missing=$missing"
  echo
  awk '
    BEGIN{sect=""}
    /"netgraph": \[/ {sect="netgraph"}
    /"bridge":/ && sect=="netgraph" {br=$4}
    /"state":/  && sect=="netgraph" {st=$4}
    /"missing_if": \[/ && sect=="netgraph" {getline; gsub(/[", \[\]]/,"",$0); miss=$0}
    /"extra_if": \[/   && sect=="netgraph" {getline; gsub(/[", \[\]]/,"",$0); extra=$0; printf("- %s : %s\n", br, st); if(miss!="") printf("    missing: %s\n", miss); if(extra!="") printf("    extra  : %s\n", extra); miss=""; extra=""}
  ' "$tmp"

  rm -f "$tmp"
}

# ---------- ensure (lecture seule) ----------
ensure(){
  detect_vale_ctl
  echo "Segments status (read-only):"

  # VALE
  echo " VALE:"
  if [ -n "$VALECTL" ] && "$VALECTL" -l >/dev/null 2>&1; then
    parse_networks_yaml_vale | while IFS='|' read -r sw ports; do
      desired_csv="$(echo "$ports" | tr -d '[:space:]')"
      actual_csv="$("$VALECTL" -l 2>/dev/null | awk -v s="$sw" '{ for(i=1;i<=NF;i++){ if($i ~ ("^" s ":[^ ]+$")){ split($i,a,":"); print a[2] } } }' | paste -sd, -)"
      if [ -z "$actual_csv" ]; then
        echo "  - $sw : MISSING"
      else
        miss="$(csv_diff "$desired_csv" "$actual_csv")"
        extra="$(csv_diff "$actual_csv" "$desired_csv")"
        if [ -n "$miss" ] || [ -n "$extra" ]; then
          echo "  - $sw : DRIFT (missing: ${miss:-none}, extra: ${extra:-none})"
        else
          echo "  - $sw : OK"
        fi
      fi
    done
  else
    echo "  (valectl/vale-ctl indisponible ou ne supporte pas -l)"
  fi

  # Netgraph
  echo " Netgraph:"
  if have ngctl; then
    # désiré
    parse_networks_yaml_netgraph | while IFS='|' read -r br ports; do
      desired_csv="$(echo "$ports" | tr -d '[:space:]')"
      # actuel
      actual_csv="$(netgraph_runtime_dump 2>/dev/null | awk -v b="$br" '$1==b{print $3}' | awk 'NF' | sort -u | paste -sd, -)"
      if [ -z "$actual_csv" ]; then
        echo "  - $br : MISSING"
      else
        miss="$(csv_diff "$desired_csv" "$actual_csv")"
        extra="$(csv_diff "$actual_csv" "$desired_csv")"
        if [ -n "$miss" ] || [ -n "$extra" ]; then
          echo "  - $br : DRIFT (missing: ${miss:-none}, extra: ${extra:-none})"
        else
          echo "  - $br : OK"
        fi
      fi
    done
  else
    echo "  (ngctl indisponible)"
  fi
}

# ---------- CLI ----------
cmd="${1:-}"; shift || true
case "$cmd" in
  ensure) ensure ;;
  plan)
    if [ "${1:-}" = "--json" ]; then plan_json; else plan_text; fi
    ;;
  *)
    cat >&2 <<USAGE
Usage: $0 {ensure|plan [--json]}
  ensure       : vérifie l'état (VALE & Netgraph, lecture seule)
  plan         : plan de cohérence (texte)
  plan --json  : plan de cohérence (JSON), inclut:
                 - vale: desired/actual/present/missing/extra per switch
                 - netgraph: desired/actual/present/missing/extra + links (hook->if) per bridge
USAGE
    exit 1
    ;;
esac
