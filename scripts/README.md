# esxi-pt.sh

A single POSIX shell script that does the host-side editing of
[the guide](../README.md) on the ESXi host itself: the VMkernel boot options,
the passthrough switch, the three USB edits and the VMX parameters.

It is written for the shell ESXi actually ships — BusyBox `ash` with BusyBox
`awk`, `sed` and `grep` — so it needs nothing installed: no Python, no bash,
no packages.

## What it does, and what it leaves to you

| It does | It does not |
| --- | --- |
| Show the host's state in one screen | Install or apply the unlocker |
| Set `VMkernel.Boot.disableACSCheck` and `VMkernel.Boot.vga` | Add PCI or USB devices to a VM — that is done in the Host Client |
| Switch passthrough on or off for a PCI device | Reboot the host |
| List USB devices and their vendor:product IDs | Download or check a VBIOS |
| Edit `/etc/vmware/config`, `/bootbank/boot.cfg` and a `.vmx` file | Touch anything inside macOS |
| Back up every file before it is touched | |

## Getting it onto the host

ESXi wipes `/tmp` on every reboot, so keep the script on a datastore:

```sh
scp scripts/esxi-pt.sh root@esxi:/vmfs/volumes/datastore1/
ssh root@esxi
sh /vmfs/volumes/datastore1/esxi-pt.sh status
```

Run it as `sh esxi-pt.sh …` and it works regardless of file permissions.

## Commands

`esxi-pt.sh --help` prints the full list. `ID` is a USB vendor:product ID,
written as `05ac:0250` or `0x05ac:0x0250`.

| Command | Guide | What it does |
| --- | --- | --- |
| `status [--all]` | — | ESXi version, both boot options, the `kernelopt` line, the host's `usb.quirks`, and the PCI devices with their passthrough state. Only passthrough-capable devices are listed; `--all` lists every device. |
| `acs-check on\|off` | Part 2, step 8 | `esxcli system settings kernel set -s disableACSCheck -v TRUE\|FALSE` |
| `vga-console on\|off` | Part 2, step 9 | `esxcli system settings kernel set -s vga -v TRUE\|FALSE`; warns that the DCUI goes black |
| `pci list` | Part 2, step 10 | The PCI device table of `status` |
| `pci on\|off ADDRESS` | Part 2, step 10 | `esxcli hardware pci pcipassthru set -d ADDRESS -e true\|false` (ESXi 7.0 or later) |
| `usb list` | Part 3, step 1 | `lsusb -v`, reduced to a table: ID, HID flag, whether the host already allows it, name |
| `usb host-allow ID…` | Part 3, step 2 | Appends `usb.quirks.deviceN = "0xID allow"` to `/etc/vmware/config` |
| `usb host-ignore ID…` | Part 3, step 3 | Adds the devices to `CONFIG./USB/quirks=` on the `kernelopt` line of `/bootbank/boot.cfg` |
| `vmx find` | — | Lists the `.vmx` files on the datastores |
| `vmx show VMX` | — | Prints the passthrough-related parameters of a VM |
| `vmx usb VMX ID…` | Part 3, step 4 | Sets `usb.generic.allowHID = "TRUE"` and adds `usb.quirks.deviceN` entries |
| `vmx gpu VMX --rom FILE` | Part 2, steps 12, 15–16 | Sets `pciPassthruN.opromEnabled`, `pciPassthruN.filename` and `svga.present = "FALSE"` |
| `vmx get VMX KEY` | — | Prints one parameter's value |
| `vmx set VMX KEY VALUE […]` | — | Sets any parameter, several `KEY VALUE` pairs at a time |

### Examples

```sh
# the whole of part 3 for a keyboard and a Logitech receiver
sh esxi-pt.sh usb list
sh esxi-pt.sh usb host-allow  05ac:0250 046d:c52b
sh esxi-pt.sh usb host-ignore 05ac:0250 046d:c52b
sh esxi-pt.sh vmx usb "/vmfs/volumes/VM Storage/OSX Monterey/OSX Monterey.vmx" 05ac:0250 046d:c52b

# part 2: VBIOS for the GPU that was added first, and no virtual video card
sh esxi-pt.sh vmx gpu "/vmfs/volumes/VM Storage/OSX Monterey/OSX Monterey.vmx" \
    --rom ../Powercolor.RX480.8192.160923.rom

# … or for the GPU that was added second
sh esxi-pt.sh vmx gpu "/vmfs/volumes/VM Storage/OSX Monterey/OSX Monterey.vmx" \
    --device 1002:67df --rom ../Powercolor.RX480.8192.160923.rom
```

`vmx gpu` writes to `pciPassthru0` by default. If the GPU is not the first PCI
device of the VM, pick the entry with `--device VENDOR:DEVICE` (the script looks
the entry up by its `deviceId` and `vendorId`) or with `-i N`.

## Options

Options go before the command.

| Option | Effect |
| --- | --- |
| `-n`, `--dry-run` | Print what would change; write nothing. Never asks. |
| `-y`, `--yes` | Do not ask for confirmation. |
| `-f`, `--force` | Edit the VMX although a lock directory exists next to it. |
| `--quirk NAME` | Kernel quirk for `usb host-ignore`. Default `UQ_KBD_IGNORE`. |
| `--rev LOW:HIGH` | Revision range for new quirks. Default `0x0000:0xffff`, as in the guide. Broadcom's own articles use `:0xffff`. |
| `--root DIR` | Prefix for `/etc` and `/bootbank`. Used by the test-suite; never needed on a host. |

## How it edits

- **Preview first.** Every command prints what it is about to do — old lines
  with `-`, new lines with `+`, `esxcli` calls verbatim — and asks `[y/N]`.
- **Backups.** Each file is copied to `NAME.bak.<timestamp>` next to itself
  before it is written. A second backup in the same second gets a suffix, so
  an earlier backup is never overwritten.
- **In place.** A file's content is replaced, but the file itself keeps its
  mode, owner and inode — which matters for `/bootbank/boot.cfg`.
- **Refuses to guess.** `boot.cfg` is only touched when it contains exactly one
  unquoted `kernelopt=` line, and the script stops if the line count would change.
- **VMX rules.** Parameter names are matched case-insensitively; an existing
  parameter is replaced where it stands, a new one is appended, and none is
  duplicated. A VM with a lock directory (`NAME.vmx.lck`) next to its VMX is
  left alone unless `--force` is given — power it off first.
- **Repeatable.** Running a command again is a no-op ("nothing to do").
- **Reversible.** `usb host-allow --remove ID…` and `usb host-ignore --remove ID…`
  take devices back out.

Exit status: `0` when done or nothing was to do, `1` on an error or when you
decline at the prompt.

## After an ESXi update

Updates write a new `boot.cfg`. Run `esxi-pt.sh status` afterwards and compare
it with what you had; then re-apply `usb host-ignore` if needed. The unlocker
has to be re-applied as well, see
[Status of the unlocker](../README.md#status-of-the-unlocker).

## How it is tested — and what is not

`tests/run.sh` points the script at a sandbox (`--root`) and at fake `esxcli`
and `lsusb` commands, then checks every command's output, exit status, the
resulting files and the backups. It passes under:

- BusyBox `ash` with BusyBox `awk` — the closest stand-in for ESXi's shell
- `dash`, `bash`, and the `awk` of BusyBox, BSD and mawk

[CI](../.github/workflows/ci.yml) runs it on Ubuntu with `dash`, `bash` and
`busybox`, and ShellCheck at its strictest severity.

**Not tested: a live ESXi host.** The script was written from the guide and
from Broadcom's documentation, and the following could differ on real hardware:

- the exact layout of `esxcli hardware pci list` (the script reads the
  `Configured Owner` and `Passthru Capable` fields) and of `lsusb -v`,
- the output of `esxcli system settings kernel list` for the `vga` and
  `disableACSCheck` rows,
- whether `esxcli hardware pci pcipassthru` exists on your build (ESXi 7.0+).

Start with `--dry-run`. If something looks wrong, please open an issue with the
output of `esxi-pt.sh status` (with addresses and names removed) and your ESXi
build number.

## Running the tests locally

```sh
sh tests/run.sh                              # the system shell
dash tests/run.sh                            # dash
bash tests/run.sh                            # bash
busybox sh tests/run.sh                      # BusyBox, as on ESXi
docker run --rm -v "$PWD:/w:ro" -w /w busybox sh tests/run.sh
```

The suite writes only inside a temporary directory and removes it when done.
