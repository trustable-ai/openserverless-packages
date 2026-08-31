#!/bin/bash
set -euo pipefail
cd "$(dirname $0)"
source ./env

echo "=== prepare user trustable ==="

sudo apt-get update && sudo apt-get install -y iptables zstd binutils

sudo userdel trustable || true
sudo groupdel trustable || true
sudo rm -Rvf /home/trustable
sudo groupadd -g 769 trustable || true
sudo useradd -u 769 -g trustable -m -d /home/trustable -s /bin/bash trustable || true
sudo mkdir -p /home/trustable/workspace
sudo chown -R trustable:trustable /home/trustable

echo "=== install ops ==="

curl -sL n7s.co/get-ops-tru | bash
sudo mv ~/.local/bin/ops /usr/bin/ops
sudo chown root:root /usr/bin/ops

ops -update
ops -info
