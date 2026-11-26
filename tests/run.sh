#!/bin/sh
# ---------------------------------------------------------------------------
# Test-suite for scripts/esxi-pt.sh
#
# Runs on any Unix with a POSIX sh. The script under test is pointed at a
# sandbox root (--root) and at fake esxcli / lsusb binaries, so nothing on
# this machine, and nothing on any ESXi host, is touched.
#
#   sh tests/run.sh                                             system sh
#   dash tests/run.sh                                           dash
#   bash tests/run.sh                                           bash
#   busybox sh tests/run.sh                                     BusyBox ash, as on ESXi
#
# ESXi's shell is BusyBox ash, so that run is the one that matters.
# Exit status is 0 only if every check passes.
# ---------------------------------------------------------------------------

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../scripts/esxi-pt.sh"
# shellcheck disable=SC2086
SH=${SHELL_UNDER_TEST:-sh}

SB=$(mktemp -d "${TMPDIR:-/tmp}/esxi-pt-test.XXXXXX") || exit 1
trap 'rm -rf "$SB"' EXIT
trap 'rm -rf "$SB"; exit 1' HUP INT TERM

VMX="$SB/vmfs/volumes/datastore1/OSX Monterey/OSX Monterey.vmx"
ROM=Powercolor.RX480.8192.160923.rom

# ------------------------------------------------------------------ fixtures

mkdir -p "$SB/bin" "$SB/etc/vmware" "$SB/bootbank" "$SB/state" \
    "$SB/vmfs/volumes/datastore1/OSX Monterey"

reset_host() {
    printf 'libdir = "/usr/lib/vmware"\n' > "$SB/etc/vmware/config"
    cat > "$SB/bootbank/boot.cfg" <<'EOF'
bootstate=0
title=Loading VMware ESXi
timeout=5
prefix=
kernel=b.b00
kernelopt=autoPartition=FALSE
modules=jumpstrt.gz --- useropts.gz --- features.gz --- k.b00 --- uc_intel.b00 --- uc_amd.b00 --- uc_hygon.b00 --- procfs.b00 --- vmx.v00 --- vim.v00
build=7.0.3-0.55.20328353
updated=1
EOF
    rm -f "$SB/state/"* "$SB/"*.log "$SB/bootbank/"*.bak.* "$SB/etc/vmware/"*.bak.*
    : > "$SB/esxcli.log"
    : > "$SB/pt.log"
}

reset_vmx() {
    rm -rf "$VMX.lck" "${VMX%.vmx}.vmx.lck" "$VMX.bak."* "$VMX.orig" "$VMX.tmp"
    rm -f "$SB/vmfs/volumes/datastore1/$ROM"
    cat > "$VMX" <<'EOF'
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "OSX Monterey"
guestOS = "darwin21-64"
firmware = "efi"
numvcpus = "8"
memSize = "26624"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "OSX Monterey.vmdk"
usb.present = "TRUE"
usb_xhci.present = "TRUE"
ethernet0.present = "TRUE"
ethernet0.virtualDev = "vmxnet3"
ethernet0.networkName = "VM Network"
svga.present = "TRUE"
pciPassthru0.present = "TRUE"
pciPassthru0.deviceId = "0x67df"
pciPassthru0.vendorId = "0x1002"
pciPassthru0.pciSlotNumber = "192"
pciPassthru1.present = "TRUE"
pciPassthru1.deviceId = "0xaaf0"
pciPassthru1.vendorId = "0x1002"
EOF
}

lines() { awk 'END { print NR }' "$1"; }

export ESXI_PT_TEST_SB="$SB"

cat > "$SB/bin/esxcli" <<'EOF'
#!/bin/sh
# fake esxcli: logs every call and answers from canned output
echo "esxcli $*" >> "$ESXI_PT_TEST_SB/esxcli.log"
state() { cat "$ESXI_PT_TEST_SB/state/$1" 2>/dev/null || echo "$2"; }
case "$*" in
    "system version get")
        cat <<'X'
Product: VMware ESXi
Version: 7.0.3
Build: 20328353
Update: 3
Patch: 67
X
        ;;
    "system settings kernel list")
        cat <<X
Name                   Type  Value  Description
----                   ----  -----  -----------
disableACSCheck        bool  $(state disableACSCheck FALSE)  Bypass ACS capability checks on all PCIE devices
vga                    bool  $(state vga TRUE)  Enable/Disable VGA support.
X
        ;;
    "system settings kernel set -s disableACSCheck -v "*)
        args="$*"
        echo "${args##*-v }" > "$ESXI_PT_TEST_SB/state/disableACSCheck" ;;
    "system settings kernel set -s vga -v "*)
        args="$*"
        echo "${args##*-v }" > "$ESXI_PT_TEST_SB/state/vga" ;;
    "hardware pci list")
        cat <<'X'
0000:00:02.0
   Address: 0000:00:02.0
   Segment: 0x0000
   Bus: 0x00
   Slot: 0x02
   Function: 0x0
   Configured Owner: VMkernel
   Current Owner: VMkernel
   Vendor ID: 0x8086
   Device ID: 0x1912
   Vendor Name: Intel Corporation
   Device Name: HD Graphics 530
   Class: VGA compatible controller
   Class Code: 30000
   Passthru Capable: true

0000:00:1f.3
   Address: 0000:00:1f.3
   Segment: 0x0000
   Bus: 0x00
   Slot: 0x1f
   Function: 0x3
   Configured Owner: VMkernel
   Current Owner: VMkernel
   Vendor ID: 0x8086
   Device ID: 0xa170
   Vendor Name: Intel Corporation
   Device Name: 100 Series/C230 Series Chipset Family HD Audio Controller
   Class: Audio device
   Class Code: 40300
   Passthru Capable: false

0000:01:00.0
   Address: 0000:01:00.0
   Segment: 0x0000
   Bus: 0x01
   Slot: 0x00
   Function: 0x0
   Configured Owner: VM Passthru
   Current Owner: VM Passthru
   Vendor ID: 0x1002
   Device ID: 0x67df
   Vendor Name: Advanced Micro Devices, Inc. [AMD/ATI]
   Device Name: Ellesmere [Radeon RX 470/480/570/580/590]
   Class: VGA compatible controller
   Class Code: 30000
   Passthru Capable: true
   Module Name: pciPassthru
X
        ;;
    "hardware pci pcipassthru set -d "*" -e "*)
        echo "$*" >> "$ESXI_PT_TEST_SB/pt.log" ;;
    *)
        echo "fake esxcli: unexpected arguments: $*" >&2
        exit 1
        ;;
esac
EOF

cat > "$SB/bin/lsusb" <<'EOF'
#!/bin/sh
# fake lsusb -v, modelled on the output shown in the original guide
echo "lsusb $*" >> "$ESXI_PT_TEST_SB/lsusb.log"
cat <<'X'
Bus 001 Device 001: ID 0e0f:8003 VMware, Inc. Root Hub

Couldn't open device, some information will be missing

Bus 001 Device 002: ID 1a40:0101 Terminus Technology Inc. Hub
Device Descriptor:
  idProduct          0x0101 Hub

Bus 001 Device 003: ID 05e3:0608 Genesys Logic, Inc. Hub
Device Descriptor:
  idProduct          0x0608 USB 2.0 Hub

Bus 001 Device 004: ID 05ac:0250 Apple, Inc. Aluminium Keyboard (ISO)
Device Descriptor:
  idProduct          0x0250 Aluminium Keyboard (ISO)
  iProduct                2 Apple, Inc. Aluminium Keyboard (ISO)
                HID Device Descriptor:
                  bcdHID               1.00
                HID Device Descriptor:
                  bcdHID               1.00
can't get device qualifier: Resource temporarily unavailable

Bus 001 Device 005: ID 046d:c52b Logitech, Inc. Unifying Receiver
Device Descriptor:
  idProduct          0xc52b Unifying Receiver
                HID Device Descriptor:
                  bcdHID               1.11
                HID Device Descriptor:
                  bcdHID               1.11
                HID Device Descriptor:
                  bcdHID               1.11
can't get device qualifier: Resource temporarily unavailable
X
EOF

chmod +x "$SB/bin/esxcli" "$SB/bin/lsusb"
PATH="$SB/bin:$PATH"

# ---------------------------------------------------------------- harness --

PASS=0
FAIL=0
TNAME=

section() {
    echo
    echo "== $1"
}

t() { TNAME=$1; }

# shellcheck disable=SC2086
run() {
    OUT=$($SH "$SCRIPT" --root "$SB" "$@" 2>&1)
    RC=$?
}

# run_stdin TEXT ARGS... : answer the confirmation prompt with TEXT
run_stdin() {
    _text=$1
    shift
    # shellcheck disable=SC2086
    OUT=$(printf '%s\n' "$_text" | $SH "$SCRIPT" --root "$SB" "$@" 2>&1)
    RC=$?
}

pass() { PASS=$((PASS + 1)); }

fail() {
    FAIL=$((FAIL + 1))
    echo "FAIL [$TNAME] $1"
    printf '%s\n' "$OUT" | sed 's/^      /      | /'
}

ok_rc()   { if [ "$RC" -eq 0 ]; then pass; else fail "expected exit status 0, got $RC"; fi; }
fail_rc() { if [ "$RC" -ne 0 ]; then pass; else fail "expected a non-zero exit status"; fi; }
has()     { case "$OUT" in *"$1"*) pass ;; *) fail "output should contain: $1" ;; esac; }
hasnt()   { case "$OUT" in *"$1"*) fail "output should not contain: $1" ;; *) pass ;; esac; }
hasre()   { if printf '%s\n' "$OUT" | grep -Eq -- "$1"; then pass; else fail "output should match: $1"; fi; }
eq()      { if [ "$1" = "$2" ]; then pass; else fail "expected '$2', got '$1'"; fi; }
fhas()    { if grep -qF -- "$2" "$SB$1" 2>/dev/null; then pass; else fail "$SB$1 should contain: $2"; fi; }
fhasnt()  { if grep -qF -- "$2" "$SB$1" 2>/dev/null; then fail "$SB$1 should not contain: $2"; else pass; fi; }
vhas()    { if grep -qF -- "$1" "$VMX" 2>/dev/null; then pass; else fail "the VMX should contain: $1"; fi; }
vhasnt()  { if grep -qF -- "$1" "$VMX" 2>/dev/null; then fail "the VMX should not contain: $1"; else pass; fi; }
loghas()  { if grep -qF -- "$1" "$SB/esxcli.log"; then pass; else fail "esxcli was not called with: $1"; fi; }
usbloghas() { if grep -qF -- "$1" "$SB/lsusb.log"; then pass; else fail "lsusb was not called with: $1"; fi; }

# oldest_backup DIR NAME -> the oldest NAME.bak.* file in DIR (exit 1 if there is none).
# A glob expands in sorted order, so the first match is the oldest.
oldest_backup() {
    for _f in "$1/$2".bak.*; do
        if [ -e "$_f" ]; then
            printf '%s\n' "$_f"
            return 0
        fi
    done
    return 1
}

count_backups() {
    _n=0
    for _f in "$1/$2".bak.*; do
        if [ -e "$_f" ]; then
            _n=$((_n + 1))
        fi
    done
    printf '%s\n' "$_n"
}

# bak_exists DIR NAME : a NAME.bak.<timestamp> exists in DIR
bak_exists() {
    if oldest_backup "$1" "$2" > /dev/null; then
        pass
    else
        fail "no backup of $2 in $1"
    fi
}

leftovers() {
    _n=0
    for _f in "${TMPDIR:-/tmp}"/esxi-pt.sh.*; do
        if [ -e "$_f" ]; then
            _n=$((_n + 1))
        fi
    done
    printf '%s\n' "$_n"
}

# ---------------------------------------------------------------- tests ----

reset_host
reset_vmx
START_LEFTOVERS=$(leftovers)

section "help and argument handling"

t "--help lists every command"
run --help
ok_rc
has "Usage:"
has "acs-check on|off"
has "vga-console on|off"
has "pci on|off ADDRESS"
has "usb host-allow ID..."
has "usb host-ignore ID..."
has "vmx gpu VMX --rom FILE"

t "no command is a usage error"
run
fail_rc
has "Usage:"

t "an unknown command is rejected"
run frobnicate
fail_rc
has "unknown command"

t "an unknown option is rejected"
run --frobnicate status
fail_rc
has "unknown option"

t "an invalid device ID is rejected before anything is touched"
run --yes usb host-allow zz:1
fail_rc
has "not a valid ID"
fhasnt /etc/vmware/config usb.quirks

section "status"

reset_host
t "status of an untouched host"
run status
ok_rc
hasre 'Version:[ ]+7\.0\.3'
hasre 'Build:[ ]+20328353'
has "disableACSCheck = FALSE"
has "vga = TRUE"
has "autoPartition=FALSE"
has "(no usb.quirks entries)"
hasre '0000:01:00\.0 +on +yes +0x1002:0x67df +Ellesmere'
hasre '0000:00:02\.0 +- +yes +0x8086:0x1912 +HD Graphics 530'
hasnt "0000:00:1f.3"
has "status --all"

t "status --all lists devices that cannot be passed through too"
run status --all
ok_rc
hasre '0000:00:1f\.3 +- +no +0x8086:0xa170'

t "pci list prints the device table on its own"
run pci list
ok_rc
hasre '0000:01:00\.0 +on'

t "status shows usb.quirks and the kernelopt line once they exist"
printf 'usb.quirks.device0 = "0x05ac:0x0250 allow"\n' >> "$SB/etc/vmware/config"
run status
ok_rc
has "usb.quirks.device0 = \"0x05ac:0x0250 allow\""

section "kernel boot options (guide steps 8 and 9)"

reset_host
t "acs-check off --dry-run runs nothing"
run --dry-run acs-check off
ok_rc
has "[dry run] would run: esxcli system settings kernel set -s disableACSCheck -v TRUE"
hasnt "[ok]"
eq "$(cat "$SB/esxcli.log")" ""

t "acs-check off applies"
run --yes acs-check off
ok_rc
loghas "system settings kernel set -s disableACSCheck -v TRUE"
fhas /state/disableACSCheck TRUE
run status
has "disableACSCheck = TRUE"

t "acs-check on reverts"
run --yes acs-check on
ok_rc
loghas "system settings kernel set -s disableACSCheck -v FALSE"
fhas /state/disableACSCheck FALSE

t "vga-console off applies and warns about the DCUI"
run --yes vga-console off
ok_rc
has "black screen"
loghas "system settings kernel set -s vga -v FALSE"
fhas /state/vga FALSE
run status
has "vga = FALSE"

t "vga-console on reverts"
run --yes vga-console on
ok_rc
loghas "system settings kernel set -s vga -v TRUE"
fhas /state/vga TRUE

t "declining at the prompt leaves the setting alone"
run_stdin n acs-check off
fail_rc
has "Aborted - nothing was changed."
fhas /state/disableACSCheck FALSE

t "confirming at the prompt applies it"
run_stdin y acs-check off
ok_rc
has "[ok] set."
fhas /state/disableACSCheck TRUE

t "acs-check without on|off is a usage error"
run --yes acs-check
fail_rc
has "usage:"

section "PCI passthrough toggle (guide step 10)"

reset_host
t "pci on --dry-run runs nothing"
run --dry-run pci on 0000:09:00.0
ok_rc
has "[dry run] would run: esxcli hardware pci pcipassthru set -d 0000:09:00.0 -e true"
eq "$(cat "$SB/pt.log")" ""

t "pci off and pci on call esxcli with the expected arguments"
run --yes pci off 0000:09:00.0
ok_rc
grep -qF 'hardware pci pcipassthru set -d 0000:09:00.0 -e false' "$SB/pt.log"
eq $? 0
run --yes pci on 0000:09:00.0
ok_rc
grep -qF 'hardware pci pcipassthru set -d 0000:09:00.0 -e true' "$SB/pt.log"
eq $? 0

t "a malformed address is rejected"
run --yes pci on 1:2.3
fail_rc
has "usage:"

section "usb list"

reset_host
t "usb list flags HID devices"
run usb list
ok_rc
usbloghas "lsusb -v"
# ID  HID  allow  name; "allow" is blank for devices the host does not allow yet
hasre '05ac:0250 +HID + +Apple, Inc\. Aluminium Keyboard \(ISO\)'
hasre '046d:c52b +HID + +Logitech, Inc\. Unifying Receiver'
hasre '1a40:0101 +- + +Terminus Technology Inc\. Hub'
hasre '0e0f:8003 +- + +VMware, Inc\. Root Hub'
hasnt "Resource temporarily unavailable"

t "usb list marks IDs that the host already allows"
printf 'usb.quirks.device0 = "0x046d:0xc52b allow"\n' >> "$SB/etc/vmware/config"
run usb list
ok_rc
hasre '046d:c52b +HID +yes +Logitech'
hasre '05ac:0250 +HID + +Apple'

section "usb host-allow (/etc/vmware/config)"

reset_host
t "--dry-run previews the lines and appends nothing"
run --dry-run usb host-allow 05ac:0250 0x046d:C52B
ok_rc
has '+ usb.quirks.device0 = "0x05ac:0x0250 allow"'
has '+ usb.quirks.device1 = "0x046d:0xc52b allow"'
has "[dry run] nothing was written."
eq "$(cat "$SB/etc/vmware/config")" 'libdir = "/usr/lib/vmware"'

t "the two lines are appended and the file backed up"
run --yes usb host-allow 05ac:0250 0x046d:C52B
ok_rc
has "[ok] done."
fhas /etc/vmware/config 'libdir = "/usr/lib/vmware"'
fhas /etc/vmware/config 'usb.quirks.device0 = "0x05ac:0x0250 allow"'
fhas /etc/vmware/config 'usb.quirks.device1 = "0x046d:0xc52b allow"'
eq "$(lines "$SB/etc/vmware/config")" 3
bak_exists "$SB/etc/vmware" config

t "a second host-allow run is a no-op"
run --yes usb host-allow 05ac:0250
ok_rc
has "already in /etc/vmware/config"
hasnt "usb.quirks.device1"
eq "$(lines "$SB/etc/vmware/config")" 3

t "a new ID continues the numbering"
run --yes usb host-allow 046d:c077
ok_rc
fhas /etc/vmware/config 'usb.quirks.device2 = "0x046d:0xc077 allow"'

t "both notations are accepted and duplicates dropped"
run --yes usb host-allow 046D:C077 0x046d:0xc077
ok_rc
has "nothing to do"
eq "$(lines "$SB/etc/vmware/config")" 4

t "--remove drops an entry and renumbers the rest"
run --yes usb host-allow --remove 05ac:0250
ok_rc
has '- usb.quirks.device0 = "0x05ac:0x0250 allow"'
fhasnt /etc/vmware/config '0x05ac:0x0250'
fhas /etc/vmware/config 'usb.quirks.device0 = "0x046d:0xc52b allow"'
fhas /etc/vmware/config 'usb.quirks.device1 = "0x046d:0xc077 allow"'
fhasnt /etc/vmware/config 'usb.quirks.device2'
eq "$(lines "$SB/etc/vmware/config")" 3

t "--remove of an unknown ID is a no-op for /etc/vmware/config"
run --yes usb host-allow --remove 1234:5678
ok_rc
has "nothing to do"
eq "$(lines "$SB/etc/vmware/config")" 3

t "two edits in quick succession leave two backups, the first one pristine"
reset_host
run --yes usb host-allow 05ac:0250
ok_rc
run --yes usb host-allow 046d:c52b
ok_rc
eq "$(count_backups "$SB/etc/vmware" config)" 2
eq "$(cat "$(oldest_backup "$SB/etc/vmware" config)")" 'libdir = "/usr/lib/vmware"'

t "a file without a final newline gets one before the new lines"
reset_host
printf 'libdir = "/usr/lib/vmware"' > "$SB/etc/vmware/config"
run --yes usb host-allow 05ac:0250
ok_rc
eq "$(lines "$SB/etc/vmware/config")" 2
fhas /etc/vmware/config 'libdir = "/usr/lib/vmware"'
fhas /etc/vmware/config 'usb.quirks.device0 = "0x05ac:0x0250 allow"'

t "declining at the prompt leaves /etc/vmware/config alone"
reset_host
run_stdin n usb host-allow 05ac:0250
fail_rc
has "Aborted"
eq "$(cat "$SB/etc/vmware/config")" 'libdir = "/usr/lib/vmware"'

section "usb host-ignore (/bootbank/boot.cfg)"

EXPECT='kernelopt=autoPartition=FALSE CONFIG./USB/quirks=0x05ac:0x0250:0x0000:0xffff:UQ_KBD_IGNORE:0x046d:0xc52b:0x0000:0xffff:UQ_KBD_IGNORE'

reset_host
t "--dry-run shows the new line and leaves the file alone"
run --dry-run usb host-ignore 05ac:0250 046d:c52b
ok_rc
has "- kernelopt=autoPartition=FALSE"
has "+ $EXPECT"
has "[dry run] nothing was written."
fhas /bootbank/boot.cfg 'kernelopt=autoPartition=FALSE'
fhasnt /bootbank/boot.cfg 'CONFIG./USB/quirks'
eq "$(lines "$SB/bootbank/boot.cfg")" 9

t "the result is the kernelopt line from the guide, and nothing else changes"
run --yes usb host-ignore 05ac:0250 046d:c52b
ok_rc
fhas /bootbank/boot.cfg "$EXPECT"
eq "$(lines "$SB/bootbank/boot.cfg")" 9
fhas /bootbank/boot.cfg 'build=7.0.3-0.55.20328353'
fhas /bootbank/boot.cfg 'title=Loading VMware ESXi'
bak_exists "$SB/bootbank" boot.cfg

t "a new device is appended, the existing ones are kept as they are"
run --yes usb host-ignore 046d:c077
ok_rc
fhas /bootbank/boot.cfg "$EXPECT:0x046d:0xc077:0x0000:0xffff:UQ_KBD_IGNORE"
eq "$(lines "$SB/bootbank/boot.cfg")" 9

t "a second host-ignore run is a no-op"
run --yes usb host-ignore 05ac:0250
ok_rc
has "nothing to do"
fhas /bootbank/boot.cfg "$EXPECT:0x046d:0xc077:0x0000:0xffff:UQ_KBD_IGNORE"

t "--remove drops one device"
run --yes usb host-ignore --remove 046d:c52b
ok_rc
fhas /bootbank/boot.cfg 'kernelopt=autoPartition=FALSE CONFIG./USB/quirks=0x05ac:0x0250:0x0000:0xffff:UQ_KBD_IGNORE:0x046d:0xc077:0x0000:0xffff:UQ_KBD_IGNORE'
eq "$(lines "$SB/bootbank/boot.cfg")" 9

t "--remove of the last devices restores the original kernelopt line"
run --yes usb host-ignore --remove 05ac:0250 046d:c077
ok_rc
fhas /bootbank/boot.cfg 'kernelopt=autoPartition=FALSE'
fhasnt /bootbank/boot.cfg 'CONFIG./USB/quirks'
eq "$(lines "$SB/bootbank/boot.cfg")" 9

t "--remove of an unknown ID is a no-op for the kernelopt line"
run --yes usb host-ignore --remove 1234:5678
ok_rc
has "nothing to do"

t "--rev :0xffff writes the form used in VMware's own articles"
run --yes --rev :0xffff usb host-ignore 05ac:0250
ok_rc
fhas /bootbank/boot.cfg 'kernelopt=autoPartition=FALSE CONFIG./USB/quirks=0x05ac:0x0250::0xffff:UQ_KBD_IGNORE'

t "--quirk selects another quirk"
run --yes --quirk UQ_HID_IGNORE usb host-ignore --remove 05ac:0250
ok_rc
run --yes --quirk UQ_HID_IGNORE usb host-ignore 05ac:0250
ok_rc
fhas /bootbank/boot.cfg 'CONFIG./USB/quirks=0x05ac:0x0250:0x0000:0xffff:UQ_HID_IGNORE'

t "a quirk name with separators in it is rejected"
run --yes --quirk 'UQ_KBD_IGNORE:x' usb host-ignore 046d:c52b
fail_rc
has "--quirk"
fhasnt /bootbank/boot.cfg '0x046d:0xc52b'

t "other options on the kernelopt line are kept in place"
reset_host
cat > "$SB/bootbank/boot.cfg" <<'EOF'
bootstate=0
title=Loading VMware ESXi
timeout=5
prefix=
kernel=b.b00
kernelopt=autoPartition=FALSE disableACSCheck=TRUE
modules=jumpstrt.gz --- useropts.gz
build=7.0.3-0.55.20328353
updated=1
EOF
run --yes usb host-ignore 05ac:0250
ok_rc
fhas /bootbank/boot.cfg 'kernelopt=autoPartition=FALSE disableACSCheck=TRUE CONFIG./USB/quirks=0x05ac:0x0250:0x0000:0xffff:UQ_KBD_IGNORE'
eq "$(lines "$SB/bootbank/boot.cfg")" 9

t "a boot.cfg without a kernelopt line is refused and left alone"
printf 'bootstate=0\ntitle=x\n' > "$SB/bootbank/boot.cfg"
run --yes usb host-ignore 05ac:0250
fail_rc
has "no kernelopt= line"
eq "$(cat "$SB/bootbank/boot.cfg")" 'bootstate=0
title=x'

t "a quoted kernelopt value is an unexpected format"
printf 'kernelopt="autoPartition=FALSE"\n' > "$SB/bootbank/boot.cfg"
run --yes usb host-ignore 05ac:0250
fail_rc
has "unexpected format"
eq "$(cat "$SB/bootbank/boot.cfg")" 'kernelopt="autoPartition=FALSE"'

t "two kernelopt lines are an unexpected format"
printf 'kernelopt=autoPartition=FALSE\nkernelopt=quiet\n' > "$SB/bootbank/boot.cfg"
run --yes usb host-ignore 05ac:0250
fail_rc
has "unexpected format"

t "declining at the prompt leaves boot.cfg alone"
reset_host
run_stdin n usb host-ignore 05ac:0250
fail_rc
has "Aborted"
fhas /bootbank/boot.cfg 'kernelopt=autoPartition=FALSE'

section "VMX files"

reset_vmx
t "vmx find lists the VMs on the datastores"
run vmx find
ok_rc
has "$VMX"

t "vmx show prints the passthrough-related parameters"
run vmx show "$VMX"
ok_rc
has 'pciPassthru0.deviceId = "0x67df"'
has 'pciPassthru1.deviceId = "0xaaf0"'
has 'svga.present = "TRUE"'
has 'guestOS = "darwin21-64"'
has 'ethernet0.virtualDev = "vmxnet3"'
hasnt 'memSize'

t "vmx get reads a value"
run vmx get "$VMX" svga.present
ok_rc
eq "$OUT" TRUE

t "vmx get is case-insensitive"
run vmx get "$VMX" SVGA.Present
ok_rc
eq "$OUT" TRUE

t "vmx get of an unknown key fails"
run vmx get "$VMX" no.such.key
fail_rc
has "no line for"

t "vmx of a missing file fails"
run vmx show "$SB/nope.vmx"
fail_rc
has "VMX file not found"

t "vmx usb adds allowHID and the quirks, nothing else"
reset_vmx
BEFORE=$(lines "$VMX")
run --yes vmx usb "$VMX" 05ac:0250 046d:c52b
ok_rc
has '+ usb.generic.allowHID = "TRUE"'
vhas 'usb.generic.allowHID = "TRUE"'
vhas 'usb.quirks.device0 = "0x05ac:0x0250 allow"'
vhas 'usb.quirks.device1 = "0x046d:0xc52b allow"'
vhas 'pciPassthru0.deviceId = "0x67df"'
vhas 'svga.present = "TRUE"'
eq "$(lines "$VMX")" $((BEFORE + 3))
eq "$(sed -n 1p "$VMX")" '.encoding = "UTF-8"'
bak_exists "$SB/vmfs/volumes/datastore1/OSX Monterey" "OSX Monterey.vmx"

t "a second vmx usb run is a no-op"
run --yes vmx usb "$VMX" 05ac:0250
ok_rc
has "nothing to do"
eq "$(lines "$VMX")" $((BEFORE + 3))

t "an existing allowHID = FALSE line is replaced where it stands"
reset_vmx
awk 'NR == 3 { print "usb.generic.allowHID = \"FALSE\"" } { print }' "$VMX" > "$VMX.tmp"
cat "$VMX.tmp" > "$VMX"
rm -f "$VMX.tmp"
BEFORE=$(lines "$VMX")
run --yes vmx usb "$VMX" 05ac:0250
ok_rc
eq "$(sed -n 3p "$VMX")" 'usb.generic.allowHID = "TRUE"'
eq "$(grep -c -i 'usb.generic.allowHID' "$VMX")" 1
eq "$(lines "$VMX")" $((BEFORE + 1))

t "vmx gpu sets the VBIOS flags and removes the virtual video card"
reset_vmx
printf 'x' > "$SB/vmfs/volumes/datastore1/$ROM"
BEFORE=$(lines "$VMX")
run --yes vmx gpu "$VMX" --rom ../$ROM
ok_rc
hasnt "WARNING"
has "- svga.present = \"TRUE\""
has '+ svga.present = "FALSE"'
vhas 'pciPassthru0.opromEnabled = "TRUE"'
vhas "pciPassthru0.filename = \"../$ROM\""
eq "$(sed -n 18p "$VMX")" 'svga.present = "FALSE"'
eq "$(grep -c -i 'svga.present' "$VMX")" 1
eq "$(lines "$VMX")" $((BEFORE + 2))

t "a second run changes nothing"
run --yes vmx gpu "$VMX" --rom ../$ROM
ok_rc
eq "$(lines "$VMX")" $((BEFORE + 2))

t "a relative ROM file that does not exist is flagged"
reset_vmx
run --yes vmx gpu "$VMX" --rom ../missing.rom
ok_rc
has "WARNING"
has "/OSX Monterey/../missing.rom does not exist"
hasnt "add the GPU to the VM"
rm -f "$SB/vmfs/volumes/datastore1/$ROM"

t "--device picks the pciPassthruN entry that holds that device"
reset_vmx
run --yes vmx gpu "$VMX" --device 1002:aaf0 --rom ../audio.rom
ok_rc
has '+ pciPassthru1.opromEnabled = "TRUE"'
vhas 'pciPassthru1.opromEnabled = "TRUE"'
vhas 'pciPassthru1.filename = "../audio.rom"'
vhasnt 'pciPassthru0.opromEnabled'

t "--device also takes the device ID alone"
reset_vmx
run --yes vmx gpu "$VMX" --device 0xaaf0 --rom ../audio.rom
ok_rc
vhas 'pciPassthru1.opromEnabled = "TRUE"'

t "--device with a vendor that does not match finds nothing"
reset_vmx
run --yes vmx gpu "$VMX" --device 8086:aaf0 --rom ../audio.rom
ok_rc
has "WARNING: no single pciPassthruN entry"
vhas 'pciPassthru0.opromEnabled = "TRUE"'

t "-i selects the entry explicitly"
reset_vmx
run --yes vmx gpu "$VMX" -i 1 --rom ../audio.rom
ok_rc
vhas 'pciPassthru1.opromEnabled = "TRUE"'
vhasnt 'pciPassthru0.opromEnabled'

t "-i wins over --device"
reset_vmx
run --yes vmx gpu "$VMX" -i 0 --device 1002:aaf0 --rom ../audio.rom
ok_rc
vhas 'pciPassthru0.opromEnabled = "TRUE"'
vhasnt 'pciPassthru1.opromEnabled'

t "--device falls back to index 0 with a warning when the device is not in the VMX"
reset_vmx
run --yes vmx gpu "$VMX" --device 1002:dead --rom ../x.rom
ok_rc
has "WARNING: no single pciPassthruN entry"
vhas 'pciPassthru0.opromEnabled = "TRUE"'

t "a malformed --device ID is rejected"
reset_vmx
run --yes vmx gpu "$VMX" --device zzzz --rom ../x.rom
fail_rc
has "not a valid ID"
vhasnt 'opromEnabled'

t "a VM without the GPU added warns but still writes"
reset_vmx
grep -v '^pciPassthru0\.' "$VMX" > "$VMX.tmp"
cat "$VMX.tmp" > "$VMX"
rm -f "$VMX.tmp"
run --yes vmx gpu "$VMX" --rom ../x.rom
ok_rc
has "add the GPU to the VM in the Host Client first"
vhas 'pciPassthru0.opromEnabled = "TRUE"'

t "vmx gpu without --rom is a usage error"
reset_vmx
run --yes vmx gpu "$VMX"
fail_rc
has "usage:"

t "a locked VM is refused unless --force is given"
reset_vmx
mkdir "$VMX.lck"
run --yes vmx usb "$VMX" 05ac:0250
fail_rc
has "lock directory"
vhasnt 'usb.generic.allowHID'
run --yes --force vmx usb "$VMX" 05ac:0250
ok_rc
has "WARNING: a lock directory exists"
vhas 'usb.generic.allowHID = "TRUE"'
rmdir "$VMX.lck"

t "vmx set changes parameters in place, whatever their spelling, without duplicates"
reset_vmx
printf 'pciPassthru0.opromEnabled = "FALSE"\n' >> "$VMX"
BEFORE=$(lines "$VMX")
run --yes vmx set "$VMX" pciPassthru0.opromEnabled TRUE
ok_rc
has '- pciPassthru0.opromEnabled = "FALSE"'
vhas 'pciPassthru0.opromEnabled = "TRUE"'
eq "$(grep -c -i 'pciPassthru0.opromEnabled' "$VMX")" 1
eq "$(lines "$VMX")" "$BEFORE"

t "vmx set appends new parameters and accepts several pairs"
run --yes vmx set "$VMX" smc.present TRUE pciPassthru0.opromEnabled TRUE
ok_rc
eq "$(sed -n 18p "$VMX")" 'svga.present = "TRUE"'
eq "$(tail -n 1 "$VMX")" 'smc.present = "TRUE"'
eq "$(grep -c -i 'pciPassthru0.opromEnabled' "$VMX")" 1

t "vmx set rejects odd argument lists, quotes and a missing file"
run --yes vmx set "$VMX" smc.present
fail_rc
has "usage:"
run --yes vmx set "$VMX" 'bad"key' x
fail_rc
has "invalid parameter name"
run --yes vmx set "$VMX" good.key 'bad"value'
fail_rc
has "must not contain quotes"
run --yes vmx set "$SB/nope.vmx" a b
fail_rc
has "VMX file not found"

t "a VMX is never rewritten under --dry-run"
reset_vmx
cp "$VMX" "$VMX.orig"
run --dry-run vmx gpu "$VMX" --rom ../x.rom
ok_rc
has "[dry run] nothing was written."
run --dry-run vmx usb "$VMX" 05ac:0250
ok_rc
cmp -s "$VMX" "$VMX.orig"
eq $? 0

t "declining at the prompt leaves the VMX alone"
run_stdin n vmx usb "$VMX" 05ac:0250
fail_rc
has "Aborted"
cmp -s "$VMX" "$VMX.orig"
eq $? 0

section "tidiness"

t "no temporary file is left behind"
eq "$(leftovers)" "$START_LEFTOVERS"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "$PASS checks passed, 0 failed"
    echo "shell under test: $SH"
else
    echo "$PASS checks passed, $FAIL FAILED"
    echo "shell under test: $SH"
    exit 1
fi
