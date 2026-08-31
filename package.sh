#!/bin/bash
# Build the trustable .deb per ./package.md.
set -euo pipefail
cd "$(dirname $0)"
source ./env
ops -info

echo "=== PACKAGE ==="
# --test builds a reduced package that bundles ONLY /var/lib/rancher/k3s/server
# (the control plane), skipping the rest of the k3s state tree (the data). Use it
# to verify the install flow quickly without shipping the full data set.
TEST_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --test) TEST_BUILD=1 ;;
    esac
done

VERSION="$OPS_DEB_VERSION"
VERSION="${VERSION#v}"
ARCH="$(dpkg --print-architecture)"
PKGNAME="openserverless"
DISTDIR="$(cd .. && pwd)/dist"
if [ "${TEST_BUILD}" -eq 1 ]; then
    DEB="${DISTDIR}/${PKGNAME}_${VERSION}_${ARCH}-test.deb"
else
    DEB="${DISTDIR}/${PKGNAME}_${VERSION}_${ARCH}.deb"
fi

mkdir -p "${DISTDIR}"

# Ensure k3s is stopped before we read its files.
sudo systemctl stop k3s.service 2>/dev/null || true
if [ -x /usr/local/bin/k3s-killall.sh ]; then
    sudo /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
fi
sync

mkdir -p /var/tmp
# Staging dir holds ONLY the DEBIAN/ packaging metadata. Every payload file —
# including the generated helper scripts — lives at its real on-disk location
# and is tarred straight from there into data.tar, with no intermediate copy.
PKGROOT="/var/tmp/package"
sudo rm -rf "${PKGROOT}"
mkdir -p "${PKGROOT}"
cleanup() { sudo rm -rf "${PKGROOT}"; }
trap cleanup EXIT


# Files bundled verbatim from their real locations (no copy). The two helper
# scripts above are included here so the whole payload tars from a single root.
FILES=(
    /usr/local/bin/k3s
    /usr/local/bin/crictl
    /usr/local/bin/k3s-killall.sh
    /usr/local/bin/k3s-uninstall.sh
    /etc/rancher/k3s/k3s.yaml
    /etc/systemd/system/k3s.service
    /etc/systemd/system/k3s.service.env
    /usr/bin/ops
)

for f in "${FILES[@]}"; do
    if [ ! -e "$f" ]; then
        echo "Missing required file: $f" >&2
        exit 1
    fi
done

# Normal build bundles the whole k3s state tree; --test bundles only the
# control-plane subdir (server), skipping the data, to validate the install
# flow with a much smaller package.
if [ "${TEST_BUILD}" -eq 1 ]; then
    K3S_SUBTREE="/var/lib/rancher/k3s/server"
    echo "TEST build: bundling only ${K3S_SUBTREE} (skipping data)."
else
    K3S_SUBTREE="/var/lib/rancher/k3s"
fi

if [ ! -d "${K3S_SUBTREE}" ]; then
    echo "Missing required directory: ${K3S_SUBTREE}" >&2
    exit 1
fi

# Build data.tar directly from the source paths, no intermediate copy.
# -C / anchors every path at the filesystem root so each file lands at its
# absolute install location inside the package.
#
# dpkg needs the parent-directory entries present in data.tar (it creates each
# dir before unpacking files into it). tar does NOT emit ancestor dirs for
# individually-listed files, so we build an explicit member list: every file
# plus all of its ancestor directories, deduped and sorted so each dir entry
# precedes its contents. --no-recursion keeps listed dirs from pulling in
# siblings; the k3s state tree is added separately (recursively).
DATA_TAR="${PKGROOT}/data.tar.zst"
DATA_TAR_RAW="${PKGROOT}/data.tar"
echo "Building data.tar (tarring from source, no copy)..."

MEMBERS_FILE="${PKGROOT}/members.lst"
{
    # Each individual file plus all of its ancestor directories. The k3s state
    # dir is listed too so its ancestors (./var, ./var/lib, ...) are emitted as
    # directory entries; its contents are appended recursively in pass 2.
    for f in "${FILES[@]}" "${K3S_SUBTREE}"; do
        d="$f"
        while [ "$d" != "/" ]; do
            echo ".${d}"
            d="$(dirname "$d")"
        done
    done
} | sort -u | sudo tee "${MEMBERS_FILE}" >/dev/null

# Build an UNCOMPRESSED tar in two passes, then compress once at the end
# (you cannot --append to a zstd stream). Ownership is preserved as-is from
# disk (--numeric-owner records the real uid/gid); we do NOT force root:root,
# because the k3s state tree contains files that must keep their original
# ownership to work on the target.
#
# Pass 1: directory skeleton + individual files, no recursion (the k3s dir
# entry itself is included here, but not its contents).
sudo tar --create --numeric-owner \
    -f "${DATA_TAR_RAW}" \
    -C / \
    --no-recursion -T "${MEMBERS_FILE}"

# Pass 2: append the k3s subtree recursively, excluding per-node TLS material.
sudo tar --append --numeric-owner \
    -f "${DATA_TAR_RAW}" \
    -C / \
    --exclude='./var/lib/rancher/k3s/server/tls' \
    ".${K3S_SUBTREE}"

# Compress to data.tar.zst.
sudo zstd -q -f --rm "${DATA_TAR_RAW}" -o "${DATA_TAR}"

# Installed-Size = uncompressed payload size, minus the excluded TLS dir.
INSTALLED_SIZE=$(
    {
        for f in "${FILES[@]}"; do sudo du -sk "$f"; done
        sudo du -sk --exclude='*/server/tls' "${K3S_SUBTREE}"
    } | awk '{s+=$1} END{print s}'
)

sudo mkdir -p "${PKGROOT}/DEBIAN"

sudo tee "${PKGROOT}/DEBIAN/control" >/dev/null <<EOF
Package: ${PKGNAME}
Version: ${VERSION}
Section: admin
Priority: optional
Architecture: ${ARCH}
Depends: iptables, systemd
Installed-Size: ${INSTALLED_SIZE}
Maintainer: Nuvolaris <info@nuvolaris.io>
Description: Trustable k3s-based platform package
 Bundles k3s and trustable helper scripts for offline installation.
EOF


sudo tee "${PKGROOT}/DEBIAN/preinst" >/dev/null <<'EOF'
#!/bin/bash
set -e

# A previous trustable package is already installed (this is an upgrade or
# reinstall: $1 is "upgrade", or "install" with a 2nd arg = the old version).
# We do NOT support installing over an existing trustable. Tell the user to
# remove it first.
if [ -n "$2" ] || [ "$1" = "upgrade" ]; then
    cat >&2 <<'MSG'
ERROR: openserverless is already installed.

Please remove the existing package before installing this one:

    sudo apt-get purge openserverless

then re-run the installation.
MSG
    exit 1
fi

if [ -d /var/lib/rancher/k3s ]; then
    cat >&2 <<'MSG'
ERROR: an existing k3s installation was detected (/var/lib/rancher/k3s).

Apache OpenServerless bundles its own k3s and cannot be installed alongside another one.
Uninstall the existing k3s first:

    k3s-killall.sh && k3s-uninstall.sh

then re-run the installation.
MSG
    exit 1
fi

port_busy() {
    local p="$1"
    # Read the kernel socket tables directly — no ss/netstat dependency.
    # /proc/net/tcp{,6} always exist on Linux. Column 2 is "local_address:port"
    # with port in hex; column 4 == 0A means LISTEN.
    local hexp
    hexp=$(printf '%04X' "$p")
    awk -v hp=":$hexp" '$2 ~ hp"$" && $4=="0A"{found=1} END{exit !found}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

if port_busy 80; then
    cat >&2 <<'MSG'
ERROR: port 80 is already in use. Apache OpenServerless needs port 80 to be free.

Stop the service currently listening on port 80 (and uninstall any existing
k3s) before installing:

    k3s-killall.sh && k3s-uninstall.sh

then re-run the installation.
MSG
    exit 1
fi

exit 0
EOF
sudo chmod 0755 "${PKGROOT}/DEBIAN/preinst"

sudo tee "${PKGROOT}/DEBIAN/postinst" >/dev/null <<'EOF'
#!/bin/bash
set -e

groupadd --gid 769 trustable 2>/dev/null || true
useradd --uid 769 --gid 769 --create-home --home-dir /home/trustable --shell /bin/bash trustable 2>/dev/null || true
install -d -o trustable -g trustable -m 0755 /home/trustable/workspace
chown trustable:trustable /home/trustable/workspace

cat >/etc/sudoers.d/trustable <<'SUDOERS'
trustable ALL=(ALL) NOPASSWD:ALL
SUDOERS
chmod 0440 /etc/sudoers.d/trustable

IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
if [ -z "$IFACE" ]; then
    echo "WARNING: no default route found; skipping firewall dropin install." >&2
else
    mkdir -p /etc/systemd/system/k3s.service.d
    cat >/etc/systemd/system/k3s.service.d/blockports.conf <<DROPIN
[Service]
ExecStartPre=/sbin/iptables -t raw -I PREROUTING -i ${IFACE} -p tcp -m multiport --dports 80,443,6443 -j DROP
ExecStopPost=/sbin/iptables -t raw -D PREROUTING -i ${IFACE} -p tcp -m multiport --dports 80,443,6443 -j DROP
DROPIN
fi

systemctl daemon-reload
systemctl enable k3s.service
systemctl start k3s.service

cat <<'MSG'
**************************************************************************************
Trustable is accessible only locally through the miniops.me domain.

If you are running Trustable on your local machine, open your browser and navigate to:

http://trustable.miniops.me

If Trustable is running on a remote server, create an SSH tunnel:

ssh -L <port>:127.0.0.1:80 <your-server>

Then open your browser and navigate to:

http://trustable.miniops.me:<port>
**************************************************************************************
MSG

exit 0
EOF
sudo chmod 0755 "${PKGROOT}/DEBIAN/postinst"

sudo tee "${PKGROOT}/DEBIAN/prerm" >/dev/null <<'EOF'
#!/bin/bash
set -e
systemctl disable k3s.service 2>/dev/null || true
systemctl stop k3s.service 2>/dev/null || true
if [ -x /usr/local/bin/k3s-killall.sh ]; then
    /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
fi
exit 0
EOF
sudo chmod 0755 "${PKGROOT}/DEBIAN/prerm"

sudo tee "${PKGROOT}/DEBIAN/postrm" >/dev/null <<'EOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    rm -f /etc/sudoers.d/trustable
    rm -f /etc/systemd/system/k3s.service.d/blockports.conf
    rmdir /etc/systemd/system/k3s.service.d 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    if id trustable >/dev/null 2>&1; then
        userdel trustable 2>/dev/null || true
    fi
    if getent group trustable >/dev/null 2>&1; then
        groupdel trustable 2>/dev/null || true
    fi

    # Full cleanup of the k3s state tree. dpkg leaves non-empty dirs (and any
    # files k3s recreated at runtime) behind, so remove it explicitly.
    rm -rf /var/lib/rancher/k3s
fi

if [ "$1" = "purge" ]; then
    # purge also wipes the user's data directory.
    rm -rf /home/trustable
else
    cat <<'MSG'
Your user data is stored under /home/trustable and is not removed automatically.
To delete it, run: apt-get purge trustable   (or remove /home/trustable manually)
MSG
fi
exit 0
EOF
sudo chmod 0755 "${PKGROOT}/DEBIAN/postrm"

echo Packaging
# data.tar.zst was already built directly from the source paths (no copy).
# Build control.tar.zst from the generated DEBIAN dir, then assemble the .deb
# manually with ar (dpkg-deb --build needs a single tree, which we avoid here).
sudo chown -R 0:0 "${PKGROOT}/DEBIAN"
sudo tar --create --zstd --numeric-owner --owner=0 --group=0 \
    -f "${PKGROOT}/control.tar.zst" \
    -C "${PKGROOT}/DEBIAN" .

echo "2.0" | sudo tee "${PKGROOT}/debian-binary" >/dev/null

rm -f "${DEB}"
( cd "${PKGROOT}" && sudo ar rc "${DEB}" debian-binary control.tar.zst data.tar.zst )
echo Done

echo "Built: ${DEB}"
