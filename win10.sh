#!/usr/bin/env bash
#
# create_win10_vm.sh
# Creates a minimal, optimized Windows 10 VM on KVM/QEMU.

# Make sure we're running as root
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root or use sudo."
  exit 1
fi

# Prompt for basic settings
read -rp "VM Name [win10]: " VMNAME
VMNAME=${VMNAME:-win10}

read -rp "RAM (MB) [8192]: " VMRAM
VMRAM=${VMRAM:-8192}

read -rp "vCPUs [4]: " VMCPUS
VMCPUS=${VMCPUS:-4}

# File paths (adjust as needed)
WIN10_ISO="/mnt/ISO/Windows10.iso"
VIRTIO_ISO="/mnt/ISO/virtio-win.iso"
DISK_PATH="/mnt/VM/${VMNAME}.qcow2"
DISK_SIZE=80  # GB

# OVMF/UEFI firmware paths (common on Debian/Ubuntu)
OVMF_CODE="/usr/share/OVMF/OVMF_CODE.fd"
OVMF_VARS="/usr/share/OVMF/OVMF_VARS.fd"

# Check ISO existence
if [[ ! -f "$WIN10_ISO" || ! -f "$VIRTIO_ISO" ]]; then
  echo "ERROR: Missing Windows10.iso or virtio-win.iso. Update script paths!"
  exit 1
fi

# Create QCOW2 disk if not exist
if [[ ! -f "$DISK_PATH" ]]; then
  echo "Creating $DISK_SIZE GB QCOW2 disk at $DISK_PATH..."
  qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"
fi

# Create initial VM definition with virt-install
virt-install \
  --name "$VMNAME" \
  --machine q35 \
  --memory "$VMRAM" \
  --vcpus "$VMCPUS" \
  --cpu host \
  --disk path="$DISK_PATH",format=qcow2,bus=virtio,cache=none,discard=unmap \
  --cdrom "$WIN10_ISO" \
  --disk path="$VIRTIO_ISO",device=cdrom,bus=sata \
  --os-variant win10 \
  --network network=default,model=virtio \
  --graphics spice \
  --boot loader="$OVMF_CODE",nvram_template="$OVMF_VARS" \
  --tpm emulator,model=tpm-crb \
  --virt-type kvm \
  --noautoconsole

# Post-creation XML modifications
TMP_XML="/tmp/${VMNAME}.xml"
virsh dumpxml "$VMNAME" > "$TMP_XML"

# Remove USB tablet device
xmlstarlet ed -L -d "/domain/devices/input[@type='tablet']" "$TMP_XML"

# Add QEMU Guest Agent channel
if ! xmlstarlet sel -t -c "/domain/devices/channel[@type='unix']" "$TMP_XML" | grep -q "<channel"; then
  xmlstarlet ed -L \
    -s "/domain/devices" -t elem -n "channel" -v "" \
    -i "/domain/devices/channel[not(@type)]" -t attr -n "type" -v "unix" \
    -s "/domain/devices/channel[@type='unix']" -t elem -n "target" -v "" \
    -i "/domain/devices/channel[@type='unix']/target" -t attr -n "type" -v "virtio" \
    -i "/domain/devices/channel[@type='unix']/target" -t attr -n "name" -v "org.qemu.guest_agent.0" \
    "$TMP_XML"
fi

# Insert or replace Hyper-V features
xmlstarlet ed -L -d "/domain/features/hyperv" "$TMP_XML"
xmlstarlet ed -L \
  -s "/domain/features" -t elem -n "hyperv" -v "" \
  -i "/domain/features/hyperv" -t attr -n "mode" -v "custom" \
  -s "/domain/features/hyperv" -t elem -n "relaxed" -v "" \
  -i "/domain/features/hyperv/relaxed" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "vapic" -v "" \
  -i "/domain/features/hyperv/vapic" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "spinlocks" -v "" \
  -i "/domain/features/hyperv/spinlocks" -t attr -n "state" -v "on" \
  -i "/domain/features/hyperv/spinlocks" -t attr -n "retries" -v "8191" \
  -s "/domain/features/hyperv" -t elem -n "vpindex" -v "" \
  -i "/domain/features/hyperv/vpindex" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "runtime" -v "" \
  -i "/domain/features/hyperv/runtime" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "synic" -v "" \
  -i "/domain/features/hyperv/synic" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "stimer" -v "" \
  -i "/domain/features/hyperv/stimer" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv/stimer" -t elem -n "direct" -v "" \
  -i "/domain/features/hyperv/stimer/direct" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "reset" -v "" \
  -i "/domain/features/hyperv/reset" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "vendor_id" -v "" \
  -i "/domain/features/hyperv/vendor_id" -t attr -n "state" -v "on" \
  -i "/domain/features/hyperv/vendor_id" -t attr -n "value" -v "KVM Hv" \
  -s "/domain/features/hyperv" -t elem -n "frequencies" -v "" \
  -i "/domain/features/hyperv/frequencies" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "reenlightenment" -v "" \
  -i "/domain/features/hyperv/reenlightenment" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "tlbflush" -v "" \
  -i "/domain/features/hyperv/tlbflush" -t attr -n "state" -v "on" \
  -s "/domain/features/hyperv" -t elem -n "ipi" -v "" \
  -i "/domain/features/hyperv/ipi" -t attr -n "state" -v "on" \
  "$TMP_XML"

# Ensure hypervclock timer in <clock>
if ! xmlstarlet sel -t -c "/domain/clock" "$TMP_XML" | grep -q "<clock"; then
  xmlstarlet ed -L \
    -s "/domain" -t elem -n "clock" -v "" \
    -i "/domain/clock" -t attr -n "offset" -v "localtime" \
    "$TMP_XML"
fi
if ! xmlstarlet sel -t -c "/domain/clock/timer[@name='hypervclock']" "$TMP_XML" | grep -q "<timer"; then
  xmlstarlet ed -L \
    -s "/domain/clock" -t elem -n "timer" -v "" \
    -i "/domain/clock/timer[not(@name)]" -t attr -n "name" -v "hypervclock" \
    -i "/domain/clock/timer[@name='hypervclock']" -t attr -n "present" -v "yes" \
    "$TMP_XML"
fi

# Re-define VM
virsh define "$TMP_XML"
rm -f "$TMP_XML"

echo "=================================================="
echo " Windows 10 VM '$VMNAME' has been created/updated!"
echo "=================================================="
echo
echo "To start: virsh start $VMNAME"
echo "Use Virt-Manager or CLI to access the console."
echo
echo "During Windows setup, if the disk is not visible,"
echo "choose 'Load driver' and select the VirtIO drivers"
echo "from the second CD-ROM (virtio-win.iso)."
echo
echo "After installation, install VirtIO Guest Tools for"
echo "enhanced performance and QEMU guest agent features."
