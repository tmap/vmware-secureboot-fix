#!/usr/bin/env bash
# vmware-secureboot-fix.sh
# One-shot setup for VMware Workstation kernel modules under Secure Boot.
# - Generates/stores MOK key at /root/vmware-signing
# - Enrolls the key (requires one reboot via MOK Manager)
# - Rebuilds vmmon/vmnet, signs them, loads them
# - Installs a postinst hook to auto-rebuild+sign after future kernel updates

set -euo pipefail

CN="VMware Kernel Module Signing"
KEYDIR="/root/vmware-signing"
PRIV="$KEYDIR/MOK.priv"
CERT="$KEYDIR/MOK.der"
HOOK="/etc/kernel/postinst.d/zz-vmware-sign"
KREL="$(uname -r)"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[-] Missing: $1"; exit 1; }; }

echo "[*] Ensuring prerequisites..."
sudo -n true 2>/dev/null || { echo "[-] Please run with sudo: sudo $0"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y build-essential linux-headers-"$KREL" mokutil openssl

need_cmd vmware-modconfig
need_cmd mokutil
need_cmd openssl

echo "[*] Creating key directory (root-only) at $KEYDIR..."
mkdir -p "$KEYDIR"
chmod 700 "$KEYDIR"
chown root:root "$KEYDIR"

if [[ ! -f "$PRIV" || ! -f "$CERT" ]]; then
  echo "[*] No existing MOK key found. Generating new key pair..."
  openssl req -new -x509 -newkey rsa:2048 \
    -keyout "$PRIV" -outform DER -out "$CERT" -nodes -days 36500 \
    -subj "/CN=${CN}/"
  chown root:root "$PRIV" "$CERT"
  chmod 600 "$PRIV"
  echo "[+] Key generated."
else
  echo "[=] Using existing key at $KEYDIR"
fi

echo "[*] Checking Secure Boot state..."
SB_STATE="$(mokutil --sb-state 2>/dev/null || true)"
echo "    $SB_STATE"

is_enrolled() {
  # Try to detect our cert is enrolled by subject CN match
  mokutil --list-enrolled 2>/dev/null | grep -Fq "$CN"
}

if echo "$SB_STATE" | grep -qi enabled; then
  if is_enrolled; then
    echo "[=] Key with CN '$CN' appears already enrolled."
  else
    echo "[*] Enrolling key with MOK. You will need to reboot once to confirm."
    mokutil --import "$CERT"
    echo
    echo "[!] Reboot required to finish enrollment."
    echo "    On reboot, in the blue 'MOK Manager':"
    echo "      Enroll MOK -> Continue -> Yes -> enter the password you set -> Reboot"
    echo
    read -r -p "Press Enter to reboot now (recommended), or Ctrl+C to cancel: " _ || true
    reboot
    exit 0
  fi
else
  echo "[=] Secure Boot disabled. Signing is optional but will be set up anyway."
fi

echo "[*] Rebuilding VMware modules for current kernel ($KREL)..."
# This builds vmmon/vmnet and usually installs them under /lib/modules/.../misc
vmware-modconfig --console --install-all || true

echo "[*] Ensuring modules are present; creating misc dir if needed..."
install -d -m 755 "/lib/modules/$KREL/misc"

# Fallback: if modules not staged, try copying most recent build artifacts from /tmp
for m in vmmon vmnet; do
  KO="/lib/modules/$KREL/misc/${m}.ko"
  if [[ ! -f "$KO" ]]; then
    echo "    [$m] Not found in /lib/modules. Searching recent build output..."
    SRC="$(find /tmp -maxdepth 2 -type f -name "${m}.ko" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}')"
    if [[ -n "${SRC:-}" ]]; then
      cp -f "$SRC" "$KO"
    fi
  fi
done

echo "[*] Signing modules for all installed kernels (if sign-file exists)..."
for dir in /lib/modules/*; do
  [[ -d "$dir/misc" ]] || continue
  KVER="$(basename "$dir")"
  SIGNER="/usr/src/linux-headers-$KVER/scripts/sign-file"
  if [[ -x "$SIGNER" ]]; then
    for m in vmmon vmnet; do
      KO="$dir/misc/${m}.ko"
      if [[ -f "$KO" ]]; then
        "$SIGNER" sha256 "$PRIV" "$CERT" "$KO" || true
      fi
    done
    depmod -a "$KVER" || true
  fi
done

echo "[*] Loading modules for the running kernel..."
modprobe -v vmmon || true
modprobe -v vmnet || true

echo "[*] Verifying signatures on current kernel modules:"
for m in vmmon vmnet; do
  KO="/lib/modules/$KREL/misc/${m}.ko"
  if [[ -f "$KO" ]]; then
    echo "---- $KO"
    modinfo "$KO" | grep -E 'signer|sig_key|sig_hash|vermagic' || true
  fi
done

echo "[*] Installing post-install hook at $HOOK (auto-rebuild + auto-sign after kernel updates)..."
cat > "$HOOK" <<'EOF'
#!/bin/sh
# Auto-rebuild and auto-sign VMware modules after kernel updates
set -e

KEYDIR="/root/vmware-signing"
PRIV="$KEYDIR/MOK.priv"
CERT="$KEYDIR/MOK.der"

# The kernel version being installed is handed to postinst via $1 (usually)
KVER="$1"
if [ -z "$KVER" ]; then
  KVER="$(uname -r)"
fi

# Rebuild VMware modules (ignore errors; we'll still try to sign any present)
if command -v vmware-modconfig >/dev/null 2>&1; then
  vmware-modconfig --console --install-all || true
fi

# Ensure destination exists
install -d -m 755 "/lib/modules/$KVER/misc"

# Sign modules for all installed kernels (covers multiple kernels present)
for dir in /lib/modules/*; do
  [ -d "$dir/misc" ] || continue
  KV="$(basename "$dir")"
  SIGNER="/usr/src/linux-headers-$KV/scripts/sign-file"
  if [ -x "$SIGNER" ]; then
    for m in vmmon vmnet; do
      KO="$dir/misc/${m}.ko"
      [ -f "$KO" ] || continue
      if [ -f "$PRIV" ] && [ -f "$CERT" ]; then
        "$SIGNER" sha256 "$PRIV" "$CERT" "$KO" || true
      fi
    done
    /sbin/depmod -a "$KV" || true
  fi
done
EOF

chmod +x "$HOOK"
echo "[+] Hook installed."

echo
echo "[✓] Done."
echo "    • If Secure Boot was enabled and the key was already enrolled, VMware should work now."
echo "    • If the script asked you to reboot for MOK enrollment, run this script again after reboot to complete signing & loading."
echo
echo "Quick checks if anything misbehaves:"
echo "  mokutil --sb-state"
echo "  modinfo /lib/modules/$(uname -r)/misc/vmmon.ko | grep signer"
echo "  dmesg -T | egrep -i 'vmmon|vmnet|verification|lockdown|denied'"
