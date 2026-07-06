cat > /root/satip-ssdp-relay-helper.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

APP="SAT>IP SSDP Relay"
DEFAULT_CTID="350"
DEFAULT_HOSTNAME="satip-ssdp-relay"
DEFAULT_LXC_IP="192.168.0.225/24"
DEFAULT_GW="192.168.0.250"
DEFAULT_CLIENT_IP="192.168.178.20"
DEFAULT_RAM="256"
DEFAULT_DISK="2"

msg() { echo -e "\n[+] $*"; }
err() { echo -e "\n[!] $*" >&2; exit 1; }

command -v pct >/dev/null || err "Dieses Script muss auf dem Proxmox-Host laufen."

export DEBIAN_FRONTEND=noninteractive

if ! command -v whiptail >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y whiptail >/dev/null
fi

TITLE="$APP Installer"

CTID=$(whiptail --title "$TITLE" --inputbox "Container ID:" 8 60 "$DEFAULT_CTID" 3>&1 1>&2 2>&3)
HOSTNAME=$(whiptail --title "$TITLE" --inputbox "Hostname:" 8 60 "$DEFAULT_HOSTNAME" 3>&1 1>&2 2>&3)
LXC_IP=$(whiptail --title "$TITLE" --inputbox "LXC IP/CIDR im Octopus-Netz:" 8 70 "$DEFAULT_LXC_IP" 3>&1 1>&2 2>&3)
GATEWAY=$(whiptail --title "$TITLE" --inputbox "Gateway im Octopus-Netz:" 8 70 "$DEFAULT_GW" 3>&1 1>&2 2>&3)
CLIENT_IP=$(whiptail --title "$TITLE" --inputbox "Ziel-Client-IP im entfernten Netz:" 8 70 "$DEFAULT_CLIENT_IP" 3>&1 1>&2 2>&3)
RAM=$(whiptail --title "$TITLE" --inputbox "RAM in MB:" 8 50 "$DEFAULT_RAM" 3>&1 1>&2 2>&3)
DISK=$(whiptail --title "$TITLE" --inputbox "Disk in GB:" 8 50 "$DEFAULT_DISK" 3>&1 1>&2 2>&3)

BRIDGE_MENU=$(ip -o link show | awk -F': ' '/vmbr/ {print $2 " " $2}' | xargs)
[ -z "$BRIDGE_MENU" ] && err "Keine vmbr-Bridge gefunden."
BRIDGE=$(whiptail --title "$TITLE" --menu "Bridge wählen:" 15 70 8 $BRIDGE_MENU 3>&1 1>&2 2>&3)

ROOT_STORAGES=$(pvesm status -content rootdir | awk 'NR>1 {print $1 " " $1}' | xargs)
[ -z "$ROOT_STORAGES" ] && err "Kein Storage mit rootdir gefunden."
STORAGE=$(whiptail --title "$TITLE" --menu "LXC Storage wählen:" 15 70 8 $ROOT_STORAGES 3>&1 1>&2 2>&3)

TEMPLATE_STORAGE=$(pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -n1)
[ -z "$TEMPLATE_STORAGE" ] && TEMPLATE_STORAGE="local"

msg "Suche aktuelles Debian 12 Template..."
pveam update >/dev/null

TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)
[ -z "$TEMPLATE" ] && err "Kein Debian-12-Template gefunden."

if pct status "$CTID" >/dev/null 2>&1; then
  whiptail --title "$TITLE" --yesno "CTID $CTID existiert bereits. Löschen und neu erstellen?" 10 70 || exit 1
  pct stop "$CTID" >/dev/null 2>&1 || true
  pct destroy "$CTID" --purge >/dev/null
fi

whiptail --title "$TITLE" --yesno "LXC wird erstellt:

CTID:       $CTID
Hostname:   $HOSTNAME
LXC-IP:     $LXC_IP
Gateway:    $GATEWAY
Bridge:     $BRIDGE
Storage:    $STORAGE
Client-IP:  $CLIENT_IP
Template:   $TEMPLATE

Fortfahren?" 18 75 || exit 0

msg "Lade Template: $TEMPLATE"
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || true

msg "Erstelle privilegierten LXC..."
pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --rootfs "$STORAGE:$DISK" \
  --memory "$RAM" \
  --cores 1 \
  --net0 "name=eth0,bridge=$BRIDGE,ip=$LXC_IP,gw=$GATEWAY" \
  --unprivileged 0 \
  --features nesting=1 \
  --onboot 1 \
  --start 1

sleep 5

msg "Installiere udp-proxy-2020 per Release-Paket..."
pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

apt-get update
apt-get install -y ca-certificates curl jq libpcap0.8 tcpdump iproute2

DEB_URL=$(curl -fsSL https://api.github.com/repos/synfinatic/udp-proxy-2020/releases/latest \
  | jq -r ".assets[] | select(.name | test(\"amd64.*\\.deb$|x86_64.*\\.deb$|linux.*amd64.*\\.deb$\")) | .browser_download_url" \
  | head -n1)

if [ -z "$DEB_URL" ] || [ "$DEB_URL" = "null" ]; then
  echo "Kein amd64 .deb gefunden. Verfügbare Assets:"
  curl -fsSL https://api.github.com/repos/synfinatic/udp-proxy-2020/releases/latest | jq -r ".assets[].name"
  exit 1
fi

echo "Download: $DEB_URL"
curl -fL "$DEB_URL" -o /tmp/udp-proxy-2020.deb
dpkg -i /tmp/udp-proxy-2020.deb || apt-get -f install -y

BIN=$(command -v udp-proxy-2020 || true)
if [ -z "$BIN" ]; then
  BIN=$(find /usr /opt -type f -name udp-proxy-2020 2>/dev/null | head -n1)
fi

[ -n "$BIN" ] || { echo "udp-proxy-2020 Binary nicht gefunden"; exit 1; }

install -m 755 "$BIN" /usr/local/bin/udp-proxy-2020
/usr/local/bin/udp-proxy-2020 --help >/tmp/udp-proxy-help.txt 2>&1 || true
'

msg "Erstelle systemd Service..."
pct exec "$CTID" -- bash -lc "cat > /etc/systemd/system/udp-proxy-2020.service <<SERVICE
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
SERVICE

systemctl daemon-reload
systemctl enable --now udp-proxy-2020.service
"

msg "Fertig."

echo
echo "Status:"
pct exec "$CTID" -- systemctl status udp-proxy-2020.service --no-pager || true

echo
echo "Nächste Checks:"
echo "pct exec $CTID -- ping -c 3 $CLIENT_IP"
echo "pct exec $CTID -- journalctl -u udp-proxy-2020 -f"
echo "pct exec $CTID -- tcpdump -ni eth0 udp port 1900"
EOF

chmod +x /root/satip-ssdp-relay-helper.sh
/root/satip-ssdp-relay-helper.sh