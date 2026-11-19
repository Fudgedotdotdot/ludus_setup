#!/bin/bash
# Create a bootable ISO with Debian + Ludus preseed.
# Run in WSL:  bash create-ludus-iso.sh
# Output: debian-ludus-autoinstall.iso  (copy to Windows, flash with Rufus)

set -euo pipefail

PRESEED_FILE="ludus-preseed.cfg"
AUTO_INSTALL_FILE="auto-install.sh"
SERVICE_FILE="ludus-firstboot.service"
DEBIAN_ISO="debian-13.7.0-amd64-netinst.iso"
OUTPUT_ISO="debian-ludus-autoinstall.iso"
DEBIAN_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.7.0-amd64-netinst.iso"

# Check required files
for f in "$PRESEED_FILE" "$AUTO_INSTALL_FILE" "$SERVICE_FILE"; do
    if [ ! -f "$f" ]; then
        echo "Error: $f not found in $(pwd)"
        exit 1
    fi
done

echo "=== Downloading Debian 13 netinst ISO ==="
if [ ! -f "$DEBIAN_ISO" ]; then
    wget -q --show-progress "$DEBIAN_URL" -O "$DEBIAN_ISO"
fi

echo "=== Extracting ISO ==="
WORKDIR=$(mktemp -d)
ISOHDPFX=$(mktemp)
trap 'rm -rf "$WORKDIR" "$ISOHDPFX"' EXIT

7z x "$DEBIAN_ISO" -o"$WORKDIR" >/dev/null

# isohdpfx.bin is the isolinux MBR bootstrap. xorriso's -isohybrid-mbr needs it
# to produce the hybrid MBR+GPT layout that Debian ships and that Rufus ISO
# mode requires. Prefer the copy from the isolinux package; if it is not
# installed, fall back to the copy embedded in the Debian ISO (first 432 bytes).
SYS_ISOHDPFX=""
for p in /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/isolinux/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin; do
    [ -f "$p" ] && SYS_ISOHDPFX="$p" && break
done
if [ -n "$SYS_ISOHDPFX" ]; then
    cp "$SYS_ISOHDPFX" "$ISOHDPFX"
    echo "Using isohdpfx.bin from $SYS_ISOHDPFX"
else
    dd if="$DEBIAN_ISO" bs=432 count=1 of="$ISOHDPFX" status=none
    echo "Using isohdpfx.bin extracted from the Debian ISO"
fi

echo "=== Adding preseed, auto-install and service files ==="
# Normalize line endings to LF (files may have been edited on Windows)
cp "$PRESEED_FILE"      "$WORKDIR/preseed.cfg"
cp "$AUTO_INSTALL_FILE" "$WORKDIR/auto-install.sh"
cp "$SERVICE_FILE"      "$WORKDIR/ludus-firstboot.service"
for f in "$WORKDIR/preseed.cfg" "$WORKDIR/auto-install.sh" "$WORKDIR/ludus-firstboot.service"; do
    sed -i 's/\r$//' "$f"
done

echo "=== Modifying boot configuration ==="

# ---------------------------------------------------------------------------
# GRUB (UEFI boot). Debian 13 writes entries like:
#     menuentry --hotkey=i 'Install' { ... }
# Insert a top-level entry right after the closing brace of the 'Install' entry.
# ---------------------------------------------------------------------------
GRUB_CFG="$WORKDIR/boot/grub/grub.cfg"
ENTRY_FILE="$WORKDIR/.ludus-grub-entry"
cat > "$ENTRY_FILE" <<'GRUBEOF'
menuentry 'Auto-install Ludus (Debian + Ludus)' {
    set background_color=black
    linux    /install.amd/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg locale=en_US keymap=us hostname=ludus domain=local --- quiet
    initrd   /install.amd/initrd.gz
}
GRUBEOF

if [ -f "$GRUB_CFG" ]; then
    awk -v entry="$(cat "$ENTRY_FILE")" '
        { print }
        /menuentry/ && /'"'"'Install'"'"' \{/ { inblk = 1 }
        inblk && /^\}/ { print entry; inblk = 0 }
    ' "$GRUB_CFG" > "$GRUB_CFG.new" && mv "$GRUB_CFG.new" "$GRUB_CFG"
    n=$(grep -c "Auto-install Ludus" "$GRUB_CFG" || true)
    if [ "$n" -eq 1 ]; then
        echo "Added GRUB auto-install menu entry"
    else
        echo "ERROR: expected 1 GRUB menu entry, found $n"
        exit 1
    fi
fi
rm -f "$ENTRY_FILE"

# ---------------------------------------------------------------------------
# ISOLINUX (legacy BIOS boot). isolinux.cfg includes menu.cfg which includes
# txt.cfg, so appending a label here adds it to the boot menu.
# ---------------------------------------------------------------------------
if [ -f "$WORKDIR/isolinux/txt.cfg" ]; then
    cat >> "$WORKDIR/isolinux/txt.cfg" <<'ISOEOF'

label autoinstall
	menu label ^Auto-install Ludus (Debian + Ludus)
	kernel /install.amd/vmlinuz
	append auto=true priority=critical preseed/file=/cdrom/preseed.cfg locale=en_US keymap=us hostname=ludus domain=local initrd=/install.amd/initrd.gz --- quiet
ISOEOF
    echo "Added ISOLINUX auto-install menu entry"
fi

echo "=== Creating bootable ISO ==="
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "DEBIAN_LUDUS" \
    -isohybrid-mbr "$ISOHDPFX" \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -output "$OUTPUT_ISO" \
    "$WORKDIR" >/dev/null

echo "=== Done! ==="
echo "ISO created: $(pwd)/$OUTPUT_ISO"
echo ""
echo "Next steps:"
echo "1. Copy $OUTPUT_ISO to Windows"
echo "2. Open Rufus, select USB, select ISO"
echo "3. Partition: GPT, Target: UEFI (non-CSM)"
echo "4. Boot USB, select 'Auto-install Ludus (Debian + Ludus)'"
