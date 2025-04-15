#!/usr/bin/env bash
#
# Script Name: create_win11_vm.sh
#
# Description:
#   Automates the creation of a Windows 11 VM on KVM/QEMU using Virt-Manager.
#   - Prompts for VM name, memory, CPU count.
#   - Q35 chipset + UEFI firmware.
#   - Hyper-V enlightenments, with Intel-only <evmcs state="on"/>.
#   - CPU host-passthrough.
#   - VirtIO disk w/ cache=none, discard=unmap.
#   - Second ISO for VirtIO drivers.
#   - VirtIO NIC.
#   - Removes USB tablet.
#   - Adds QEMU Guest Agent channel.
#   - Enables a TPM 2.0 device for Win11.
#
# Usage:
#   sudo ./create_win11_vm.sh

# -----------------------------------------
# 1. Preliminary Checks
# -----------------------------------------

# Ensure we are root
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (or with sudo)."
  exit 1
fi

# Check CPU virtualization support
CPUFLAGS=$(egrep -c '(vmx|svm)' /proc/cpuinfo)
if [[ "$CPUFLAGS" -eq 0 ]]; then
  echo "ERROR: No CPU virtualization extensions detected (vmx/svm)."
  echo "Please enable VT-x/AMD-V in your BIOS/UEFI and try again."
  exit 1
else
  echo "Detected virtualization extensions. (Count: $CPUFLAGS)"
fi

# Check for required commands/packages
REQUIRED_CMDS=("kvm" "qemu-system-x86_64" "virt-install" "virt-manager" "xmlstarlet" "virsh")
PKG_MANAGER=""

# Attempt to detect package manager
if command -v apt-get &>/dev/null; then
  PKG_MANAGER="apt-get"
elif command -v dnf &>/dev/null; then
  PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
  PKG_MANAGER="yum"
elif command -v zypper &>/dev/null; then
  PKG_MANAGER="zypper"
fi

echo "Checking for required packages..."
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Package/command '$cmd' not found."
    if [ -n "$PKG_MANAGER" ]; then
      read -rp "Attempt to install '$cmd' using $PKG_MANAGER? [y/N]: " choice
      if [[ "$choice" == [Yy]* ]]; then
        $PKG_MANAGER install -y "$cmd"
      else
        echo "Cannot proceed without '$cmd'. Exiting."
        exit 1
      fi
    else
      echo "No recognized package manager found. Install '$cmd' manually."
      exit 1
    fi
  fi
done
echo "All required packages appear to be installed."

# -----------------------------------------
# 2. Prompt for VM Settings
# -----------------------------------------

# VM Name
read -rp "Enter the desired name for your Windows 11 VM (e.g. win11): " VMNAME
if [[ -z "$VMNAME" ]]; then
  echo "VM name cannot be empty. Exiting."
  exit 1
fi

# VM RAM (MB)
read -rp "Enter the amount of RAM (in MB) to allocate to the VM (e.g. 6144 for 6GB): " VMRAM
if [[ -z "$VMRAM" ]]; then
  echo "RAM amount cannot be empty. Exiting."
  exit 1
fi

# VM vCPUs
read -rp "Enter the number of vCPUs to allocate (e.g. 2, 4): " VMVCPUS
if [[ -z "$VMVCPUS" ]]; then
  echo "vCPU count cannot be empty. Exiting."
  exit 1
fi

# -----------------------------------------
# 3. Verify the ISO paths
# -----------------------------------------
WIN11_ISO="/mnt/ISO/Windows11.iso"
VIRTIO_ISO="/mnt/ISO/virtio-win.iso"

if [[ ! -f "$WIN11_ISO" ]]; then
  echo "ERROR: Windows 11 ISO not found at $WIN11_ISO."
  exit 1
fi
if [[ ! -f "$VIRTIO_ISO" ]]; then
  echo "ERROR: VirtIO ISO not found at $VIRTIO_ISO."
  exit 1
fi

# -----------------------------------------
# 4. Create QCOW2 Disk
# -----------------------------------------
DISK_PATH="/mnt/VM/${VMNAME}.qcow2"
DISK_SIZE="50"  # in GB

if [[ -f "$DISK_PATH" ]]; then
  echo "WARNING: Disk image $DISK_PATH already exists. Using existing file."
else
  echo "Creating a new ${DISK_SIZE}GB QCOW2 disk at $DISK_PATH..."
  qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE}G"
fi

# -----------------------------------------
# 5. OS Variant (win10 or win11)
# -----------------------------------------
OS_VARIANT="win10"
if osinfo-query os | grep -q "win11"; then
  OS_VARIANT="win11"
fi

# -----------------------------------------
# 6. OVMF (UEFI) paths (adjust to your distro)
# -----------------------------------------
OVMF_CODE="/usr/share/OVMF/OVMF_CODE.secboot.fd"  # UEFI + Secure Boot
OVMF_VARS="/usr/share/OVMF/OVMF_VARS.fd"

# -----------------------------------------
# 7. virt-install (Initial Creation)
# -----------------------------------------
# Q35 chipset, host CPU passthrough, TPM, main disk as VirtIO with cache=none, discard=unmap,
# second CDROM for virtio-win drivers, etc.
echo "Creating the VM with virt-install..."
virt-install \
  --name "$VMNAME" \
  --machine q35 \
  --memory "$VMRAM" \
  --vcpus "$VMVCPUS" \
  --cpu host \
  --disk path="$DISK_PATH",format=qcow2,bus=virtio,size="$DISK_SIZE",cache=none,discard=unmap \
  --cdrom "$WIN11_ISO" \
  --disk path="$VIRTIO_ISO",device=cdrom,bus=sata \
  --os-variant "$OS_VARIANT" \
  --network network=default,model=virtio \
  --graphics spice \
  --boot loader="$OVMF_CODE",loader.readonly=yes,loader_secure=yes,nvram_template="$OVMF_VARS" \
  --tpm emulator,model=tpm-crb \
  --virt-type kvm \
  --noautoconsole

# -----------------------------------------
# 8. Post-creation XML Customization
# -----------------------------------------
echo "Customizing VM XML to enable Hyper-V features, remove USB tablet, etc."
TEMP_XML="/tmp/${VMNAME}_edit.xml"
virsh dumpxml "$VMNAME" > "$TEMP_XML"

# Detect if Intel
IS_INTEL=0
if grep -iq "GenuineIntel" /proc/cpuinfo; then
  IS_INTEL=1
fi

# Remove USB tablet device
xmlstarlet ed -L \
  -d "/domain/devices/input[@type='tablet']" \
  "$TEMP_XML"

# Add QEMU Guest Agent channel if not present
if ! xmlstarlet sel -t -c "/domain/devices/channel[@type='unix']" "$TEMP_XML" | grep -q "<channel"; then
  xmlstarlet ed -L \
    -s "/domain/devices" -t elem -n "channel" -v "" \
    -i "/domain/devices/channel[not(@type)]" -t attr -n "type" -v "unix" \
    -s "/domain/devices/channel[@type='unix']" -t elem -n "target" -v "" \
    -i "/domain/devices/channel[@type='unix']/target" -t attr -n "type" -v "virtio" \
    -i "/domain/devices/channel[@type='unix']/target" -t attr -n "name" -v "org.qemu.guest_agent.0" \
    "$TEMP_XML"
fi

# Ensure <features> block exists
if ! xmlstarlet sel -t -c "/domain/features" "$TEMP_XML" | grep -q "<features>"; then
  xmlstarlet ed -L \
    -s "/domain" -t elem -n "features" -v "" \
    "$TEMP_XML"
fi

# Remove any existing <hyperv> to avoid duplication
xmlstarlet ed -L \
  -d "/domain/features/hyperv" \
  "$TEMP_XML"

# Add Hyper-V enlightenments
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
  "$TEMP_XML"

# If Intel, add <evmcs state="on"/>
if [[ "$IS_INTEL" -eq 1 ]]; then
  xmlstarlet ed -L \
    -s "/domain/features/hyperv" -t elem -n "evmcs" -v "" \
    -i "/domain/features/hyperv/evmcs" -t attr -n "state" -v "on" \
    "$TEMP_XML"
fi

# Add <timer name="hypervclock" present="yes"/> to <clock> if missing
if ! xmlstarlet sel -t -c "/domain/clock" "$TEMP_XML" | grep -q "<clock"; then
  xmlstarlet ed -L \
    -s "/domain" -t elem -n "clock" -v "" \
    -i "/domain/clock" -t attr -n "offset" -v "localtime" \
    "$TEMP_XML"
fi
if ! xmlstarlet sel -t -c "/domain/clock/timer[@name='hypervclock']" "$TEMP_XML" | grep -q "<timer"; then
  xmlstarlet ed -L \
    -s "/domain/clock" -t elem -n "timer" -v "" \
    -i "/domain/clock/timer[not(@name)]" -t attr -n "name" -v "hypervclock" \
    -i "/domain/clock/timer[@name='hypervclock']" -t attr -n "present" -v "yes" \
    "$TEMP_XML"
fi

# Re-define VM
virsh define "$TEMP_XML"
rm -f "$TEMP_XML"

echo
echo "---------------------------------------------------------------"
echo " Windows 11 VM ($VMNAME) Created & Configured Successfully!    "
echo "---------------------------------------------------------------"

# -----------------------------------------
# 9. Final Instructions
# -----------------------------------------
cat <<EOF
NEXT STEPS:

1. Start your VM:
   virsh start "$VMNAME"
   or open Virt-Manager to start it graphically.

2. Windows 11 Installation:
   - If the installer doesn't see a disk, click "Load driver" and browse the VirtIO CD to install storage drivers.
   - Then proceed with installation as normal.

3. VirtIO Guest Tools:
   - After install, mount virtio-win.iso from within Windows and install "virtio-win-guest-tools" to get
     NIC, storage, balloon, and guest agent drivers.

4. Network Interface (virtio):
   - The script already sets 'virtio' as the NIC model for best performance.

5. USB Tablet Removal:
   - We removed the USB tablet device to reduce CPU overhead.

6. QEMU Guest Agent Channel:
   - We added <channel type="unix"> so you can run commands like:
     sudo virsh shutdown "$VMNAME" --mode=agent
     sudo virsh domifaddr "$VMNAME" --source agent
     etc.

7. TPM 2.0:
   - The script enabled a TPM device (tpm-crb). This helps meet Win11's requirement.

8. Disk Cache & Discard:
   - We set cache=none and discard=unmap on the VirtIO disk for direct I/O and automatic QCOW2 shrinking.

9. Hyper-V Enlightenments:
   - The script inserted the recommended XML block for <hyperv>. 
   - If you're on AMD, we did NOT add <evmcs state="on"/>, as that is Intel-only.

Enjoy your Windows 11 VM on KVM/QEMU!
EOF
