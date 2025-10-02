#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2016 Matt Churchyard <churchers@gmail.com>
# SPDX-FileCopyrightText: 2025 g-Projets

[ -r "${BASE_DIR}/lib/config_yaml.sh" ] && . "${BASE_DIR}/lib/config_yaml.sh"

VALECTL="${VALECTL:-valectl}"
NGCTL="${NGCTL:-ngctl}"

switch::resolve_name(){ # backend logical
  case "$1" in
    vale)     echo "vale-$2" ;;
    netgraph) echo "sw-$2" ;;
    *) echo "$2" ;;
  esac
}

# ---------- Lecture (déjà présentes chez toi, rappel) ----------
switch::vale::ports(){ $VALECTL 2>/dev/null | awk -F: -v SW="$1" '($1==SW){print $2}'; }
switch::netgraph::exists(){ $NGCTL list -l 2>/dev/null | awk -v SW="$1" '($2==SW && $3=="bridge"){ok=1} END{exit(ok?0:1)}'; }
switch::netgraph::hooks(){ $NGCTL show -n "${1}:" 2>/dev/null | awk '/^hooks:/{in=1;next} in && /^[[:space:]]*link[0-9]+:/{gsub(/^[ \t]+/,"",$0);print $0}'; }
switch::netgraph::next_link(){ n=2; while $NGCTL msg "${1}:" getstats "link${n}" >/dev/null 2>&1; do n=$((n+1)); done; echo "link${n}"; }

# ---------- Création switch ----------
switch::create(){ # backend logical [anchor] [mode(a|h)] ; pour VALE mode utile si on ancre
  backend="$1"; logical="$2"; anchor="${3:-}"; mode="${4:-a}"
  sw="$(switch::resolve_name "$backend" "$logical")"
  case "$backend" in
    vale)
      # VALE: existence = au moins 1 port ; on préfère créer une ancre si fournie
      [ -n "$anchor" ] && $VALECTL -a "${sw}:${anchor}" >/dev/null 2>&1 || true
      config_yaml::upsert_switch "$logical" "vale"
      [ -n "$anchor" ] && config_yaml::add_interface "$logical" "$anchor" "a"
      ;;
    netgraph)
      # Netgraph: crée un bridge nommé via un eiface anchor (obligatoire techniquement)
      if ! switch::netgraph::exists "$sw"; then
        kldload -nq ng_ether ng_bridge || true
        $NGCTL mkpeer eiface ether ether >/dev/null
        ngeth="$($NGCTL list -l | awk '$3=="eiface"{print $2}' | tail -1)"
        link="$(switch::netgraph::next_link "$sw")"
        $NGCTL mkpeer "${ngeth}:" bridge ether "$link" >/dev/null
        $NGCTL name  "${ngeth}:ether" "$sw" >/dev/null
        # on garde ngeth comme ancre si nom donné, sinon on laisse anonyme (non requis)
        if [ -n "$anchor" ]; then
          $NGCTL name "${ngeth}:" "$anchor" >/dev/null 2>&1 || true
        fi
      fi
      config_yaml::upsert_switch "$logical" "netgraph"
      [ -n "$anchor" ] && config_yaml::add_interface "$logical" "$anchor" "a"
      ;;
    *) return 1 ;;
  esac
}

# ---------- Suppression switch ----------
switch::delete(){ # backend logical [force]
  backend="$1"; logical="$2"; force="${3:-}"
  sw="$(switch::resolve_name "$backend" "$logical")"
  case "$backend" in
    vale)
      # VALE: pas de notion de switch vide → on ne force pas ici
      # on signale: il faut détacher tous les ports (valectl -d sw:port) ailleurs.
      # MAJ YAML (on conserve le bloc pour la cohérence, ou à toi de décider)
      return 0
      ;;
    netgraph)
      if switch::netgraph::exists "$sw"; then
        if [ -n "$force" ]; then
          # Tentative: rmhook de tous les hooks, puis shutdown du node bridge
          hooks="$(switch::netgraph::hooks "$sw" || true)"
          if [ -n "$hooks" ]; then
            echo "$hooks" | awk -F: '{print $1}' | while read -r h; do
              [ -n "$h" ] && $NGCTL rmhook "${sw}:" "$h" >/dev/null 2>&1 || true
            done
          fi
          $NGCTL shutdown "${sw}:" >/dev/null 2>&1 || true
        else
          echo "Refuser delete sans --force: hooks présents potentiellement." >&2
          return 1
        fi
      fi
      ;;
  esac
}

# ---------- Attacher ----------
switch::add_member(){ # backend logical ifname mode(a|h)
  backend="$1"; logical="$2"; ifn="$3"; mode="${4:-h}"
  sw="$(switch::resolve_name "$backend" "$logical")"
  case "$backend" in
    vale)
      case "$mode" in
        a) $VALECTL -a "${sw}:${ifn}" >/dev/null ;;
        h) $VALECTL -h "${sw}:${ifn}" >/dev/null ;;
        *) echo "mode invalide (vale): $mode" >&2; return 1 ;;
      esac
      config_yaml::add_interface "$logical" "$ifn" "$mode"
      ;;
    netgraph)
      kldload -nq ng_ether ng_bridge || true
      if ! switch::netgraph::exists "$sw"; then
        # créer le bridge à la volée (avec eiface anchor technique)
        switch::create "netgraph" "$logical"
      fi
      link="$(switch::netgraph::next_link "$sw")"
      case "$mode" in
        a)
          # créer un eiface nommé ifn et le connecter
          $NGCTL mkpeer eiface ether ether >/dev/null
          ngeth="$($NGCTL list -l | awk '$3=="eiface"{print $2}' | tail -1)"
          $NGCTL name "${ngeth}:" "$ifn" >/dev/null 2>&1 || true
          $NGCTL connect "${ifn}:" "${sw}:" ether "$link" >/dev/null
          ;;
        h)
          # ifn doit exister comme ifnet (em0/ngethX/…)
          if ! ifconfig "$ifn" >/dev/null 2>&1; then
            echo "ifnet inexistant pour mode=h: $ifn" >&2
            return 1
          fi
          $NGCTL connect "${ifn}:" "${sw}:" ether "$link" >/dev/null
          ;;
        *) echo "mode invalide (netgraph): $mode" >&2; return 1 ;;
      esac
      config_yaml::add_interface "$logical" "$ifn" "$mode"
      ;;
    *) return 1 ;;
  esac
}

# ---------- Détacher ----------
switch::remove_member(){ # backend logical ifname
  backend="$1"; logical="$2"; ifn="$3"
  sw="$(switch::resolve_name "$backend" "$logical")"
  case "$backend" in
    vale)
      # on tente le detach avec -d; si le port n’existe pas, exit 0
      $VALECTL -d "${sw}:${ifn}" >/dev/null 2>&1 || true
      config_yaml::remove_interface "$logical" "$ifn" || true
      ;;
    netgraph)
      # si c’est un eiface (anchor), on peut le shutdown proprement
      if $NGCTL list -l 2>/dev/null | awk -v IF="$ifn" '($2==IF && $3=="eiface"){ok=1} END{exit(ok?0:1)}'; then
        $NGCTL shutdown "${ifn}:" >/dev/null 2>&1 || true
      else
        # ifnet partagé: rmhook entre IF: et sw:
        # on essaie de trouver sur sw: le hook linkN connecté à IF:
        hooks="$(switch::netgraph::hooks "$sw" || true)"
        target=""
        for h in $hooks; do
          hn="${h%:}"
          # test par getstats (si ok, on rmhook côté sw)
          if $NGCTL msg "${sw}:" getstats "$hn" >/dev/null 2>&1; then
            $NGCTL rmhook "${sw}:" "$hn" >/dev/null 2>&1 || true
          fi
        done
      fi
      config_yaml::remove_interface "$logical" "$ifn" || true
      ;;
  esac
}
