# VMware Workstation Secure Boot Fix for Ubuntu

This script fixes the common **“Could not open /dev/vmmon”** error on Ubuntu when Secure Boot is enabled and VMware Workstation stops working after a kernel update.

It:
- Creates and stores a **Machine Owner Key (MOK)** in `/root/vmware-signing`
- Enrolls the key with Secure Boot (one-time)
- Rebuilds VMware kernel modules (`vmmon` and `vmnet`)
- Signs them so Secure Boot will load them
- Installs a **post-kernel-update hook** to do this automatically for all future kernel updates

---

## Why This Is Needed

When Ubuntu updates to a new kernel, VMware’s kernel modules stop working because:
1. They must be rebuilt for the new kernel.
2. With Secure Boot enabled, the modules must be **cryptographically signed** with a key the firmware trusts.

Without signing, you’ll see:
```
modprobe: ERROR: could not insert 'vmmon': Key was rejected by service
```

---

## Features

- **One-time setup**: Generates and enrolls a Secure Boot key
- **Automatic rebuild + signing** after every kernel update
- Works with all kernels installed on your system
- Idempotent — safe to run multiple times

---

## Usage

### 1. Download the script
```bash
wget https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/vmware-secureboot-fix.sh
chmod +x vmware-secureboot-fix.sh
```

### 2. Run as root
```bash
sudo ./vmware-secureboot-fix.sh
```

If Secure Boot is enabled and your key is not yet enrolled:
- The script will prompt you to **reboot**
- On reboot, you’ll see the blue **MOK Manager**
- Choose:
  1. **Enroll MOK**
  2. **Continue**
  3. **Yes**
  4. Enter the password you set during enrollment
  5. Reboot

After that, run the script again to complete signing and loading modules.

---

## After Setup

Once the script has run successfully **and** the key is enrolled:
- VMware will work immediately after kernel updates.
- You don’t need to run the script again unless you:
  - Reset or change Secure Boot keys in BIOS/UEFI
  - Reinstall Ubuntu or delete `/root/vmware-signing`
  - Remove the `/etc/kernel/postinst.d/zz-vmware-sign` hook

---

## Verifying After a Kernel Update

To confirm the hook is working:
```bash
modinfo /lib/modules/$(uname -r)/misc/vmmon.ko | grep signer
```
Expected output:
```
signer:         VMware Kernel Module Signing
```

If you see that, the module is signed and will load.

---

## Uninstalling the Hook

If you ever want to remove the automation:
```bash
sudo rm /etc/kernel/postinst.d/zz-vmware-sign
```

---

## Troubleshooting

**Check Secure Boot state:**
```bash
mokutil --sb-state
```

**Check module signature:**
```bash
modinfo /lib/modules/$(uname -r)/misc/vmmon.ko | grep signer
```

**Check kernel logs:**
```bash
dmesg -T | egrep -i 'vmmon|vmnet|verification|lockdown|denied'
```

If you see “Key was rejected by service,” the module is unsigned or the key is not enrolled.

---

## License

MIT License — do whatever you want, but no warranty.
