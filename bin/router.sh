#!/bin/sh
# g-guest - router orchestrator (BSDRP in bhyve)
# Commands:
#   apply       # prepare disk from .img.xz and start VM
#   start       # start VM (expects prepared disk)
#   stop        # stop/destroy VM
#   status      # show VM status
#   console [-w]# cu to nmdm console (wait if -w)
# Env (or YAML): see config/router.yaml

set -eu

BASE_DIR="${BASE_DIR:-/usr/local/g-guest}"
CFG_DIR="${CFG_DIR:-$BASE_DIR/config}"
ROUTER_YAML="${ROUTER_YAML:-$CFG_DIR/router.yaml}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need awk; need sed; need tr

yaml_get_one(){
  # $1 path (e.g., router.name)
  awk -v key="$1" -F. '
    function ltrim(s){sub(/^[[:space:]]+/,"",s);return s}
    function rtrim(s){sub(/[[:space:]]+$/,"",s);return s}
    function trim(s){return rtrim(ltrim(s))}
    {
      if($0 ~ /^[[:space:]]*#/){next}
      if($0 ~ /^[[:space:]]*$/){next}
      gsub(":"," : ")
      for(i=1;i<=NF;i++) if($i==":") {$i=" : "}
      line=$0
      # flatten router.xxx: value
      if($1==parts[1] && depth==0){depth=1}
    }
    BEGIN{
      n=split(key,parts,".")
      depth=0
    }
    {
      if(depth==0 && $1==parts[1] && $2==":"){depth=1; next}
      if(depth==1 && n==2 && $1==parts[2] && $2==":"){
        # print value (col3..end)
        for(i=3;i<=NF;i++){printf "%s%s",$i,(i<NF?" ":"")}
        print ""
        exit
      }
      if(depth==0 && n==1 && $1==parts[1] && $2==":"){
        for(i=3;i<=NF;i++){printf "%s%s",$i,(i<NF?" ":"")}
        print ""
        exit
      }
    }
  ' "$ROUTER_YAML"
}

name="$(yaml_get_one router.name)"
workdir="$(yaml_get_one router.workdir)"
image_xz="$(yaml_get_one router.image)"
ram="$(yaml_get_one router.ram)"
cpus="$(yaml_get_one router.cpus)"
boot="$(yaml_get_one router.boot)"
console_type="$(yaml_get_one router.console)"
root_backend="$(yaml_get_one router.root_backend)"
nic_driver="$(yaml_get_one router.network_driver)"
reserve_slots="$(yaml_get_one router.nic_reserve_slots)"

: "${name:?router.name missing}"
: "${workdir:?router.workdir missing}"
: "${image_xz:?router.image missing}"
: "${ram:=2G}"
: "${cpus:=2}"
: "${boot:=uefi}"
: "${console_type:=nmdm}"
: "${root_backend:=virtio-blk}"
: "${nic_driver:=virtio-net}"
: "${reserve_slots:=2}"

disk0="${workdir}/disk0.img"
nmdm="nmdm-${name}"

# --- helpers ---
ng_next_link(){
  sw="$1"; n=2
  while ngctl msg "${sw}:" getstats "link${n}" >/dev/null 2>&1; do n=$((n+1)); done
  echo "link${n}"
}
mac_from_name(){
  # stable MAC from string
  s="$1"
  prefix="58:9c:fc"
  h="$(echo -n "$s" | sha1 | tr -d '\n' | cut -c1-6)"
  echo "${prefix}:$(echo "$h" | sed 's/../&:/g; s/:$//')"
}
ensure_console(){
  kldload -nq nmdm || true
  # device created on first open by cu; nothing to do otherwise
}
ensure_workdir(){ mkdir -p "$workdir"; }

parse_nics(){
  # prints lines: id backend switch mac
  awk '
    $1=="nics:" {in=1; next}
    in && $1=="-" {ni=1; id=backend=switch=mac=""}
    in && $1=="id:" {id=$2}
    in && $1=="backend:" {backend=$2}
    in && $1=="switch:" {switch=$2}
    in && $1=="mac:" {mac=$2}
    ni && ($0 ~ /^\s*$/ || $1=="-") {
      if(id!="") print id,backend,switch,(mac==""?"auto":mac)
      if($1!="-") {in=0}
    }
    END{ if(in && id!="") print id,backend,switch,(mac==""?"auto":mac) }
  ' "$ROUTER_YAML"
}

build_net_devices(){
  # stdout: appended -s ... for each NIC
  bus=2; slot=0; func=0
  emu="$nic_driver"
  parse_nics | while read -r id backend sw mac; do
    case "$backend" in
      netgraph)
        swname="sw-${sw}"
        link="$(ng_next_link "$swname")"
        spec="netgraph,path=${swname}:,peerhook=${link}"
        ;;
      vale)
        swname="vale-${sw}"
        port="${name}-${id}"
        spec="${swname}:${port}"
        ;;
      *) echo "ERROR: unknown backend $backend" >&2; exit 1 ;;
    esac
    [ "$mac" = "auto" ] && mac="$(mac_from_name "${name}-${id}")"
    echo -n " -s ${bus}:${slot}:${func},${emu},${spec},mac=${mac}"
    func=$((func+1))
    if [ $func -gt 7 ]; then func=0; slot=$((slot+1)); fi
    if [ $slot -gt 7 ]; then slot=0; bus=$((bus+1)); fi
  done
  # reserve empty slots if requested
  r="$reserve_slots"
  while [ "$r" -gt 0 ]; do
    echo -n " -s ${bus}:${slot}:${func},${emu}"
    func=$((func+1)); if [ $func -gt 7 ]; then func=0; slot=$((slot+1)); fi
    if [ $slot -gt 7 ]; then slot=0; bus=$((bus+1)); fi
    r=$((r-1))
  done
}

build_disk_device(){
  case "$root_backend" in
    virtio-blk) echo "-s 1:0,virtio-blk,${disk0}" ;;
    nvme)       echo "-s 1:0,nvme,${disk0}" ;;
    ahci-hd)    echo "-s 1:0,ahci-hd,${disk0}" ;;
    *)          echo "-s 1:0,virtio-blk,${disk0}" ;;
  esac
}

prepare_disk(){
  ensure_workdir
  if [ ! -f "$disk0" ]; then
    echo "Preparing disk0.img from ${image_xz}..."
    need xz
    xz -dc "$image_xz" > "$disk0"
    chmod 600 "$disk0"
  else
    echo "disk0.img already present."
  fi
}

start_vm(){
  [ -e "/dev/vmm/${name}" ] && { echo "VM already running"; return 0; }
  ensure_console
  kldload -nq vmm || true
  # common
  NET_DEVICES="$(build_net_devices)"
  DISK_DEVICE="$(build_disk_device)"
  COMMON="-c cpus=${cpus} -S -m ${ram} -s 0:0,hostbridge -A -H -P -s 0:1,lpc -l com1,/dev/${nmdm}A"
  [ "$boot" = "uefi" ] && BOOT="-l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd" || BOOT=""
  if [ "$boot" = "bios" ]; then
    need bhyveload
    bhyveload -S -m "$ram" -d "$disk0" -c "/dev/${nmdm}A" "$name"
  fi
  set +e
  bhyve ${COMMON} ${BOOT} ${DISK_DEVICE} ${NET_DEVICES} "$name"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "bhyve exited rc=$rc"
  fi
}

stop_vm(){
  if [ -e "/dev/vmm/${name}" ]; then
    bhyvectl --destroy --vm="$name" || true
    pkill -f "cu -l /dev/${nmdm}B" || true
    echo "VM destroyed."
  else
    echo "VM not running."
  fi
}

status_vm(){
  if [ -e "/dev/vmm/${name}" ]; then
    echo "RUNNING"
  else
    echo "STOPPED"
  fi
}

console_vm(){
  wait="${1:-}"
  if [ "$wait" = "-w" ]; then
    i=0; while [ ! -e "/dev/vmm/${name}" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
  fi
  cu -l "/dev/${nmdm}B"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  apply) prepare_disk; start_vm ;;
  start) start_vm ;;
  stop)  stop_vm ;;
  status) status_vm ;;
  console) console_vm "${1:-}" ;;
  *) echo "Usage: $0 {apply|start|stop|status|console [-w]}" >&2; exit 1 ;;
esac
