#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2016 Matt Churchyard <churchers@gmail.com>
# SPDX-FileCopyrightText: 2025 g-Projets

# g-guest: lib/switch.sh
# Provisioning des switches réseau (VALE & Netgraph), inspiré de vm-bhyve.
# - Fonctions "switch::<backend>::..." réutilisables par l'orchestrateur
# - CLI minimal en fin de fichier: create|delete|add|remove|show|list
#
# Conventions de nommage:
#   - VALE     : "vale-<logical>"
#   - Netgraph : "sw-<logical>"
#
# VALE "anchor":
#   - VALE n'existe dans le kernel que s'il a ≥ 1 port.
#   - On peut "matérialiser" un switch avec un port exclusif (-a) nommé
#     v_<logical>_anchor (ou personnalisé). Ce port n'est PAS un ifnet,
#     c'est un port netmap créé par valectl.
#
# Netgraph "anchor":
#   - On peut conserver une eiface d'ancrage (ex: n_<logical>_anchor) reliée
#     au bridge (sw-<logical>: link2). Optionnel: un bridge peut exister sans hook.

set -eu

# --- utils ---------------------------------------------------------------
need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
info(){ echo "INFO: $*"; }
warn(){ echo "WARN: $*" >&2; }
err(){ echo "ERROR: $*" >&2; exit 1; }

# Binaries
VALECTL="${VALECTL:-valectl}"   # FreeBSD 'valectl'
NGCTL="${NGCTL:-ngctl}"

# Defaults anchor naming
VALE_ANCHOR_PREFIX="${VALE_ANCHOR_PREFIX:-v_}"
VALE_ANCHOR_SUFFIX="${VALE_ANCHOR_SUFFIX:-_anchor}"
NG_ANCHOR_PREFIX="${NG_ANCHOR_PREFIX:-n_}"
NG_ANCHOR_SUFFIX="${NG_ANCHOR_SUFFIX:-_anchor}"

# Résolution du nom "physique" du switch selon backend + nom logique
switch::resolve_name(){
  # $1 backend   (vale|netgraph)
  # $2 logical   (ex: mgmt)
  case "$1" in
    vale)     printf "vale-%s" "$2" ;;
    netgraph) printf "sw-%s"   "$2" ;;
    *)        err "backend inconnu: $1" ;;
  esac
}

# --- VALE helpers --------------------------------------------------------
# Liste tous les ports d'un switch VALE (ligne par port: "vale-xxx:portname")
switch::vale::ports(){
  need "$VALECTL"
  sw="$1"
  "$VALECTL" 2>/dev/null | awk -F: -v SW="$sw" '($1==SW){print $2}'
}

# Test si le switch "existe" (i.e., ≥ 1 port attaché dans le kernel)
switch::vale::exists(){
  sw="$1"
  if [ -n "$(switch::vale::ports "$sw" || true)" ]; then return 0; fi
  return 1
}

# Créer un switch VALE: en pratique, ATTACHE un port anchor (-a) pour le matérialiser
# Options:
#   $1 logical
#   $2 anchor_name (optionnel, défaut v_<logical>_anchor)
#   $3 mode ("a" exclusif | "h" partagé). Pour anchor, "a" est recommandé.
switch::vale::create(){
  logical="$1"
  anchor="${2:-${VALE_ANCHOR_PREFIX}${logical}${VALE_ANCHOR_SUFFIX}}"
  mode="${3:-a}"
  sw="$(switch::resolve_name vale "$logical")"

  if switch::vale::exists "$sw"; then
    info "VALE $sw déjà présent (≥ 1 port)."
    return 0
  fi

  need "$VALECTL"
  case "$mode" in
    a) opt="-a" ;;  # exclusive netmap port
    h) opt="-h" ;;  # host-shared (requiert un ifnet existant nommé $anchor)
    *) err "mode VALE invalide (utiliser 'a' ou 'h')" ;;
  esac

  # En mode -a, 'anchor' est un port netmap logique (aucun ifnet requis).
  # En mode -h, 'anchor' DOIT être un ifnet existant (em0, ngethX, tapY, ...).
  "$VALECTL" "$opt" "${sw}:${anchor}" >/dev/null
  info "Créé VALE $sw via anchor (${opt} ${sw}:${anchor})"
}

# Supprimer le switch VALE:
# - sans --force: refuse si des ports non-anchor sont attachés
# - avec  --force: détache tous les ports, y compris anchors
#   $1 logical
#   $2 force ("force" pour tout enlever)
switch::vale::delete(){
  logical="$1"
  force="${2:-}"
  sw="$(switch::resolve_name vale "$logical")"
  need "$VALECTL"

  ports="$(switch::vale::ports "$sw" || true)"
  [ -z "$ports" ] && { info "VALE $sw inexistant"; return 0; }

  non_anchor=0
  # Détecte ports non-anchor
  echo "$ports" | while read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      "${VALE_ANCHOR_PREFIX}${sw}${VALE_ANCHOR_SUFFIX}"|\
      "${VALE_ANCHOR_PREFIX}${logical}${VALE_ANCHOR_SUFFIX}"|*anchor*)
        : ;;
      *) non_anchor=$((non_anchor+1));;
    esac
  done

  # Recompte robuste (sous-shell-safe)
  non_anchor="$(echo "$ports" | awk -v SW="$sw" -v L="$logical" -v pre="$VALE_ANCHOR_PREFIX" -v suf="$VALE_ANCHOR_SUFFIX" '
    BEGIN{c=0}
    {
      p=$0
      if (p==pre SW suf || p==pre L suf) next
      if (tolower(p) ~ /anchor/) next
      c++
    }
    END{print c}
  ')"

  if [ "$non_anchor" -gt 0 ] && [ "$force" != "force" ]; then
    err "VALE $sw: ports non-anchor présents ($non_anchor). Utilise 'force' pour supprimer."
  fi

  # Détache tous les ports
  echo "$ports" | while read -r p; do
    [ -z "$p" ] && continue
    "$VALECTL" -d "${sw}:${p}" >/dev/null 2>&1 || true
  done
  info "VALE $sw supprimé (tous ports détachés)"
}

# Ajouter un membre (ifnet ou port netmap) à un switch VALE
#   $1 logical
#   $2 ifname_or_port
#   $3 mode: a|h (exclusif vs host-shared)
switch::vale::add_member(){
  logical="$1"; ifn="$2"; mode="${3:-h}"
  sw="$(switch::resolve_name vale "$logical")"
  need "$VALECTL"

  # Le switch "existe" dès qu'un port est attaché; sinon, on crée via anchor interne (-a)
  if ! switch::vale::exists "$sw"; then
    info "VALE $sw absent: création par anchor interne"
    switch::vale::create "$logical" "${VALE_ANCHOR_PREFIX}${logical}${VALE_ANCHOR_SUFFIX}" "a"
  fi

  case "$mode" in
    a) opt="-a" ;;  # créer un port netmap exclusif nommé $ifn
    h) opt="-h" ;;  # attacher un ifnet hôte existant
    *) err "mode VALE invalide (a|h)" ;;
  esac

  if [ "$opt" = "-h" ]; then
    ifconfig "$ifn" >/dev/null 2>&1 || err "interface $ifn introuvable (mode -h)"
  fi

  "$VALECTL" "$opt" "${sw}:${ifn}" >/dev/null
  info "VALE attach: ${sw}:${ifn} ($opt)"
}

# Retirer un membre du switch VALE
#   $1 logical
#   $2 ifname_or_port
switch::vale::remove_member(){
  logical="$1"; ifn="$2"
  sw="$(switch::resolve_name vale "$logical")"
  need "$VALECTL"

  if ! switch::vale::exists "$sw"; then
    warn "VALE $sw inexistant; rien à faire"
    return 0
  fi
  "$VALECTL" -d "${sw}:${ifn}" >/dev/null 2>&1 || warn "échec détachement (peut-être déjà absent): ${sw}:${ifn}"

  # Si plus aucun port → switch disparaît du kernel (c'est normal)
  info "VALE detach: ${sw}:${ifn}"
}

# Affichage "show" simple
switch::vale::show(){
  logical="$1"
  sw="$(switch::resolve_name vale "$logical")"
  ports="$(switch::vale::ports "$sw" || true)"
  if [ -z "$ports" ]; then
    echo "vale  ${sw}  MISSING  -"
  else
    echo "vale  ${sw}  PRESENT  $(echo "$ports" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  fi
}

# --- Netgraph helpers ----------------------------------------------------
# Le bridge "sw-<logical>" existe si un node "bridge" portant ce nom est présent
switch::netgraph::exists(){
  need "$NGCTL"
  sw="$1"
  # ngctl list -l : <name> <id> <type> ...
  if "$NGCTL" list -l | awk -v SW="$sw" '($2==SW && $3=="bridge"){ok=1} END{exit(ok?0:1)}'
  then return 0; fi
  return 1
}

# Liste des hooks linkN -> peer
switch::netgraph::hooks(){
  need "$NGCTL"
  sw="$1"
  "$NGCTL" show -n "${sw}:" 2>/dev/null | awk '
    /^hooks:/ {in=1; next}
    in && /^[[:space:]]*link[0-9]+:/ {
      gsub(/^[ \t]+/,"",$0); print $0
    }'
}

# Prochain linkN libre (lecture seule)
switch::netgraph::next_link(){
  need "$NGCTL"
  sw="$1"
  n=2
  while "$NGCTL" msg "${sw}:" getstats "link${n}" >/dev/null 2>&1; do n=$((n+1)); done
  echo "link${n}"
}

# Créer un bridge Netgraph "sw-<logical>"
# Options:
#   $1 logical
#   $2 anchor_if (optionnel, ex: n_<logical>_anchor). Si vide: bridge sans hook.
switch::netgraph::create(){
  logical="$1"
  anchor="${2:-}"
  sw="$(switch::resolve_name netgraph "$logical")"
  need "$NGCTL"

  if switch::netgraph::exists "$sw"; then
    info "Netgraph $sw déjà présent"
    return 0
  fi

  # Création du bridge via mkpeer (nécessite un peer initial)
  # On utilise une eiface temporaire pour créer le node 'bridge', qu'on nomme "sw-<logical>".
  "$NGCTL" mkpeer eiface ether ether >/dev/null
  ngeth="$("$NGCTL" list -l | awk '$3=="eiface"{print $2}' | tail -1)"
  next="$(switch::netgraph::next_link "$sw")"  # sw n'existe pas encore; next sera "link2"

  # Attacher eiface->bridge et nommer le bridge
  "$NGCTL" mkpeer "${ngeth}:" bridge ether "$next" >/dev/null
  "$NGCTL" name  "${ngeth}:ether" "$sw" >/dev/null

  if [ -n "$anchor" ]; then
    # On renomme l'eiface temporaire en anchor + l'active
    "$NGCTL" name "${ngeth}:" "$anchor" >/dev/null
    ifconfig "$ngeth" name "$anchor" up >/dev/null 2>&1 || true
    info "Netgraph $sw créé avec anchor $anchor ($next)"
  else
    # Pas d'anchor: on laisse le bridge, puis on supprime l'eiface
    "$NGCTL" shutdown "${ngeth}:" >/dev/null 2>&1 || true
    info "Netgraph $sw créé (sans hook)"
  fi
}

# Supprimer un bridge Netgraph
# - sans --force: refuse si des hooks linkN existent
# - avec  --force: shutdown du node sw-<logical>
#   $1 logical
#   $2 force ("force" pour suppression)
switch::netgraph::delete(){
  logical="$1"
  force="${2:-}"
  sw="$(switch::resolve_name netgraph "$logical")"
  need "$NGCTL"

  if ! switch::netgraph::exists "$sw"; then
    info "Netgraph $sw inexistant"
    return 0
  fi

  hooks="$(switch::netgraph::hooks "$sw" || true)"
  if [ -n "$hooks" ] && [ "$force" != "force" ]; then
    err "Netgraph $sw: hooks présents. Utilise 'force' pour supprimer."
  fi

  "$NGCTL" shutdown "${sw}:" >/dev/null 2>&1 || true
  info "Netgraph $sw supprimé"
}

# Ajouter un membre ifnet à un bridge Netgraph
#   $1 logical
#   $2 ifname (ex: ngethX, em0, tapY, ...)
switch::netgraph::add_member(){
  logical="$1"; ifn="$2"
  sw="$(switch::resolve_name netgraph "$logical")"
  need "$NGCTL"
  ifconfig "$ifn" >/dev/null 2>&1 || err "interface $ifn introuvable"

  if ! switch::netgraph::exists "$sw"; then
    # créer le bridge vide sans anchor
    switch::netgraph::create "$logical" ""
  fi

  link="$(switch::netgraph::next_link "$sw")"
  "$NGCTL" connect "${ifn}:" "${sw}:" ether "$link" >/dev/null 2>&1 || err "ngctl connect échoué ($ifn -> $sw:$link)"
  info "Netgraph attach: ${ifn} -> ${sw}:${link}"
}

# Retirer un membre (shutdown du node eiface si c'est un ngeth, ou déconnexion si noeud dédié)
#   $1 logical
#   $2 ifname
switch::netgraph::remove_member(){
  logical="$1"; ifn="$2"
  sw="$(switch::resolve_name netgraph "$logical")"
  need "$NGCTL"

  ifconfig "$ifn" >/dev/null 2>&1 || { warn "$ifn introuvable"; return 0; }

  # Tentative simple: shutdown du node (si c'est un node NG)
  "$NGCTL" shutdown "${ifn}:" >/dev/null 2>&1 || true
  info "Netgraph detach: ${ifn} (shutdown du node si applicable)"
}

# Affichage "show" simple
switch::netgraph::show(){
  logical="$1"
  sw="$(switch::resolve_name netgraph "$logical")"
  if switch::netgraph::exists "$sw"; then
    hooks="$(switch::netgraph::hooks "$sw" || true)"
    if [ -n "$hooks" ]; then
      echo "netgraph  ${sw}  PRESENT  $(echo "$hooks" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    else
      echo "netgraph  ${sw}  PRESENT  (no hooks)"
    fi
  else
    echo "netgraph  ${sw}  MISSING  -"
  fi
}

# --- façade générique ----------------------------------------------------
switch::create(){
  # $1 backend (vale|netgraph)
  # $2 logical
  # $3 anchor_name (optionnel)
  # $4 mode (vale: a|h ; netgraph: unused)
  case "$1" in
    vale)     switch::vale::create     "$2" "${3:-}" "${4:-a}" ;;
    netgraph) switch::netgraph::create "$2" "${3:-}" ;;
    *)        err "backend inconnu: $1" ;;
  esac
}

switch::delete(){
  # $1 backend
  # $2 logical
  # $3 "force" (optionnel)
  case "$1" in
    vale)     switch::vale::delete     "$2" "${3:-}" ;;
    netgraph) switch::netgraph::delete "$2" "${3:-}" ;;
    *)        err "backend inconnu: $1" ;;
  esac
}

switch::add_member(){
  # $1 backend
  # $2 logical
  # $3 ifname_or_port
  # $4 mode (VALE only: a|h)
  case "$1" in
    vale)     switch::vale::add_member     "$2" "$3" "${4:-h}" ;;
    netgraph) switch::netgraph::add_member "$2" "$3" ;;
    *)        err "backend inconnu: $1" ;;
  esac
}

switch::remove_member(){
  # $1 backend
  # $2 logical
  # $3 ifname_or_port
  case "$1" in
    vale)     switch::vale::remove_member     "$2" "$3" ;;
    netgraph) switch::netgraph::remove_member "$2" "$3" ;;
    *)        err "backend inconnu: $1" ;;
  esac
}

switch::show(){
  # $1 backend
  # $2 logical
  case "$1" in
    vale)     switch::vale::show     "$2" ;;
    netgraph) switch::netgraph::show "$2" ;;
    *)        err "backend inconnu: $1" ;;
  esac
}

switch::list(){
  # Liste courte des switches connus (à partir des backends inspectables)
  need "$VALECTL"; need "$NGCTL"
  echo "== VALE =="
  "$VALECTL" 2>/dev/null | awk -F: '{print $1}' | sort -u | sed 's/^/  /'
  echo "== NETGRAPH (bridges) =="
  "$NGCTL" list -l | awk '$3=="bridge"{print $2}' | sed 's/^/  /'
}

# --- CLI minimal ---------------------------------------------------------
if [ "${1:-}" = "__sourced__" ]; then
  return 0
fi

cmd="${1:-}"; shift || true
case "$cmd" in
  create)
    # switch.sh create <vale|netgraph> <logical> [anchor_name] [mode]
    backend="${1:-}"; logical="${2:-}"; anchor="${3:-}"; mode="${4:-}"
    [ -n "$backend" ] && [ -n "$logical" ] || err "Usage: $0 create <vale|netgraph> <logical> [anchor_name] [mode]"
    switch::create "$backend" "$logical" "$anchor" "$mode"
    ;;
  delete)
    # switch.sh delete <vale|netgraph> <logical> [force]
    backend="${1:-}"; logical="${2:-}"; force="${3:-}"
    [ -n "$backend" ] && [ -n "$logical" ] || err "Usage: $0 delete <vale|netgraph> <logical> [force]"
    switch::delete "$backend" "$logical" "$force"
    ;;
  add)
    # switch.sh add <vale|netgraph> <logical> <ifname_or_port> [mode]
    backend="${1:-}"; logical="${2:-}"; ifn="${3:-}"; mode="${4:-}"
    [ -n "$backend" ] && [ -n "$logical" ] && [ -n "$ifn" ] || err "Usage: $0 add <vale|netgraph> <logical> <ifname_or_port> [mode]"
    switch::add_member "$backend" "$logical" "$ifn" "$mode"
    ;;
  remove)
    # switch.sh remove <vale|netgraph> <logical> <ifname_or_port>
    backend="${1:-}"; logical="${2:-}"; ifn="${3:-}"
    [ -n "$backend" ] && [ -n "$logical" ] && [ -n "$ifn" ] || err "Usage: $0 remove <vale|netgraph> <logical> <ifname_or_port>"
    switch::remove_member "$backend" "$logical" "$ifn"
    ;;
  show)
    # switch.sh show <vale|netgraph> <logical>
    backend="${1:-}"; logical="${2:-}"
    [ -n "$backend" ] && [ -n "$logical" ] || err "Usage: $0 show <vale|netgraph> <logical>"
    switch::show "$backend" "$logical"
    ;;
  list)
    switch::list
    ;;
  ""|-h|--help|help)
    cat <<EOF
Usage:
  $0 create <vale|netgraph> <logical> [anchor_name] [mode]
     - VALE: mode a|h (défaut a). 'a' crée un port netmap exclusif (recommandé pour anchor)
  $0 delete <vale|netgraph> <logical> [force]
  $0 add    <vale|netgraph> <logical> <ifname_or_port> [mode]
     - VALE: mode a|h (a = port netmap exclusif, h = ifnet hôte)
  $0 remove <vale|netgraph> <logical> <ifname_or_port>
  $0 show   <vale|netgraph> <logical>
  $0 list

Notes:
  - VALE n'existe que s'il a ≥1 port: 'create' ajoute un anchor si nécessaire.
  - Netgraph peut exister sans hook; 'create' peut garder un anchor eiface si tu fournis un nom.
EOF
    ;;
  *)
    err "commande inconnue: $cmd"
    ;;
esac
