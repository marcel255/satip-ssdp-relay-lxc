#!/usr/bin/env bash
set -Eeuo pipefail

APP="SAT>IP SSDP Relay"
DEFAULT_CTID="350"
DEFAULT_HOSTNAME="satip-ssdp-relay"
DEFAULT_LXC_IP="192.168.0.225/24"
DEFAULT_GATEWAY="192.168.0.250"
DEFAULT_CLIENT_IP="192.168.178.20"
DEFAULT_RAM="256"
DEFAULT_DISK="2"

msg() { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*" >&2; }
die() { echo -e "\n[FEHLER] $*" >&2; exit 1; }

command -v pct >/dev/null 2>&1 || die "Dieses Script muss direkt auf dem Proxmox-Host laufen."

export DEBIAN_FRONTEND=noninteractive

msg "Installiere Helper-Abhängigkeiten auf Proxmox..."
apt-get update -qq
apt-get install -y whiptail curl ca-certificates >/dev/null

TITLE="$APP Installer"

ask_input() {
  local text="$1"
  local default="$2"
  whiptail --title "$TITLE" --inputbox "$text" 8 70 "$default" 3>&1 1>&2 2>&3
}

CTID="$(ask_input "Container-ID:" "$DEFAULT_CTID")"
HOSTNAME="$(ask_input "Hostname:" "$DEFAULT_HOSTNAME")"
LXC_IP="$(ask_input "LXC-IP/CIDR im Octopus-Netz:" "$DEFAULT_LXC_IP")"
GATEWAY="$(ask_input "Gateway im Octopus-Netz:" "$DEFAULT_GATEWAY")"
CLIENT_IP="$(ask_input "Ziel-Client-IP im entfernten Netz:" "$DEFAULT_CLIENT_IP")"
RAM="$(ask_input "RAM in MB:" "$DEFAULT_RAM")"
DISK="$(ask_input "Disk in GB:" "$DEFAULT_DISK")"

BRIDGE_MENU="$(ip -o link show | awk -F': ' '/vmbr/ {print $2 " " $2}' | xargs || true)"
[ -n "$BRIDGE_MENU" ] || die "Keine Proxmox-Bridge wie vmbr0 gefunden."
BRIDGE="$(whiptail --title "$TITLE" --menu "Bridge auswählen:" 15 70 8 $BRIDGE_MENU 3>&1 1>&2 2>&3)"

STORAGE_MENU="$(pvesm status -content rootdir | awk 'NR>1 {print $1 " " $1}' | xargs || true)"
[ -n "$STORAGE_MENU" ] || die "Kein Storage mit rootdir gefunden."
STORAGE="$(whiptail --title "$TITLE" --menu "LXC-Storage auswählen:" 15 70 8 $STORAGE_MENU 3>&1 1>&2 2>&3)"

TEMPLATE_STORAGE="$(pvesm status -content vztmpl | awk 'NR>1 {print $1}' | head -n1 || true)"
[ -n "$TEMPLATE_STORAGE" ] || TEMPLATE_STORAGE="local"

msg "Suche aktuelles Debian-12-LXC-Template..."
pveam update >/dev/null

TEMPLATE="$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n1)"
[ -n "$TEMPLATE" ] || die "Kein Debian-12-Template gefunden."

if pct status "$CTID" >/dev/null 2>&1; then
  whiptail --title "$TITLE" --yesno "CTID $CTID existiert bereits.

Soll dieser Container gelöscht und neu erstellt werden?" 10 70 || die "Abgebrochen."
  msg "Stoppe und lösche bestehenden CT $CTID..."
  pct stop "$CTID" >/dev/null 2>&1 || true
  pct destroy "$CTID" --purge
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

Fortfahren?" 18 78 || die "Abgebrochen."

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

msg "Setze Container-Optionen für Packet-Capture..."
{
  echo "lxc.apparmor.profile: unconfined"
} >> "/etc/pve/lxc/${CTID}.conf"

pct restart "$CTID"
sleep 5

msg "Installiere Abhängigkeiten im LXC..."
pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  git \
  jq \
  build-essential \
  libpcap-dev \
  libpcap0.8 \
  tcpdump \
  iproute2
'

msg "Installiere aktuelle Go-Version im LXC..."
pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail
export LC_ALL=C

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
  amd64) GOARCH="amd64" ;;
  arm64) GOARCH="arm64" ;;
  *) echo "Nicht unterstützte Architektur: $ARCH"; exit 1 ;;
esac

GO_FILE="$(curl -fsSL "https://go.dev/dl/?mode=json" \
  | jq -r --arg arch "$GOARCH" \
  ".[0].files[] | select(.os == \"linux\" and .arch == \$arch and .kind == \"archive\") | .filename" \
  | head -n1)"

[ -n "$GO_FILE" ] || { echo "Konnte Go-Download nicht bestimmen."; exit 1; }

echo "Lade $GO_FILE"
curl -fL "https://go.dev/dl/${GO_FILE}" -o /tmp/go.tar.gz

rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz

/usr/local/go/bin/go version
'

msg "Baue udp-proxy-2020 aus Source..."
pct exec "$CTID" -- bash -lc '
set -Eeuo pipefail
export PATH="/usr/local/go/bin:$PATH"
export LC_ALL=C

rm -rf /opt/udp-proxy-2020
git clone https://github.com/synfinatic/udp-proxy-2020.git /opt/udp-proxy-2020

cd /opt/udp-proxy-2020

if [ -f Makefile ]; then
  make
else
  go build -o udp-proxy-2020 .
fi

BIN="$(find /opt/udp-proxy-2020 -type f -name udp-proxy-2020 -perm -111 | head -n1 || true)"

if [ -z "$BIN" ]; then
  echo "Binary nicht gefunden. Build-Inhalt:"
  find /opt/udp-proxy-2020 -maxdepth 3 -type f
  exit 1
fi

install -m 755 "$BIN" /usr/local/bin/udp-proxy-2020

/usr/local/bin/udp-proxy-2020 --help >/tmp/udp-proxy-2020-help.txt 2>&1 || true
/usr/local/bin/udp-proxy-2020 --version || true
'

msg "Erstelle systemd-Service..."
pct exec "$CTID" -- bash -lc "cat > /etc/systemd/system/udp-proxy-2020.service <<EOF
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

systemctl daemon-reload
systemctl enable --now udp-proxy-2020.service
"

msg "Installation fertig."

echo
echo "Status:"
pct exec "$CTID" -- systemctl status udp-proxy-2020.service --no-pager || true

echo
echo "Prüfbefehle:"
echo "pct exec $CTID -- ping -c 3 $CLIENT_IP"
echo "pct exec $CTID -- journalctl -u udp-proxy-2020 -f"
echo "pct exec $CTID -- tcpdump -ni eth0 udp port 1900"
echo
echo "Wenn VLC nichts findet, zuerst tcpdump prüfen."