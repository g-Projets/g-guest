g-guest (minimal bundle)
========================

This archive contains a minimal, self-contained starter of g-guest:
- bin/router.sh     : BSDRP VM orchestrator (bhyve)
- bin/segments.sh   : VALE & Netgraph segments manager
- bin/topology.sh   : Backup/Restore topology YAML (with SHA256)
- lib/access.sh     : PF NAT, netgraph attach, SSH helper
- rc.d/g_guest_segments : rc.d script to ensure segments on boot
- config/router.yaml, config/networks.yaml : templates to start

Quick install
-------------
# as root
install -d /usr/local/g-guest/{bin,lib,config,backups,logs}
cp -a g-guest/bin/*.sh /usr/local/g-guest/bin/
cp -a g-guest/lib/*.sh /usr/local/g-guest/lib/
cp -a g-guest/config/*.yaml /usr/local/g-guest/config/
install -m 0755 g-guest/rc.d/g_guest_segments /usr/local/etc/rc.d/g_guest_segments

chmod 0755 /usr/local/g-guest/bin/*.sh /usr/local/g-guest/lib/*.sh
chmod 0644 /usr/local/g-guest/config/*.yaml

sysrc g_guest_segments_enable=YES
service g_guest_segments start

Segments then router:
  /usr/local/g-guest/bin/segments.sh ensure
  /usr/local/g-guest/bin/router.sh apply
  /usr/local/g-guest/lib/access.sh up
