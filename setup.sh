#!/bin/bash
set -euo pipefail
cd "$(dirname $0)"

echo "=== prepare user trustant ==="

sudo apt-get update && sudo apt-get install -y iptables zstd binutils

sudo userdel trustant || true
sudo groupdel trustant || true
sudo rm -Rvf /home/trustant
sudo groupadd -g 769 trustant || true
sudo useradd -u 769 -g trustant -m -d /home/trustant -s /bin/bash trustant || true
sudo mkdir -p /home/trustant/workspace
sudo chown -R trustant:trustant /home/trustant

echo "=== install ops ==="

curl -sL n7s.co/get-ops-tru | bash
sudo mv ~/.local/bin/ops /usr/bin/ops
sudo chown root:root /usr/bin/ops
sudo -iu trustant ops -update
sudo -iu trustant ops -info
