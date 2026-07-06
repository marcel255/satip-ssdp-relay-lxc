#!/usr/bin/env bash
set -Eeuo pipefail

APP="SAT>IP SSDP Relay"
DEFAULT_CTID="350"
DEFAULT_HOSTNAME="satip-ssdp-relay"
DEFAULT_CLIENT_IP="192.168.178.20"
DEFAULT_LXC_IP="192.168.0.225/24"
DEFAULT_GW="192.168.0.250"
DEFAULT_RAM="256"
DEFAULT_DISK="2"

msg() { echo -e "\n[+] $*"; }
err() { echo -e "\n[!] $*" >&2; exit 1; }

command -v pct >/dev/null || err "Dieses Script muss auf dem Proxmox-Host laufen."

apt-get update -qq
apt-get install -y whiptail curl wget git jq >/dev/null

CTID=$(whiptail --inputbox "Container ID:" 8 50 "$DEFAULT_CTID" 3>&1 1>&2 2>&3)
HOSTNAME=$(whiptail --inputbox "Hostname:" 8 50 "$DEFAULT_HOSTNAME" 3>&1 1>&2 2>&3)
CLIENT_IP=$(whiptail --inputbox "Ziel-Client-IP im entfernten Netz:" 8 60 "$DEFAULT_CLIENT_IP" 3>&1 1>&2 2>&3)
LXC_IP=$(whiptail --inputbox "LXC IP/CIDR im Octopus-Netz:" 8 60 "$DEFAULT_LXC_IP" 3>&1 1>&2 2>&3)
GATEWAY=$(whiptail --inputbox "Gateway im Octopus-Netz:" 8 60 "$DEFAULT_GW" 3>&1 1>&2 2>&3)
RAM=$(whiptail --inputbox "RAM in MB:" 8 40 "$DEFAULT_RAM" 3>&1 1>&2 2>&3)
DISK=$(whiptail --inputbox "Disk in GB:" 8 40 "$DEFAULT_DISK" 3>&1 1>&2 2>&3)

BRIDGES=$(ip -o link show | awk -F': ' '/vmbr/ {print $2 " " $2}' | xargs)
BRIDGE=$(whiptail --menu "Bridge wählen:" 15 60 6 $BRIDGES 3>&1 1>&2 2>&3)

STORAGES=$(pvesm status -content rootdir | awk 'NR>1 {print $1 " " $1}' | xargs)
STORAGE=$(whiptail --menu "Storage für LXC wählen:" 15 60 6 $STORAGES 3>&1 1>&2 2>&3)

TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 {print $1 " " $1}' | head -n1 | awk '{print $1}')
[ -z "$TEMPLATE_STORAGE" ] && TEMPLATE_STORAGE="local"

msg "Suche aktuelles Debian 12 Template..."
pveam update >/dev/null

TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)
[ -z "$TEMPLATE" ] && err "Kein Debian-12-Template gefunden."

msg "Lade Template: $TEMPLATE"
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || true

whiptail --yesno "LXC erstellen?

CTID:      $CTID
Hostname:  $HOSTNAME
IP:        $LXC_IP
Gateway:   $GATEWAY
Bridge:    $BRIDGE
Storage:   $STORAGE
Client:    $CLIENT_IP
Template:  $TEMPLATE

Fortfahren?" 18 70 || exit 0

pct status "$CTID" &>/dev/null && err "CTID $CTID existiert bereits."

msg "Erstelle LXC..."
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --storage "$STORAGE" \
  --rootfs "$STORAGE:$DISK" \
  --memory "$RAM" \
  --cores 1 \
  --net0 "name=eth0,bridge=$BRIDGE,ip=$LXC_IP,gw=$GATEWAY" \
  --unprivileged 0 \
  --features nesting=1 \
  --onboot 1 \
  --start 1

sleep 5

msg "Installiere Pakete im LXC..."
pct exec "$CTID" -- bash -lc '
set -e
apt-get update
apt-get install -y git build-essential libpcap-dev golang-go tcpdump iproute2 ca-certificates
'

msg "Installiere udp-proxy-2020..."
pct exec "$CTID" -- bash -lc '
set -e
rm -rf /opt/udp-proxy-2020
git clone https://github.com/synfinatic/udp-proxy-2020.git /opt/udp-proxy-2020
cd /opt/udp-proxy-2020
make
install -m 755 udp-proxy-2020 /usr/local/bin/udp-proxy-2020
'

msg "Erstelle systemd Service..."
pct exec "$CTID" -- bash -lc "cat > /etc/systemd/system/udp-proxy-2020.service" <<EOF
[Unit]
Description=udp-proxy-2020 SATIP SSDP Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp-proxy-2020 --port 1900 --interface eth0 --fixed-ip eth0@$CLIENT_IP --level info
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now udp-proxy-2020.service

msg "Fertig."

echo
echo "Status:"
pct exec "$CTID" -- systemctl status udp-proxy-2020.service --no-pager || true

echo
echo "Logs:"
echo "pct exec $CTID -- journalctl -u udp-proxy-2020 -f"

echo
echo "SSDP Traffic prüfen:"
echo "pct exec $CTID -- tcpdump -ni eth0 udp port 1900"

echo
echo "Client erreichbar?"
echo "pct exec $CTID -- ping -c 3 $CLIENT_IP"