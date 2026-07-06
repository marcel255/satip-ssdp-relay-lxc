#!/usr/bin/env bash
set -e

clear
echo "SAT>IP SSDP Relay LXC Installer - udp-proxy-2020"
echo

read -rp "CTID [225]: " CTID
CTID=${CTID:-225}

read -rp "Hostname [satip-ssdp-relay]: " HOSTNAME
HOSTNAME=${HOSTNAME:-satip-ssdp-relay}

read -rp "Storage [local-lvm]: " STORAGE
STORAGE=${STORAGE:-local-lvm}

read -rp "Template Storage [local]: " TEMPLATE_STORAGE
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-local}

read -rp "Bridge [vmbr0]: " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

read -rp "LXC IP/CIDR im Octopus-Netz [192.168.0.225/24]: " LXC_IP
LXC_IP=${LXC_IP:-192.168.0.225/24}

read -rp "Gateway [192.168.0.1]: " GATEWAY
GATEWAY=${GATEWAY:-192.168.0.1}

read -rp "Ziel-Client IP im entfernten Netz [192.168.25.4]: " CLIENT_IP
CLIENT_IP=${CLIENT_IP:-192.168.25.4}

read -rp "Interface im LXC [eth0]: " IFACE
IFACE=${IFACE:-eth0}

read -rp "RAM MB [256]: " RAM
RAM=${RAM:-256}

read -rp "Disk GB [2]: " DISK
DISK=${DISK:-2}

TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"

echo
echo "Konfiguration:"
echo "CTID:        $CTID"
echo "Hostname:    $HOSTNAME"
echo "IP:          $LXC_IP"
echo "Gateway:     $GATEWAY"
echo "Bridge:      $BRIDGE"
echo "Client:      $CLIENT_IP"
echo "Interface:   $IFACE"
echo
read -rp "Fortfahren? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1

pveam update
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" || true

pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --storage "$STORAGE" \
  --rootfs "$STORAGE:$DISK" \
  --memory "$RAM" \
  --cores 1 \
  --net0 name=eth0,bridge="$BRIDGE",ip="$LXC_IP",gw="$GATEWAY" \
  --unprivileged 0 \
  --features nesting=1 \
  --onboot 1 \
  --start 1

sleep 5

pct exec "$CTID" -- bash -c "
apt update
apt install -y git build-essential libpcap-dev golang-go tcpdump iproute2 ca-certificates
cd /opt
git clone https://github.com/synfinatic/udp-proxy-2020.git
cd udp-proxy-2020
make
install -m 755 udp-proxy-2020 /usr/local/bin/udp-proxy-2020
"

pct exec "$CTID" -- bash -c "cat > /etc/systemd/system/udp-proxy-2020.service" <<EOF
[Unit]
Description=udp-proxy-2020 SAT>IP SSDP Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/udp-proxy-2020 --port 1900 --interface $IFACE --fixed-ip $IFACE@$CLIENT_IP --level info
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now udp-proxy-2020.service

echo
echo "Fertig."
echo
echo "Status:"
pct exec "$CTID" -- systemctl status udp-proxy-2020.service --no-pager
echo
echo "Logs:"
echo "pct exec $CTID -- journalctl -u udp-proxy-2020 -f"
echo
echo "Traffic prüfen:"
echo "pct exec $CTID -- tcpdump -ni $IFACE udp port 1900"