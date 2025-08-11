#!/usr/bin/env bash
# vmware-secureboot-fix.sh (hardened)
# - Generates/stores MOK at /root/vmware-signing (RSA-2048; change to 3072 if desired)
# - Enrolls key (one-time, prompts reboot)
# - Rebuilds/signs/loads vmmon & vmnet
# - Ensures vmmon/vmnet autoload via /etc/modules-load.d/vmware.conf
# - Restarts VMware network services
# - Installs kernel postinst hook to auto-rebuild+sign and restart networking
# Security hardening:
#   * Removed unsafe /tmp module copy fallback
#   * Strict checks for module presence before signing/loading

set -euo pipefail

CN="VMware Kernel Module Signing"
KEYDIR="/root/vmware-signing"
PRIV="$KEYDIR/MOK.priv"
CERT="$KEYDIR/MOK.der"
HOOK="/etc/kernel/postinst.d/zz-vmware-sign"
KREL="$(uname -r)"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[-] Missing: $1"; exit 1; }; }
as_root() { sudo -n true 2>/dev/null || { echo "[-] Please run with sudo: sudo $0"; exit 1; }; }

as_root
export DEBIAN_FRONTEND=noninteractive
echo "[*] Installing prerequisites..."
apt-get update -y
apt-get install -y build-essential "linux-headers-$KREL" mokutil openssl || true

need_cmd vmware-modconfig
need_cmd mokutil
need_cmd openssl

echo "[*] Preparing key directory: $KEYDIR"
install -d -m 700 "$KEYDIR"
chown root:root "$KEYDIR"

if [[ ! -f "$PRIV" || ! -f "$CERT" ]]; then
  echo "[*] Generating MOK key (RSA-2048). To use RSA-3072, edit this script."
  openssl req -new -x509 -newkey rsa:2048 \
    -keyout "$PRIV" -outform DER -out "$CERT" -nodes -days 36500 \
    -subj "/CN=${CN}/"
  chown root:root "$PRIV" "$CERT"
  chmod 600 "$PRIV"
  echo "[+] Key created."
else
  echo "[=] Using existing key at $KEYDIR"
fi

echo "[*] Secure Boot state:"
SB_STATE="$(mokutil --sb-state 2>/dev/null || true)"
echo "    $SB_STATE"

is_enrolled() { mokutil --list-enrolled 2>/dev/null | grep -Fq "$CN"; }

if echo "$SB_STATE" | grep -qi enabled; then
  if is_enrolled; then
    echo "[=] MOK '$CN' appears enrolled."
  else
    echo "[*] Enrolling key (one-time). You'll be prompted to set a password and reboot."
    mokutil --import "$CERT"
    echo
    echo "[!] Reboot required to finish MOK enrollment."
    echo "    Blue screen flow: Enroll MOK -> Continue -> Yes -> enter password -> Reboot"
    read -r -p "Press Enter to reboot now (recommended), or Ctrl+C to cancel: " _ || true
    reboot
    exit 0
  fi
else
  echo "[=] Secure Boot disabled; proceeding (signing still configured)."
fi

echo "[*] Rebuilding VMware modules for kernel $KREL..."
vmware-modconfig --console --install-all || true

echo "[*] Verifying modules exist in /lib/modules/$KREL/misc ..."
install -d -m 755 "/lib/modules/$KREL/misc"
for m in vmmon vmnet; do
  KO="/lib/modules/$KREL/misc/${m}.ko"
  if [[ ! -f "$KO" ]]; then
    echo "[-] $KO not found after vmware-modconfig. Aborting for safety."
    echo "    Ensure VMware Workstation is installed and matching kernel headers are present."
    exit 1
  fi
done

echo "[*] Signing modules for all installed kernels (if sign-file exists)..."
for dir in /lib/modules/*; do
  [[ -d "$dir/misc" ]] || continue
  KV="$(basename "$dir")"
  SIGNER="/usr/src/linux-headers-$KV/scripts/sign-file"
  [[ -x "$SIGNER" ]] || continue
  for m in vmmon vmnet; do
    KO="$dir/misc/${m}.ko"
    [[ -f "$KO" ]] || continue
    "$SIGNER" sha256 "$PRIV" "$CERT" "$KO" || true
  done
  depmod -a "$KV" || true
done

echo "[*] Ensuring vmmon/vmnet autoload at boot..."
CONF="/etc/modules-load.d/vmware.conf"
grep -q '^vmmon$' "$CONF" 2>/dev/null || echo vmmon | tee -a "$CONF" >/dev/null
grep -q '^vmnet$' "$CONF" 2>/dev/null || echo vmnet | tee -a "$CONF" >/dev/null

echo "[*] Loading modules now..."
modprobe -v vmmon || true
modprobe -v vmnet || true

echo "[*] Restarting VMware network services..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart vmware-networks.service 2>/dev/null || true
  systemctl restart vmware.service 2>/dev/null || true
fi
# Fallback legacy helpers
if command -v vmware-networks >/dev/null 2>&1; then
  vmware-networks --restart || true
fi
if [ -x /etc/init.d/vmware ]; then
  /etc/init.d/vmware restart || true
fi

echo "[*] Verifying signatures on current kernel modules:"
for m in vmmon vmnet; do
  KO="/lib/modules/$KREL/misc/${m}.ko"
  echo "---- $KO"
  modinfo "$KO" | grep -E 'signer|sig_key|sig_hash|vermagic' || true
done

echo "[*] Installing kernel postinst hook at $HOOK ..."
cat > "$HOOK" <<'EOF'
#!/bin/sh
# Auto-rebuild + sign VMware modules after kernel updates, then restart networking
set -e

KEYDIR="/root/vmware-signing"
PRIV="$KEYDIR/MOK.priv"
CERT="$KEYDIR/MOK.der"

# The kernel being installed is usually passed as $1; fallback to running kernel
KVER="$1"
[ -n "$KVER" ] || KVER="$(uname -r)"

# Rebuild modules
if command -v vmware-modconfig >/dev/null 2>&1; then
  vmware-modconfig --console --install-all || true
fi

# Ensure misc dir
install -d -m 755 "/lib/modules/$KVER/misc"

# Sign for all installed kernels (covers multiple versions)
for dir in /lib/modules/*; do
  [ -d "$dir/misc" ] || continue
  KV="$(basename "$dir")"
  SIGNER="/usr/src/linux-headers-$KV/scripts/sign-file"
  [ -x "$SIGNER" ] || continue
  for m in vmmon vmnet; do
    KO="$dir/misc/${m}.ko"
    [ -f "$KO" ] || continue
    if [ -f "$PRIV" ] && [ -f "$CERT" ]; then
      "$SIGNER" sha256 "$PRIV" "$CERT" "$KO" || true
    fi
  done
  /sbin/depmod -a "$KV" || true
done

# Ensure autoload on boot
CONF="/etc/modules-load.d/vmware.conf"
grep -q '^vmmon$' "$CONF" 2>/dev/null || echo vmmon >> "$CONF"
grep -q '^vmnet$' "$CONF" 2>/dev/null || echo vmnet >> "$CONF"

# Restart VMware networking if available
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart vmware-networks.service 2>/dev/null || true
  systemctl restart vmware.service 2>/dev/null || true
fi
if command -v vmware-networks >/dev/null 2>&1; then
  vmware-networks --restart || true
fi
[ -x /etc/init.d/vmware ] && /etc/init.d/vmware restart || true

exit 0
EOF
chmod +x "$HOOK"
echo "[+] Hook installed."

echo
echo "[✓] Done."
echo "   • If this was your first time and the key wasn't enrolled, reboot to enroll via MOK Manager, then rerun this script."
echo "   • Otherwise, VMware networking (vmnet8) should be available now."
