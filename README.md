# macOS on VMware ESXi with GPU and USB passthrough

[![CI](https://github.com/startergo/esxi-macos-vm/actions/workflows/ci.yml/badge.svg)](https://github.com/startergo/esxi-macos-vm/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**A macOS virtual machine on VMware ESXi that behaves like a workstation.** An AMD Radeon
RX 480 passed through over HDMI with full Metal support, its HDMI audio, a USB 3.1 controller
and the keyboard and mouse — with **no OpenCore, no kexts, and nothing changed inside macOS**.

This is an English guide built on the German how-to *“Howto: VMware ESXi Hackintosh Host mit
Passthrough RX480 und Eingabegeräte”* by **eldxmgw** (hackintosh-forum.de, January 2023).
The complete translation of the thread is in [`docs/translation.md`](docs/translation.md);
this page is the same procedure, reorganised and annotated.

## Contents

- [What you get](#what-you-get)
- [Read this first](#read-this-first)
- [Choosing the ESXi version](#choosing-the-esxi-version)
- [Requirements](#requirements)
- [Part 1 — A macOS VM on ESXi](#part-1--a-macos-vm-on-esxi)
- [Part 2 — PCIe passthrough](#part-2--pcie-passthrough)
- [Part 3 — USB keyboard and mouse](#part-3--usb-keyboard-and-mouse)
- [Editing the VMX](#editing-the-vmx)
- [Checking the result](#checking-the-result)
- [Undo](#undo)
- [Helper script](#helper-script)
- [Notes](#notes)
- [Status of the unlocker](#status-of-the-unlocker)
- [On a real Mac](#on-a-real-mac)
- [ESXi licensing today](#esxi-licensing-today)
- [Sources](#sources)
- [Credits and license](#credits-and-license)

## What you get

What the original author had running at the end, on ESXi 7.0 U3g with a macOS Monterey guest:

| What the VM gets | Result reported by the author |
| --- | --- |
| Radeon RX 480, over HDMI | Detected natively as *AMD Radeon RX 480*, 8 GB VRAM, **Metal supported**; drives a 34″ 21:9 display at 3440 × 1440 and 60 Hz |
| RX 480 HDMI audio | The monitor appears as an HDMI output device (2 channels, 48 kHz) |
| USB 3.1 controller (Intel Alpine Ridge) | Shown in macOS as a *USB 3.1 Bus* driven by Apple's own XHCI driver |
| Keyboard and mouse receiver | Both appear behind that controller and work |
| VMXNET 3 network adapter | Works with macOS's built-in driver |
| Snapshots | Worked for the author, although VMware does not officially support them for passthrough VMs |

Tested by the author on **ESXi 7.0 U3g (build 20328353)** and **8.0 (build 20513097)**, with
**macOS Monterey 12.6.2** and **Ventura 13.1**. Host hardware: Gigabyte GA-Z170X-Gaming 3,
Intel Core i7-6700K, 32 GB RAM, PowerColor Red Devil RX 480 8 GB, Intel I210-T1 network card.

He still runs it: in November 2026 he recommended the setup in English on MacRumors, as a way
to run macOS releases newer than Monterey on a Mac Pro (2013) — with the caveat that he has not
tried it on that machine. See [On a real Mac](#on-a-real-mac).

**How it works, in four sentences.** ESXi can run macOS guests, but only exposes that guest
type on Apple hardware; the *unlocker* switches it on. With the real GPU handed to the VM,
macOS loads its own AMD driver for it, so there is nothing to patch in the guest. Two VMX
parameters hand the GPU a copy of its VBIOS, because macOS cannot read it from a passed-through
card, and a third removes ESXi's virtual video card. Finally the ESXi host is told to leave
the keyboard and mouse alone, so the VM can have them.

## Read this first

- **Apple's license.** The macOS software license agreement only permits running macOS in
  virtual machines on Apple-branded hardware. Running it on other hardware, as a “Hackintosh”
  does, is a matter between you and Apple. See [Credits and license](#credits-and-license);
  on a real Mac the question does not arise — see [On a real Mac](#on-a-real-mac).
- **The unlocker patches ESXi.** It modifies files VMware ships, in a way VMware does not
  support. Use a host you can afford to reinstall, and read [Status of the unlocker](#status-of-the-unlocker).
- **Two steps take away your screens.** Step 9 blanks the ESXi console (DCUI) and step 12
  switches off the VM's console window. Do not start passthrough until SSH to the host and
  Screen Sharing to the guest both work.
- **Back up before every reboot.** Put the host in maintenance mode first, as the author
  stresses, and keep a copy of every file you edit (`esxi-pt.sh` does that for you).
- **Which ESXi.** The procedure is verified on ESXi 7.0 U3 only. If you are starting from the
  free 8.0 U3e — the only ESXi Broadcom gives away today — its licence suits this guide, but no
  unlocker is known to work on it, so step 2 is open. See [Choosing the ESXi version](#choosing-the-esxi-version).
- **What is verified.** Parts 1–3 are the original author's procedure, and only his. The
  command-line alternatives, the *Undo* section and the background notes were added here and
  are marked as such. The helper script was tested in sandboxes only — see
  [Helper script](#helper-script).

## Choosing the ESXi version

The original step 1 reads: *“Install ESXi and do the basic setup (I tested this with
7.0U3g-20328353 and 8.0-20513097).”* That still holds, and the differences between the
versions matter:

| ESXi version | For this guide |
| --- | --- |
| **7.0 U3** (the author's: U3g, build 20328353) | **The safe choice.** Both generations of the unlocker target ESXi 7, and 7.0.x is the last release line in which VMware supported Mac hardware at all (Broadcom KB 313785). Its free licence is no longer issued: a new installation starts with 60 days of evaluation. |
| 8.0 (build 20513097) | Worked for the author. Keep the VM's compatibility at **ESXi 7.0 U2**, which his VMs use. |
| 8.0 U1 – U3, commercial builds | Not known to work on an unpatched installation. The README of the Unlocker 4 mirror reports that macOS guests stop booting on updated ESXi 8 hosts unless the VMs stay at 7.0 U2 compatibility, and keyboard passthrough has unresolved reports on 8.0 U2/U3. One user reports Unlocker 3 on 8.0 U2 with a 7.0 U2 VM. |
| **8.0 U3e, the free hypervisor** (build 24677879) | **The licence is no obstacle; the macOS guest is.** Nothing in this guide needs a paid licence, and the author's VM has exactly the 8 vCPUs the free one allows. But it is an 8.0 U3 build, so the row above applies. Details under [ESXi licensing today](#esxi-licensing-today). |
| 9.x | No unlocker is known to work. |

Where the versions come from: ESXi 7.0 and the commercial 8.0 builds are downloads that need an
entitlement on the Broadcom Support Portal. The free 8.0 U3e is the exception.

The author recommends checking the [VMware compatibility guide](https://compatibilityguide.broadcom.com/)
for your hardware before you start — that is why he added a cheap Intel I210-T1 network card
and disabled the onboard NIC.

## Requirements

**Host**

- Intel VT-d or AMD-Vi enabled in the firmware, UEFI boot, and **Secure Boot off** (the unlocker needs it).
- Enough RAM for the VM: a VM with a passed-through device gets all of its memory reserved on the host.
- A network card and a storage controller that ESXi supports.
- SSH and the ESXi Shell enabled on the host.

**Guest**

- A graphics card macOS supports without extras. AMD Polaris cards (RX 470, 480, 570, 580, 590)
  are a safe pick; the author uses an RX 480.
- A **VBIOS dump that matches your exact card** (model and memory size), see step 13.
- A macOS installer as an ISO.

**Access**

- Screen Sharing (or Apple Remote Desktop) working in the VM before you begin part 2.

## Part 1 — A macOS VM on ESXi

Anyone who does not want passthrough is finished after step 7.

### 1. Install ESXi and do the basic setup

See [Choosing the ESXi version](#choosing-the-esxi-version). Afterwards, in the ESXi Host Client
(`https://<host>/ui`), create a datastore and enable SSH under **Host → Actions → Services →
Enable Secure Shell (SSH)**. Every host-side command below is run in an SSH session on the host.
The author works with a single datastore named `VM Storage`.

If you installed the free 8.0 U3e, look at **Host → Manage → Licensing** first: it has to read
*vSphere 8 Hypervisor* with the expiration date *Never*. Evaluation mode there means the
licence was not taken over, see [ESXi licensing today](#esxi-licensing-today).

### 2. Apply the ESXi unlocker

This enables the *Apple macOS* guest types on non-Apple hardware. The repository the original
guide points to no longer exists, so [Status of the unlocker](#status-of-the-unlocker) explains
where the tool lives today and how it is installed. Put the host in maintenance mode, with no
VMs running, and reboot afterwards. The unlocker has to be applied again after every ESXi upgrade.

### 3. Prepare a macOS ISO

The author used [this guide for Monterey](https://nishtahir.com/how-to-create-a-macos-iso),
which adapts to Ventura. [`startergo/macos-iso`](https://github.com/startergo/macos-iso) is an
alternative: GitHub Actions workflows that build DMG and ISO installers for many macOS versions.

### 4. Set up storage

Upload the ISO to your datastore (the author keeps installers in an `ISOs/` folder).

### 5. Create the VM

**Virtual Machines → Create / Register VM**, with the author's settings:

| Setting | Author's value | Remark |
| --- | --- | --- |
| Guest OS | Apple macOS 12 (64-bit) | For Ventura he kept this type; the Host Client then notes that the running guest is macOS 13 |
| Compatibility | ESXi 7.0 U2 and later | Keep 7.0 U2, also on ESXi 8 |
| CPU, memory, disk | 8 vCPUs, 26 GB, 150 GB | |
| Firmware | EFI | |
| Hard disk | on an LSI Logic Parallel controller | the author's choice |
| CD/DVD | Datastore ISO file | your installer |
| USB controller | USB 3.1 | |
| Network adapter | **VMXNET 3** | Do not forget this one, see below |

The network adapter must be **VMXNET 3**. macOS ships a driver for it, and the unlocker's notes
warn that Ventura guests boot-loop with the emulated `e1000e` adapter.

### 6. Install macOS and VMware Tools

Install from the ISO. Then get VMware Tools for macOS and install it by hand: attach the
`darwin.iso` image to the VM's CD/DVD drive and run *Install VMware Tools* inside macOS.

The last version is **VMware Tools 12.1.1 (build 22484250)**. Two identical copies exist:
Broadcom's [frozen legacy tools](https://packages-prod.broadcom.com/tools/frozen/)
(`darwin/darwin.iso`) and the `iso/` folder of [`DrDonk/unlocker`](https://github.com/DrDonk/unlocker).
Both have the SHA-256 `e0c96286f376b30e2c2362bd991709f0f6bc6ebd911be4056a58da8698c49236`.

### 7. Turn on Screen Sharing

In macOS: **System Settings → General → Sharing → Screen Sharing**. The author calls it ARD
(Apple Remote Desktop), whose service this is. Connect to the VM from another Mac
(Finder → ⌘K → `vnc://<VM address>`) and make sure it works — from step 12 on, the ESXi console
is no longer available.

## Part 2 — PCIe passthrough

Menu paths are for the ESXi Host Client. The commands in the grey blocks are the equivalents
for an SSH session; `esxi-pt.sh` is the [helper script](#helper-script).

### 8. Disable the PCIe ACS check

As a precaution, so that passthrough works on every PCIe device. **Host → Manage → System →
Advanced Settings**, search for `pcie`, and set `VMkernel.Boot.disableACSCheck` to `true`.

```sh
esxcli system settings kernel set -s disableACSCheck -v TRUE     # or: esxi-pt.sh acs-check off
```

*(Added here: the command line is VMware's documented equivalent of the advanced setting,
see Broadcom KB 310338.)*

### 9. Disable the VMkernel VGA console

Without this, passed-through graphics cards have to be enabled again by hand after every
reboot of the host. **Caution:** from the next reboot on, the ESXi console (DCUI) shows a
black screen. SSH and the Host Client keep working, and step “Undo” reverses it.

```sh
esxcli system settings kernel set -s vga -v FALSE                # or: esxi-pt.sh vga-console off
```

Reboot the host.

### 10. Enable passthrough for the devices

**Host → Manage → Hardware → PCI Devices**: mark the devices, click **Toggle passthrough**,
then reboot. Enable passthrough for the whole card — the author's RX 480 appears twice:

| Address | Device | Passthrough |
| --- | --- | --- |
| `0000:01:00.0` | Radeon RX 480 | Active |
| `0000:01:00.1` | Ellesmere HDMI Audio (the card's sound function) | Active |
| `0000:09:00.0` | DSL6540 USB 3.1 Controller (Alpine Ridge) | Active |

Only devices that ESXi considers capable can be switched; the page shows that for each one.

```sh
esxcli hardware pci pcipassthru set -d 0000:01:00.0 -e true     # or: esxi-pt.sh pci on 0000:01:00.0
```

*(Added here: `esxcli … pcipassthru` exists since ESXi 7.0; `esxi-pt.sh status` lists every
device with its passthrough state.)*

### 11. Add the GPU to the VM

Power the VM off. **VM → Edit settings → Add other device → PCI Device**, then pick the GPU
from the list. Use the plain *PCI Device*, **not** the dynamic variant, which picks a matching
device only when the VM starts — the author could not get that one to work. The first PCI
device you add is `pciPassthru0` in the VMX file.

### 12. Remove the virtual video card

Set `svga.present` to `FALSE` in the VMX. **Caution:** the VM's console window stops working
here; Screen Sharing and the real GPU take over.

```sh
esxi-pt.sh vmx set "/vmfs/volumes/VM Storage/OSX Monterey/OSX Monterey.vmx" svga.present FALSE
```

How to edit the VMX by hand is described under [Editing the VMX](#editing-the-vmx).

### 13. Get the VBIOS for your card

Obtain a VBIOS dump that matches your card **exactly** — model and memory size — or read out
your own. The author's, for a PowerColor RX 480 with 8 GB, is on
[TechPowerUp](https://www.techpowerup.com/vgabios/187376/powercolor-rx480-8192-160923).
A dump from the wrong card can leave the GPU without a picture.

### 14. Store it on the VM storage

Put the file directly on the datastore, without nested folders — for example as
`/vmfs/volumes/VM Storage/Powercolor.RX480.8192.160923.rom`.

### 15 and 16. Point the VM at the VBIOS

Add two parameters to the VMX. `opromEnabled` lets the VM run the card's option ROM;
`filename` is the path to the dump, relative to the VM's folder (`../` is the datastore root).

```sh
esxi-pt.sh vmx gpu "/vmfs/volumes/VM Storage/OSX Monterey/OSX Monterey.vmx" \
    --rom ../Powercolor.RX480.8192.160923.rom
```

### 17. Start the VM

Passthrough should now work once the monitor is on the right input. The author passes on a
claim he read but could not verify, that GPU passthrough works over HDMI but not over
DisplayPort; HDMI works for him, with a 7 m cable.

### 18. Add the remaining devices

Add the other passed-through devices the same way as in step 11: the HDMI audio function and,
if you have one, the USB 3.1 controller.

## Part 3 — USB keyboard and mouse

ESXi claims keyboards (and receivers that contain one) for itself, so they are not offered for
passthrough. Three places must name the devices, then the host is rebooted and the devices are
added to the VM. The author's examples: an Apple keyboard `05ac:0250` and a Logitech Unifying
receiver `046d:c52b`, both hanging off a USB hub.

### 1. Find the IDs

In an SSH session on the host:

```sh
lsusb -v | grep -E '(^Bus|HID)'          # or: esxi-pt.sh usb list
```

Every device that reports an HID descriptor is a candidate; the ID after `ID` is
`vendor:product`:

```text
Bus 001 Device 002: ID 1a40:0101 Terminus Technology Inc. Hub
Bus 001 Device 004: ID 05ac:0250 Apple, Inc. Aluminium Keyboard (ISO)
                HID Device Descriptor:
Bus 001 Device 005: ID 046d:c52b Logitech, Inc. Unifying Receiver
                HID Device Descriptor:
```

From here on the values are written with a `0x` prefix: `0x05ac:0x0250`.

### 2. Allow the devices on the host

Append to `/etc/vmware/config` (one line per device, numbered from 0):

```text
usb.quirks.device0 = "0x05ac:0x0250 allow"
usb.quirks.device1 = "0x046d:0xc52b allow"
```

```sh
esxi-pt.sh usb host-allow 05ac:0250 046d:c52b
```

### 3. Tell the VMkernel to leave them alone

In `/bootbank/boot.cfg`, append to the existing `kernelopt=` line, separated by one space:
`CONFIG./USB/quirks=` followed by `vendor:device:minRevision:maxRevision:quirk` for each device,
several devices chained with colons.

```text
kernelopt=autoPartition=FALSE CONFIG./USB/quirks=0x05ac:0x0250:0x0000:0xffff:UQ_KBD_IGNORE:0x046d:0xc52b:0x0000:0xffff:UQ_KBD_IGNORE
```

Everything else on the line stays as it is. `UQ_KBD_IGNORE` is used for both devices: the
receiver contains a keyboard interface, and mice are not claimed by ESXi in the first place.

```sh
esxi-pt.sh usb host-ignore 05ac:0250 046d:c52b
```

*(Added here: Broadcom's own articles write the revision range with an empty lower bound,
`::0xffff`; both forms are accepted. If you prefer that one: `esxi-pt.sh --rev :0xffff …`.)*

### 4. Tell the VM

Add the same IDs and a switch for HID devices to the VM's VMX:

```text
usb.generic.allowHID = "TRUE"
usb.quirks.device0 = "0x05ac:0x0250 allow"
usb.quirks.device1 = "0x046d:0xc52b allow"
```

```sh
esxi-pt.sh vmx usb "/vmfs/volumes/VM Storage/OSX Monterey/OSX Monterey.vmx" 05ac:0250 046d:c52b
```

### 5. Reboot the host, then add the devices to the VM

Put the host in maintenance mode and reboot it. Then, with the VM switched off:
**VM → Edit settings → Add other device → USB Device**, and pick the keyboard and the receiver.
They are only listed once the steps above are in place.

Copy-paste templates for the three files are in the [`config/`](config/) folder.

## Editing the VMX

From step 11 on, “the VMX” means the VM's configuration file. There are two ways to edit it,
and they use **different syntax** — although both end up in the same file:

| Where | How | Syntax |
| --- | --- | --- |
| ESXi Host Client | VM → Edit settings → VM Options → Advanced → Configuration Parameters → Edit Configuration | name and value in two columns, no quotes: `pciPassthru0.opromEnabled` / `TRUE` |
| SSH | `/vmfs/volumes/<datastore>/<VM>/<VM>.vmx` | `pciPassthru0.opromEnabled = "TRUE"` |

Whichever you choose:

- Watch the syntax. One space too many or a typo, and it silently does not work, the VM does
  not start, or it behaves strangely. There is no single right way; use whichever suits the moment.
- Edit by hand only while the VM is powered off, and keep a copy of the file first.
- Parameter names are case-insensitive; a parameter must appear only once.
- Do not edit by hand behind vCenter's back: let vCenter or the Host Client write the file, or
  unregister the VM first and register it again afterwards.

## Checking the result

Inside the VM, the author's results look like this:

- **System Information → Graphics/Displays** lists *AMD Radeon RX 480* with 8 GB VRAM, device
  ID `0x67df`, and Metal support. The display shows its native resolution and refresh rate —
  here an LG ultrawide at 3440 × 1440, 60 Hertz.
- **System Information → USB** shows a *USB 3.1 Bus* with the keyboard and the receiver.
- **System Information → Ethernet** shows the VMXNET 3 adapter as `en0`.
- **System Settings → Sound** offers the monitor as an HDMI output device.
- The model is reported as `VMware7,1`; About This Mac names the graphics card.

A quick check in Terminal:

```sh
system_profiler SPDisplaysDataType | grep -E 'Chipset|Metal|VRAM|Resolution'
system_profiler SPUSBDataType
```

## Undo

*(Added here.)* Every change of this guide is reversible:

| Change | Revert |
| --- | --- |
| ACS check (step 8) | `esxcli system settings kernel set -s disableACSCheck -v FALSE`, reboot |
| VGA console (step 9) | `esxcli system settings kernel set -s vga -v TRUE`, reboot — the DCUI is back |
| Passthrough of a device (step 10) | Toggle it off in the Host Client, or `esxcli hardware pci pcipassthru set -d <address> -e false`, reboot |
| GPU in the VM (steps 11–16) | VM off → remove the PCI devices from the VM → restore `svga.present`, delete `opromEnabled` and `filename`, or copy the `*.vmx.bak.*` file back |
| USB HID quirks | `esxi-pt.sh usb host-allow --remove <IDs>` and `esxi-pt.sh usb host-ignore --remove <IDs>`, delete `usb.generic.allowHID` and `usb.quirks.device*` from the VMX, remove the USB devices from the VM, reboot |
| Unlocker | Unlocker 3: `./esxi-uninstall.sh`; Unlocker 4: `./relock`; reboot |

## Helper script

[`scripts/esxi-pt.sh`](scripts/esxi-pt.sh) does the file editing of this guide on the ESXi host:
the kernel boot options, the passthrough switch, the three USB edits and the VMX parameters. It
shows every change before writing it, asks for confirmation, keeps a backup of each file, and is
written for ESXi's own shell (BusyBox `ash`, no Python, no bash). It also reads the host's
licence and warns before a VM gets more vCPUs than the licence allows — 8 with the free
hypervisor.

```sh
scp scripts/esxi-pt.sh root@esxi:/vmfs/volumes/datastore1/
ssh root@esxi
sh /vmfs/volumes/datastore1/esxi-pt.sh status
```

| Guide step | Command |
| --- | --- |
| Overview | `esxi-pt.sh status` |
| 8 | `esxi-pt.sh acs-check off` |
| 9 | `esxi-pt.sh vga-console off` |
| 10 | `esxi-pt.sh pci on 0000:01:00.0` |
| Part 3, 1 | `esxi-pt.sh usb list` |
| Part 3, 2–4 | `esxi-pt.sh usb host-allow …`, `esxi-pt.sh usb host-ignore …`, `esxi-pt.sh vmx usb …` |
| 12, 15–16 | `esxi-pt.sh vmx gpu … --rom …`, `esxi-pt.sh vmx set …` |
| Licence | `esxi-pt.sh license`, `esxi-pt.sh license set KEY` |

`--dry-run` shows what a command would do without touching anything. Details are in
[`scripts/README.md`](scripts/README.md).

**How far it is tested.** The script's logic runs against fake `esxcli`, `lsusb` and `vim-cmd`
commands in a sandbox, with 375 checks that pass under BusyBox (ESXi's shell), dash, bash and
three `awk` implementations. **It has not been run on a live ESXi host yet.** The commands it
issues are the ones documented above plus Broadcom's two licence commands
([KB 428537](https://knowledge.broadcom.com/external/article/428537/verify-esxi-host-license-information-fro.html),
[KB 381426](https://knowledge.broadcom.com/external/article/381426/assigning-esxi-license-to-esxi-host-fail.html)),
and the licence reports the tests are modelled on come from public screenshots. Treat your
first run as a test and start with `--dry-run`.

## Notes

*(Added here, unless marked otherwise.)*

- **After every ESXi update, check the host.** Updates and patches write a new `boot.cfg`, and
  the unlocker has to be re-applied. `esxi-pt.sh status` shows in one screen whether
  `kernelopt`, the host's `usb.quirks` and the boot options are still as they should be.
- **Snapshots.** The author reports that snapshots work with his passthrough VM. VMware's
  documentation does not support them for such VMs, nor suspend or vMotion, so do not rely on
  it for backups.
- **Memory.** Adding a PCI device makes ESXi reserve all of the VM's memory on the host.
- **Ventura and the CPU.** The author runs Ventura on an “obsolete” Skylake CPU without any
  guest modification. According to the unlocker's notes, Ventura drops Intel CPUs older than
  Haswell and no longer runs on AMD CPUs — that is a limitation of macOS, not of ESXi.
- **One major release, like a real Mac.** The author suggests going one step further: have the
  hypervisor start the VM automatically once passthrough is up, so the machine feels like a
  physical workstation. If the user then shuts the VM down, a script should put the host into
  maintenance mode and shut it down too. Not covered here.
- **DisplayPort.** Whether passthrough works over DisplayPort is unverified; the author only
  tested HDMI.
- **The end of the line is in sight.** Broadcom has ended Mac platform support with ESXi 7.0.x,
  VMware has deprecated macOS guests, and Apple drops Intel with macOS 27 — which makes macOS 26
  Tahoe the last macOS that can run in a VM of this kind at all (DrDonk's unlocker README,
  August 2026).

## Status of the unlocker

Step 2 of the original guide links `https://github.com/DrDonk/esxi-unlocker`. **That repository
no longer exists.** It was archived in November 2023 and is gone as of November 2026; its last
release was Unlocker 4.0.6 (March 2023), “designed for VMware ESXi 7”. The source survives in
mirrors, in two generations:

| | Unlocker 3 | Unlocker 4 |
| --- | --- | --- |
| Written for | ESXi 6.5, 6.7 and 7.0 | ESXi 7 |
| How it works | A boot module is registered; at every boot a Python script builds a RAM-disk overlay with patched copies of `/bin/vmx` and `libvmkctl.so`. Nothing on disk is changed. | `unlock`, `relock` and `check` scripts patch the files and register an `apple.v00` boot module |
| Install | Extract the package on a datastore, `./esxi-install.sh`, reboot | Extract on a datastore, `./unlock`, reboot |
| Remove | `./esxi-uninstall.sh`, reboot | `./relock`, reboot |
| Source today | [`netgc/esxi-unlocker`](https://github.com/netgc/esxi-unlocker) and its fork [`chaosch/esxi-unlocker`](https://github.com/chaosch/esxi-unlocker) | [`netgc/esxi-unlocker-4`](https://github.com/netgc/esxi-unlocker-4) (source mirror) |

[`chaosch/esxi-unlocker`](https://github.com/chaosch/esxi-unlocker) is a fork of the Unlocker
3.0.5 repository created in April 2026. Its code is unchanged — the four additional commits
only add GitHub Actions workflows that build the package and publish releases. At the time of
writing it has no published releases, so the package has to be built from source; the build
script only runs on macOS and still names the package `esxi-unlocker-303.tgz`.

Outline for Unlocker 3 — read the repository's README first, and uninstall any previous
unlocker before installing another version:

```sh
# on a Mac: build the package
git clone https://github.com/chaosch/esxi-unlocker.git && cd esxi-unlocker && python3 esxi-build.py
scp esxi-unlocker-*.tgz root@esxi:/vmfs/volumes/<datastore>/

# on the ESXi host, in maintenance mode with no VMs running
cd /vmfs/volumes/<datastore> && tar xzf esxi-unlocker-*.tgz && ./esxi-install.sh
# … reboot the host, then:
./esxi-smctest.sh          # reports whether the patch is active
```

What applies to both generations:

- **Secure Boot must be disabled** in the host's firmware; the unlocker's own notes say it does
  not work with it enabled.
- **ESXi 7 is the supported target.** The author also ran it on ESXi 8.0 with VMs at 7.0 U2
  compatibility. The Unlocker 4 mirror reports that macOS guests stop booting on updated ESXi 8
  hosts unless VMs are kept that way. Nothing is known to work on a stock ESXi 8.0 U1 or later,
  or on 9.x. The one exception is a user who reports Unlocker 3 on 8.0 U2 with a 7.0 U2 VM, and
  poor performance (comment on the mirror's [issue #2](https://github.com/netgc/esxi-unlocker-4/issues/2)).
- **Pre-patched installers exist. They are not a recommendation.** The READMEs of both mirrors
  link to sysin.org, which distributes ESXi 8.0 U3 installer images with the unlocker built in.
  That shows it can be done on 8.0 U3 — but a hypervisor image from an unofficial source cannot
  be checked, and this guide does without it.
- **OC4VM on ESXi: one report.** In September 2026 a user wrote on OC4VM's issue tracker that his
  macOS VM boots on an unpatched ESXi 8.0 U3e — the free hypervisor — once the OpenCore image is
  attached as a disk rather than as an ISO ([DrDonk/OC4VM#104](https://github.com/DrDonk/OC4VM/issues/104)).
  DrDonk replied that ESXi is not supported and that the next version returns to disk images.
  One report, a Big Sur guest, no passthrough: a lead, not a procedure.
- **VMware has moved on.** ESXi 7.0.x is the last release that supports Apple Mac hardware,
  and VMware Tools for macOS are in maintenance mode (Broadcom KB 313785). The provenance of
  the final `darwin.iso` is documented in a
  [Broadcom community thread](https://community.broadcom.com/vmware-cloud-foundation/discussion/download-links-for-frozen-legacy-vmware-tools-1).

**Not to be confused with [`DrDonk/unlocker`](https://github.com/DrDonk/unlocker).** That
repository is alive (v4.2.8, May 2026), but it is the unlocker for **Workstation and Player**
on Windows and Linux: it has no ESXi target and does not patch an ESXi host. Its README points
to [OC4VM](https://github.com/DrDonk/OC4VM), an OpenCore image that runs macOS guests in Fusion
and Workstation without patching anything — and OC4VM's README states that ESXi is not
supported. For an ESXi host, Unlocker 3 or 4 on ESXi 7 remains the only way that more than
one person has reported.

## On a real Mac

*(Added here.)* The guide assumes an ordinary PC, which is why it needs the unlocker. On a Mac
two things are different, and neither is verified here.

- **Apple's licence is satisfied.** macOS may run in virtual machines on Apple-branded hardware.
- **ESXi 7.0 offers macOS guests without the unlocker — on the Macs it supported.** Those are
  the Mac Pro 6,1 (2013) and the Mac mini 6,2 (2012) and 7,1 (2014); Broadcom KB 313785 names
  7.0.x as their last release. The unlocker only switches on what, in the words of its README,
  “are normally exposed in Fusion and ESXi when running on Apple hardware”. On a Mac VMware
  never supported, the Mac Pro 7,1 (2019), users needed the unlocker all the same: macOS guests
  stopped with `DSMOS: SMC read error` until it was installed (comments on William Lam's
  [GPU passthrough post](https://williamlam.com/2020/12/gpu-passthrough-with-esxi-on-the-apple-2019-mac-pro-71.html)
  and a [Broadcom community thread](https://community.broadcom.com/vmware-cloud-foundation/discussion/unable-to-install-macos-guest-on-to-esxi-70u2a-host-apple-hardware)).
  So on a supported Mac under 7.0, step 2 can be skipped.
- **ESXi 8.0 is not supported on any Mac, but installs on several.** William Lam installed it on
  Mac minis from 2011 and 2018 — the newer one only with a boot option — and readers reported
  Mac minis from 2012 and 2014 and Mac Pros from 2013 and 2019
  ([vSphere 8 on Apple Mac Hardware](https://williamlam.com/2022/10/vsphere-8-on-apple-mac-hardware.html)).
  The Ivy Bridge processors of the Mac mini 6,2 and of the Mac Pro 6,1 are on vSphere 8's list
  of unsupported CPUs, so the installer stops with `CPU_SUPPORT ERROR` unless the boot option
  `allowLegacyCPU=true` is given
  ([Homelab considerations for vSphere 8](https://williamlam.com/2022/09/homelab-considerations-for-vsphere-8.html)).
  Whether a macOS guest boots on such a host is not published anywhere I found; the Mac Pro 7,1
  users who tried on 8.0 reported boot loops.

**The author's view, November 2026.** In the MacRumors thread
*[eGPU working on Linux and Windows (MacPro 6,1 / MacPro 2013)](https://forums.macrumors.com/threads/egpu-working-on-linux-and-windows-macpro-6-1-macpro-2013.2488015/?post=34976634#post-34976634)*
he suggested his setup as the better way to use the GPUs of a 2013 Mac Pro. He has not tried it
on that machine, but expects ESXi 8 to run there because his own cluster contains dual-socket
hosts with the same CPUs; the GPUs, he writes, would need testing. He still uses the system
today to run macOS releases newer than Monterey, the last one for that Mac, in VMs.

**What that means for a Mac Pro 6,1 today.** The version this guide is verified on, 7.0 U3,
needs a licence key that Broadcom no longer gives away, and macOS guests on the free 8.0 U3e
are unverified. That is the open end of this guide for real Macs; reports are welcome.

## ESXi licensing today

The original thread dates from January 2023. Since then:

- In February 2024 Broadcom withdrew the free hypervisor the author refers to (KB 2107518, no
  longer online; [Born City's report](https://borncity.com/win/2024/02/13/free-vsphere-hypervisor-esxi-7-x-and-8-x-end-of-general-availability/)).
  Keys issued before remain valid; new ones are not issued.
- In April 2025 a free **VMware vSphere Hypervisor** returned — as a separate image of
  **ESXi 8.0 Update 3e, build 24677879**. The commercial 8.0 U3e is build 24674464
  ([build list](https://www.virten.net/vmware/esxi-release-build-number-history)).
- Any other installation starts in evaluation mode and runs unrestricted for 60 days before a
  key is needed, as the author describes.
- Current releases are ESXi 9.1.2 and 8.0 U3m (November 2026), see
  [Broadcom KB 316595](https://knowledge.broadcom.com/external/article/316595/build-numbers-and-versions-of-vmware-esx.html).

### The free 8.0 U3e

**Where.** Broadcom Support Portal → **My Downloads** → *Free Software Downloads available
HERE* → **VMware vSphere Hypervisor** → **8.0U3e** → accept the terms. The file is
`VMware-VMvisor-Installer-8.0U3e-24677879.x86_64.iso`; a free Broadcom account is enough
([Broadcom KB 399823](https://knowledge.broadcom.com/external/article/399823/vmware-esxi-80-update-3e-now-available-a.html)).

**Fresh install, not an upgrade.** The image carries its licence key, so a fresh installation
normally comes up as *vSphere 8 Hypervisor* with the expiration date *Never*. A host that is
*upgraded* to this image does not get the key: it runs in evaluation mode, and after 60 days it
no longer powers on VMs. A few posters in the
[Broadcom community thread](https://community.broadcom.com/vmware-cloud-foundation/discussion/license-key-for-the-free-edition-of-vmware-esxi-80u3e)
on the key ran into evaluation mode even after a fresh install, so looking under
**Host → Manage → Licensing** right after the installation is the first thing to do. What the
posters confirmed to help: install the image once more, even in a VM, read the key there and
assign it to the other host — the key is also posted in the thread. Whether Broadcom's terms
allow that outside its own image is for you to judge.

In the shell, `esxi-pt.sh license` shows the state, and `esxi-pt.sh license set KEY` assigns a
key.

**What the licence allows**
([Broadcom KB 399823](https://knowledge.broadcom.com/external/article/399823/vmware-esxi-80-update-3e-now-available-a.html),
[release notes](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere/8-0/release-notes/esxi-update-and-patch-release-notes/vsphere-esxi-80u3e-release-notes.html)):

| Limit | For this guide |
| --- | --- |
| 8 vCPUs per VM; a larger VM fails to power on with *There are insufficient licenses to complete this operation* | The author's VM has exactly 8. `esxi-pt.sh status` lists the VMs above the limit. |
| Host Client only, no vCenter | Every step is a Host Client step anyway, and the note about not editing the VMX behind vCenter's back does not apply. |
| Remote vSphere API read-only | Nothing here uses it: the script runs in the ESXi Shell over SSH, which is not restricted. |
| No vMotion, HA, DRS or VADP backups; no support; “for non-production use” | None of it is used. |

Broadcom KB 399823 also lists up to 2 physical CPUs per host; the release notes mention only
the 8 vCPUs.

**Patches.** 8.0 U3e is the only free image; the later 8.0 U3 releases are not. Whether a free
host may be patched to them is nothing Broadcom has spelled out; [one guide](https://bazwise.com/how-to-update-esxi-free-2026/)
describes taking the depot from the portal's free section and applying it with `esxcli`. If a
host then reports *License key has expired* although its licence never expires, that is a known
defect of ESXi 8.0 U3 up to U3g, fixed in U3h
([Broadcom KB 389204](https://knowledge.broadcom.com/external/article/389204/error-license-key-has-expired-license-ex.html)):
`touch /etc/vmware/license.cfg`, then `vim-cmd vimsvc/license --show`, refreshes it.

**The catch for this guide.** The free tier's limits do not get in the way — the author's VM
uses exactly 8 vCPUs. The catch is elsewhere: the free hypervisor is an 8.0 U3 build, and no
unlocker is known to work on a stock 8.0 U3 host, see
[Status of the unlocker](#status-of-the-unlocker).

## Sources

**The original**

- eldxmgw, *[Howto: VMware ESXi Hackintosh Host mit Passthrough RX480 und Eingabegeräte](https://www.hackintosh-forum.de/forum/thread/57423-howto-vmware-esxi-hackintosh-host-mit-passthrough-rx480-und-eingabegeräte/)*, hackintosh-forum.de, 7 January 2023 — with 18 screenshots
- eldxmgw, [post in a MacRumors thread on eGPUs for the Mac Pro 2013](https://forums.macrumors.com/threads/egpu-working-on-linux-and-windows-macpro-6-1-macpro-2013.2488015/?post=34976634#post-34976634), November 2026 — recommending the setup for that Mac
- [English translation of the whole thread](docs/translation.md)

**ESXi passthrough and USB**

- William Lam, *[Passthrough of Integrated GPU (iGPU) for Standard Intel NUC](https://williamlam.com/2020/06/passthrough-of-integrated-gpu-igpu-for-standard-intel-nuc.html)* — the `vga` boot option
- William Lam, *[How to Passthrough USB Keyboard/Mouse (HID) and CCID Devices to VM in ESXi?](https://williamlam.com/2020/05/how-to-passthrough-usb-keyboard-mouse-hid-and-ccid-devices-to-vm-in-esxi.html)*
- William Lam, *[ESX Passthrough of AMD Ryzen Integrated Graphics (iGPU)](https://williamlam.com/2026/05/esx-passthrough-of-amd-ryzen-integrated-graphics-igpu.html)* — `pciPassthru.filename` with an external ROM
- TinkerTry, *[ESXi 7 GPU Passthrough UI Bug Workaround](https://tinkertry.com/vmware-vsphere-esxi-7-gpu-passthrough-ui-bug-workaround)*
- virten.net, *[New esxcli commands in vSphere 7.0](https://www.virten.net/2020/04/new-esxcli-commands-in-vsphere-7-0)*
- Broadcom KB [323377](https://knowledge.broadcom.com/external/article/323377), [380954](https://knowledge.broadcom.com/external/article/380954) (USB HID passthrough), [312208](https://knowledge.broadcom.com/external/article/312208) (`opromEnabled`), [310338](https://knowledge.broadcom.com/external/article/310338), [445893](https://knowledge.broadcom.com/external/article/445893) (PCI passthrough)

**Unlocker and macOS guests**

- [Archived README of DrDonk/esxi-unlocker](https://web.archive.org/web/20250620183232/https://github.com/DrDonk/esxi-unlocker)
- [Unlocker v3 for ESXi, announcement thread](https://www.insanelymac.com/forum/topic/335756-macos-unlocker-v30-for-vmware-esxi) (Secure Boot)
- Broadcom KB [313785](https://knowledge.broadcom.com/external/article/313785/discontinuation-of-support-for-apple-mac.html) — end of Mac platform support
- [`DrDonk/unlocker`](https://github.com/DrDonk/unlocker) — the Workstation/Player unlocker; still maintained, and the source of the notes on the deprecation of macOS guests
- [OC4VM — OpenCore for VMware](https://github.com/DrDonk/OC4VM) — macOS guests for Fusion and Workstation without patching; ESXi not supported
- [DrDonk/OC4VM#104](https://github.com/DrDonk/OC4VM/issues/104) — one report of an OC4VM guest booting on an unpatched ESXi 8.0 U3e
- [netgc/esxi-unlocker-4#2](https://github.com/netgc/esxi-unlocker-4/issues/2) — Unlocker 4 failing on ESXi 8.0; a user on Unlocker 3 and 8.0 U2
- Broadcom community, *[Boot Loop in macOS Ventura on ESXi 8 Hardware Profile](https://community.broadcom.com/vmware-cloud-foundation/discussion/boot-loop-in-in-macos-ventura-on-esxi-8-hardware-profile)*
- William Lam, *[vSphere 8 on Apple Mac Hardware](https://williamlam.com/2022/10/vsphere-8-on-apple-mac-hardware.html)*, *[Homelab considerations for vSphere 8](https://williamlam.com/2022/09/homelab-considerations-for-vsphere-8.html)* (unsupported CPUs), *[GPU passthrough with ESXi on the Apple 2019 Mac Pro 7,1](https://williamlam.com/2020/12/gpu-passthrough-with-esxi-on-the-apple-2019-mac-pro-71.html)* (unlocker needed on an unsupported Mac)

**Licensing**

- Broadcom KB [399823](https://knowledge.broadcom.com/external/article/399823/vmware-esxi-80-update-3e-now-available-a.html) (free 8.0 U3e), [428537](https://knowledge.broadcom.com/external/article/428537/verify-esxi-host-license-information-fro.html) (read the licence from the shell), [381426](https://knowledge.broadcom.com/external/article/381426/assigning-esxi-license-to-esxi-host-fail.html) (assign one from the shell), [389204](https://knowledge.broadcom.com/external/article/389204/error-license-key-has-expired-license-ex.html) (*License key has expired*), [316595](https://knowledge.broadcom.com/external/article/316595/build-numbers-and-versions-of-vmware-esx.html) (build numbers)
- [VMware ESXi 8.0 Update 3e Release Notes](https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/vsphere/8-0/release-notes/esxi-update-and-patch-release-notes/vsphere-esxi-80u3e-release-notes.html)
- virten.net, *[VMware ESXi Release and Build Number History](https://www.virten.net/vmware/esxi-release-build-number-history)* — the two builds of 8.0 U3e
- Broadcom community, *[License key for the free edition of VMware ESXi 8.0U3e](https://community.broadcom.com/vmware-cloud-foundation/discussion/license-key-for-the-free-edition-of-vmware-esxi-80u3e)*
- Nakivo, *[Free ESXi: Restrictions and Limitations](https://www.nakivo.com/blog/free-vmware-esxi-restrictions-limitations)* — the two installer images, the licence in the Host Client and in the shell
- Virtualization Howto, *[VMware ESXi Free Edition Available Again with 8.0U3e](https://www.virtualizationhowto.com/2025/04/vmware-esxi-free-edition-available-again-with-8-0u3e-download-now/)*, *[Install the New VMware ESXi Free Edition Custom ISOs and Limitations](https://www.virtualizationhowto.com/2025/04/install-the-new-vmware-esxi-free-edition-custom-isos-and-limitations/)*
- Born City, *[Free vSphere Hypervisor (ESXi 7.x and 8.x) End of General Availability](https://borncity.com/win/2024/02/13/free-vsphere-hypervisor-esxi-7-x-and-8-x-end-of-general-availability/)* (February 2024)
- Network World, *[VMware quietly brings back its free ESXi hypervisor](https://www.networkworld.com/article/3964957/vmware-quietly-brings-back-its-free-esxi-hypervisor.html)*
- Bazwise, *[How to update VMware ESXi free 8.0 Update 3e](https://bazwise.com/how-to-update-esxi-free-2026/)*
- [Apple software license agreements](https://www.apple.com/legal/sla/)

## Credits and license

- The original guide and its screenshots are the work of **eldxmgw** and remain the author's.
  The guide and its translation are included here with credit and a link back; they are **not**
  covered by this repository's license.
- Unlocker: Dave Parsons (DrDonk) and contributors, MIT License.
- Translation, revised guide, `scripts/esxi-pt.sh` and the test-suite: © 2026 startergo,
  [MIT License](LICENSE).
