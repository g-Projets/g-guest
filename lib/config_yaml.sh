#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2025 g-Projets

CFG_DIR="${CFG_DIR:-/usr/local/g-guest/config}"
NETWORKS_YAML="${NETWORKS_YAML:-$CFG_DIR/networks.yaml}"

_jsonescape(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g;'; }

# Assure que le fichier existe avec squelette
config_yaml::ensure_file() {
  [ -f "$NETWORKS_YAML" ] && return 0
  mkdir -p "$CFG_DIR"
  cat > "$NETWORKS_YAML" <<EOF
version: 1
networks: []
EOF
}

# Vérifie si un switch logique existe (ret 0 si présent)
config_yaml::has_switch() {
  logical="$1"
  [ -r "$NETWORKS_YAML" ] || return 1
  awk -v L="$logical" '
    $1=="networks:" {in=1; next}
    in && $1=="-"   {name=""}
    in && $1=="name:" {name=$2}
    in && name==L {found=1; exit}
    END{exit(found?0:1)}
  ' "$NETWORKS_YAML"
}

# Ajoute (ou ne fait rien si présent) un switch avec backend + bloc interfaces
config_yaml::upsert_switch() {
  logical="$1"; backend="$2"
  config_yaml::ensure_file
  if config_yaml::has_switch "$logical"; then
    # met à jour backend si différent
    tmp="$(mktemp)"
    awk -v L="$logical" -v B="$backend" '
      BEGIN{in=0}
      { print_line=1 }
      $1=="networks:" {n=1}
      n && $1=="-" {in=0}
      n && $1=="name:" && $2==L {in=1}
      in && $1=="backend:" {
        if ($2!=B) $0="    backend: "B
      }
      print $0
    ' "$NETWORKS_YAML" > "$tmp" && mv "$tmp" "$NETWORKS_YAML"
    return 0
  fi
  # append un nouvel item
  tmp="$(mktemp)"
  cat "$NETWORKS_YAML" > "$tmp"
  cat >> "$tmp" <<EOF

  - name: $logical
    backend: $backend
    interfaces: []
EOF
  mv "$tmp" "$NETWORKS_YAML"
}

# Vérifie si une interface est déjà déclarée dans un switch
config_yaml::has_interface() {
  logical="$1"; ifname="$2"
  [ -r "$NETWORKS_YAML" ] || return 1
  awk -v L="$logical" -v IF="$ifname" '
    $1=="networks:" {in=1; next}
    in && $1=="-" {name=""; sect=""}
    in && $1=="name:" {name=$2}
    in && name==L && $1=="interfaces:" {sect=1; next}
    in && name==L && sect==1 {
      if ($1=="-") {n=""}
      if ($1=="name:" && $2==IF) {found=1; exit}
      if ($1=="backend:" || $1=="- name:") { } # carry on
    }
    END{exit(found?0:1)}
  ' "$NETWORKS_YAML"
}

# Ajoute / met à jour une interface (name/mode) dans un switch
config_yaml::add_interface() {
  logical="$1"; ifname="$2"; mode="$3"
  config_yaml::ensure_file
  config_yaml::upsert_switch "$logical" "$(awk -v L="$logical" '
    $1=="networks:" {in=1; next}
    in && $1=="-" {name=""}
    in && $1=="name:" {name=$2}
    in && name==L && $1=="backend:" {print $2; exit}
  ' "$NETWORKS_YAML")"

  if config_yaml::has_interface "$logical" "$ifname"; then
    tmp="$(mktemp)"
    awk -v L="$logical" -v IF="$ifname" -v M="$mode" '
      $1=="networks:" {in=1; next}
      {print_line=1}
      in && $1=="-" {name=""; sect=""}
      in && $1=="name:" {name=$2}
      in && name==L && $1=="interfaces:" {sect=1; next}
      in && name==L && sect==1 {
        if ($1=="-") {n=""}
        if ($1=="name:" && $2==IF) {print; getline; if($1=="mode:"){ $0="        mode: "M } ; print; next}
      }
      {print}
    ' "$NETWORKS_YAML" > "$tmp" && mv "$tmp" "$NETWORKS_YAML"
    return 0
  fi

  # append sous interfaces:
  tmp="$(mktemp)"
  awk -v L="$logical" -v IF="$ifname" -v M="$mode" '
    $1=="networks:" {in=1}
    {print}
    in && $1=="-" {name=""}
    in && $1=="name:" {name=$2}
    in && name==L && $1=="interfaces:" {mark=NR}
    END{
      if (mark>0){
        # on ne sait pas injecter en place avec awk simple -> passons
      }
    }
  ' "$NETWORKS_YAML" > "$tmp"

  # injection en fin de bloc (simple): on ajoute juste après la ligne "interfaces:"
  ed -s "$tmp" <<ED
g/^\\s*name: ${logical}\$/.,/^- name:/ s/\\(\\s*interfaces:.*\\)/\\1\\
      - name: ${ifname}\\
        mode: ${mode}/
w
q
ED
  mv "$tmp" "$NETWORKS_YAML"
}

# Supprime une interface (name) d’un switch
config_yaml::remove_interface() {
  logical="$1"; ifname="$2"
  [ -r "$NETWORKS_YAML" ] || return 0
  tmp="$(mktemp)"
  awk -v L="$logical" -v IF="$ifname" '
    $1=="networks:" {in=1}
    in && $1=="-" {name=""}
    in && $1=="name:" {name=$2}
    {
      if (name==L && $1=="-"){
        # possible début d’item interface
        getline nextl
        if (nextl ~ /^[[:space:]]*name:[[:space:]]*IF$/){
          # consomme aussi la ligne suivante "mode:"
          getline modemaybe
          next
        } else {
          print $0
          print nextl
          next
        }
      }
      print
    }
  ' "$NETWORKS_YAML" > "$tmp" && mv "$tmp" "$NETWORKS_YAML"
}
