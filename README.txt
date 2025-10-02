g-guest (minimal bundle)
========================

This archive contains a minimal, self-contained starter of g-guest:

g-guest/
├── bin/
│   ├── switchctl           # CLI gestion des switches VALE/Netgraph (create/add/remove/show/list/ensure, ng-ifadd)
│   ├── segments.sh         # Lecture seule: états des segments (OK/EMPTY/MISSING), diff config↔système
│   └── router.sh           # Gestion du routeur BSDRP (VM bhyve) + plan segments côté routeur
│   └── topology.sh         # Backup et Restore du config.
├── lib/
│   ├── switch.sh           # Implémentation backend (VALE/Netgraph) + attach/detach + MAJ YAML
│   ├── config_yaml.sh      # Upsert YAML: switch & interfaces (idempotent)
│   └── access.sh           # (optionnel) helpers PF/ssh/ngctl communs
├── config/
│   ├── networks.yaml       # Définition des switches + interfaces (name/mode a|h)
│   └── router.yaml         # Définition du routeur (image, CPU/RAM, disques, segments à attacher)
├── logs/                   # Journaux (créé à l’usage)
├── var/
│   └── run/                # Fichiers runtime
│       └── ngmap_*.db      # Mapping persistant ifname↔linkN (Netgraph) par logical
├── man/
│   └── man8/
│       ├── switchctl.8     # Page de man pour switchctl(8)
│       ├── segments.8      # Page de man pour segments.sh(8)
│       └── router.8        # Page de man pour router.sh(8)
└── README.md               # Présentation rapide + exemples d’usage


# en root
make install
make enable
make start

# maintenance
make restart
make status
make uninstall

sysrc g_guest_segments_enable=YES
sysrc g_guest_router_enable=YES
service g-guest_segments start
service g-guest_router start
