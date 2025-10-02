#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2025 g-Projets

# g-guest - Topology backup & restore (YAML) with SHA256 integrity
# Usage:
#   topology.sh backup [--out file.yaml]
#   topology.sh restore <backup.yaml> [--dry-run] [--no-ensure]
set -eu

BASE_DIR="${BASE_DIR:-/usr/local/g-guest}"
CFG_DIR="${CFG_DIR:-${BASE_DIR}/config}"
OUT_DIR="${OUT_DIR:-${BASE_DIR}/backups}"
ROUTER_YAML="${ROUTER_YAML:-${CFG_DIR}/router.yaml}"
NETWORKS_YAML="${NETWORKS_YAML:-${CFG_DIR}/networks.yaml}"
SEG_BIN="${SEG_BIN:-${BASE_DIR}/bin/segments.sh}"

have(){ command -v "$1" >/dev/null 2>&1; }
err(){ echo "ERROR: $*" >&2; exit 1; }

# Pick a VALE ctl command (FreeBSD: valectl; some builds: vale-ctl)
VALECTL=""
detect_vale_ctl(){
  if [ -z "${VALECTL}" ]; then
    if have valectl; then VALECTL="valectl";
    elif have vale-ctl; then VALECTL="vale-ctl";
    else VALECTL=""; fi
  fi
}

# SHA256 portable: FreeBSD (sha256 -q) / Linux (sha256sum)
sha256_stdin(){
  if have sha256; then sha256 -q
  elif have sha256sum; then sha256sum | awk '{print $1}'
  else err "no sha256/sha256sum available"; fi
}

dump_file_as_yaml_block(){
  path="$1"
  if [ -r "$path" ]; then
    # FreeBSD: %OLp => octal perms (e.g. 644)
    mode="$(stat -f '%OLp' "$path" 2>/dev/null || echo 644)"
    echo "  - path: \"$path\""
    echo "    mode: \"0${mode}\""
    echo "    content: |-"
    sed 's/^/      /' "$path"
  fi
}

sha256_cat_files_from_yaml(){
  y="$1"
  awk '
    $1=="files:"{inf=1; next}
    inf && $1=="-"{in1=1; next}
    inf && in1 && $1=="content:"&&$2=="|-" { in2=1; next }
    inf && in2 {
      if($0 ~ /^  - path:/){ in2=0; next }
      sub(/^      /,"",$0)
      print
    }
  ' "$y" | sha256_stdin
}

# --- Runtime collectors -------------------------------------------------

collect_netgraph_yaml(){
  echo "  netgraph:"
  if have ngctl; then
    # list all bridge nodes
    ngctl list -l | awk '$3=="bridge"{print $2}' | while read -r br; do
      [ -n "$br" ] || continue
      echo "    - bridge: \"$br\""
      echo "      links:"
      n=2
      # iterate existing hooks linkN
      while ngctl msg "${br}:" getstats "link${n}" >/dev/null 2>&1; do
        # find peer node (first field after name)
        peer="$(ngctl show -n "${br}:link${n}" 2>/dev/null | awk 'NR==1{print $2}')"
        ifname=""
        if [ -n "$peer" ]; then
          ifname="$(ngctl list -l | awk -v p="$peer" '$2==p{print $1}' | head -1)"
        fi
        echo "        - hook: \"link${n}\""
        echo "          if: \"${ifname:-}\""
        n=$((n+1))
      done
    done
  else
    echo "    - error: \"ngctl not available\""
  fi
}

collect_vale_yaml(){
  echo "  vale:"
  detect_vale_ctl
  if [ -n "$VALECTL" ]; then
    # try to list actual switches/ports (valectl -l)
    if "$VALECTL" -l >/dev/null 2>&1; then
      # typical output contains lines like: vale-<name>:<port> ...
      # We build a map switch -> ports[]
      "$VALECTL" -l 2>/dev/null | awk '
        # crude parse: split tokens like "vale-foo:bar"
        {
          for(i=1;i<=NF;i++){
            if($i ~ /^vale[-0-9A-Za-z_]*:[^ ]+$/){
              split($i, a, ":"); sw=a[1]; pt=a[2];
              print sw, pt;
            }
          }
        }' | sort -u | awk '
          BEGIN{prev=""; first=1}
          {
            sw=$1; pt=$2
            if(sw!=prev){
              if(prev!=""){ print "      ]" }
              print "    - switch: \"" sw "\""
              print "      ports: ["
              prev=sw
              first=1
            }
            if(first){ printf "        \"%s\"", pt; first=0 }
            else     { printf ", \"%s\"", pt }
            printf "\n"
          }
          END{
            if(prev!=""){ print "      ]" }
          }'
    else
      # fallback: declared from networks.yaml
      declared="$(awk '/^\s*-\s*name:/{print $3}' "$NETWORKS_YAML" 2>/dev/null || true)"
      if [ -n "$declared" ]; then
        for n in $declared; do
          echo "    - switch: \"vale-${n}\""
          echo "      ports: []"
        done
      else
        echo "    - note: \"no declared VALE switches found in networks.yaml\""
      fi
    fi
  else
    echo "    - error: \"valectl/vale-ctl not available\""
  fi
}

# --- Commands -----------------------------------------------------------

backup(){
  mkdir -p "$OUT_DIR"
  ts="$(date -u +%Y%m%d-%H%M%S)"
  out="${1:-${OUT_DIR}/topology-${ts}.yaml}"

  tmp="$(mktemp)"
  {
    echo "version: 2"
    echo "timestamp: \"$(date -u +%FT%TZ)\""
    echo "files:"
    dump_file_as_yaml_block "$ROUTER_YAML"
    dump_file_as_yaml_block "$NETWORKS_YAML"

    echo "runtime:"
    collect_netgraph_yaml
    collect_vale_yaml
  } > "$tmp"

  files_sha="$(sha256_cat_files_from_yaml "$tmp")"
  {
    cat "$tmp"
    echo "checksums:"
    echo "  algo: sha256"
    echo "  files_sha256: \"$files_sha\""
  } > "$out"
  rm -f "$tmp"
  echo "Saved → $out"
}

restore_list_files(){ awk '$1=="-"&&$2=="path:"{gsub(/"/,"",$3);print $3}' "$1"; }
restore_mode_for(){ awk -v P="$1" '$1=="-"&&$2=="path:"&&$3==("\""P"\""){in=1} in&&$1=="mode:"{gsub(/"/,"",$2);print $2; exit}' "$2"; }
restore_apply_block(){
  path="$1"; file="$2"
  awk -v P="$path" '
    $1=="-"{in=0; cont=0}
    $1=="-" && $2=="path:" && $3==("\"" P "\""){in=1}
    in && $1=="content:"&&$2=="|-" {cont=1; next}
    in && cont==1 {
      if($0 ~ /^  - path:/) exit
      sub(/^      /,"",$0); print
    }
  ' "$file"
}

verify_checksum(){
  y="$1"
  declared="$(awk '$1=="checksums:"{in=1} in&&$1=="files_sha256:"{gsub(/"/,"",$2);print $2; exit}' "$y" || true)"
  [ -n "$declared" ] || { echo "WARN: no checksum in backup, skipping verification." >&2; return 0; }
  current="$(sha256_cat_files_from_yaml "$y")"
  if [ "$current" != "$declared" ]; then
    err "checksum mismatch: files_sha256 expected=$declared computed=$current"
  fi
}

restore(){
  y="$1"; dry="$2"; ensure="$3"
  [ -r "$y" ] || err "backup not readable: $y"
  verify_checksum "$y"

  if [ "$dry" -eq 1 ]; then
    echo "# DRY-RUN restore from $y"
    echo "Would restore files:"
    restore_list_files "$y" | sed 's/^/  - /'
    [ "$ensure" -eq 1 ] && echo "Would run: $SEG_BIN ensure"
    exit 0
  fi

  restore_list_files "$y" | while read -r f; do
    [ -n "$f" ] || continue
    d="$(dirname "$f")"; mkdir -p "$d"
    mode="$(restore_mode_for "$f" "$y" || true)"
    tmp="$(mktemp)"
    restore_apply_block "$f" "$y" > "$tmp"
    [ -s "$tmp" ] || { echo "WARN: empty content for $f" >&2; }
    if [ -n "${mode:-}" ]; then install -m "$mode" "$tmp" "$f"; else install -m 0644 "$tmp" "$f"; fi
    rm -f "$tmp"
    echo "Restored $f"
  done

  if [ "$ensure" -eq 1 ] && [ -x "$SEG_BIN" ]; then
    "$SEG_BIN" ensure
  fi
  echo "Restore completed."
}

cmd="${1:-}"; shift || true
case "$cmd" in
  backup)
    out=""; [ "${1:-}" = "--out" ] && { out="${2:-}"; shift 2; }
    backup "$out"
    ;;
  restore)
    y="${1:-}"; shift || true
    [ -n "$y" ] || err "Usage: $0 restore <file.yaml> [--dry-run] [--no-ensure]"
    dry=0; ens=1
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry=1; shift ;;
        --no-ensure) ens=0; shift ;;
        *) break ;;
      esac
    done
    restore "$y" "$dry" "$ens"
    ;;
  *)
    echo "Usage: $0 {backup [--out file]|restore <file> [--dry-run] [--no-ensure]}" >&2
    exit 1
    ;;
esac
