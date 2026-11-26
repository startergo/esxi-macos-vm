# How-to: VMware ESXi Hackintosh host with RX 480 passthrough and input devices

> **Translation note.** This is a complete English translation of the German thread
> *“Howto: VMware ESXi Hackintosh Host mit Passthrough RX480 und Eingabegeräte”*
> by **eldxmgw**, first published on hackintosh-forum.de on 7 January 2023.
> The wording stays close to the original. Additions by the translator are marked
> *TN*; headings, code blocks and links have been added for readability (the
> original is a flat list). The screenshots are not re-hosted — every “image N”
> links to the original attachment on the forum.
>
> * The original guide is the work of eldxmgw and remains the author's.
> * A practical, reorganised version of this guide lives in the project [README](../README.md).
>
> **Original thread:** <https://www.hackintosh-forum.de/forum/thread/57423-howto-vmware-esxi-hackintosh-host-mit-passthrough-rx480-und-eingabegeräte/>

**Contents**

| Post | Author | Date | Subject |
| --- | --- | --- | --- |
| [#1](#post-1--the-guide) | eldxmgw | 7 Jan 2023 (edited 24 Feb 2023) | The guide |
| [#2](#post-2--audience-and-host-hardware) | eldxmgw | 7 Jan 2023 | Audience and host hardware |
| [#3](#post-3--ventura-update) | eldxmgw | 7 Jan 2023 | Ventura update |
| [#4](#post-4--licensing-question) | edifant | 7 Jan 2023 | Licensing question |
| [#5](#post-5--licensing-answer) | eldxmgw | 7 Jan 2023 | Licensing answer |

---

## Post #1 — the guide

**eldxmgw** · 7 January 2023 · edited by eldxmgw, 24 February 2023 — *“Added the correct download link for the ESXi unlocker.”*

### What works

I can report that I have now got my Monterey VM on ESXi 7.0U3g-20328353 set up and fully working. (See [images 1][img1], [5][img5], [10][img10], [10.5][img10-5], [11][img11], [12][img12], [13][img13], [14][img14].)

- The RX 480 passed through via HDMI is detected natively and has full Metal support. It drives a 34″ 21:9 monitor at native resolution and 60 Hz.
- I have disabled VMware's default VGA device in the VMkernel. This does disable normal operation of the DCUI, but that is moot once the initial setup is done, and it can quickly be reverted if it is absolutely necessary.
- I added two RX 480 passthrough configuration flags to the VMX, in particular the one for the path to the VBIOS dump.
- RX 480 HDMI sound passthrough also works without any problems.
- I have also passed through an Apple keyboard (USB) and an MX Master 3 mouse (USB receiver) by entering them via vendor and device ID quirks in the boot.cfg, the VMware config file and the VMX, and added them in working order to the VM configuration (by the way, both input devices are actually hanging off a manual USB hub).
- USB 3.1 passthrough also works without a hitch.
- Contrary to various warnings, snapshots work perfectly fine with passthrough VMs.

All of this without any OC, extra kexts or other macOS patching. Earlier I also ironed the latest update on top, to 12.6.2. I have set up the VM so that I can use it directly at the monitor via the infrastructure, or via ARD. I control ESXi via the web UI, or centrally via vCenter.

> *TN: “OSX” in the original means macOS. OC = OpenCore. ARD = Apple Remote Desktop (its screen-sharing service is what the author relies on once the VM console is gone). The keyboard shows up in the ESXi Host Client as “Apple Matias Wired Keyboard”.*

One could now also think about instructing the hypervisor to start the macOS VM automagically after system start → hypervisor is initialized → VM is initialized → passthrough is active, in order to give the user the impression of a physical workstation with a single major release.

The user would not notice what is running in the layers around it. In principle that would be just what the classic Hackintosh conveyed. All of this is easy to set up in ESXi or in VM management.

One would only have to think through the administrative implementation of how the hypervisor should react if the user shuts down the macOS VM and expects the workstation (actually the host) to behave like a fat client and shut itself down as well.

Since the host should be put into maintenance mode before shutting down, that would have to be handled by a script (if you want that).

In principle, the steps can be completed quickly and easily.

*(Anyone who does not want to use passthrough is finished after step 7.)*

### Step by step

1. Install ESXi and do the basic setup (I tested this with 7.0U3g-20328353 and 8.0-20513097. The images show 7.0U3g).

2. Obtain the ESXi unlocker matching your ESXi version and apply it (freely available in David Parsons' GitHub repository: <https://github.com/DrDonk/esxi-unlocker>).

   > *TN (Nov 2026): that repository is no longer reachable. See [Status of the unlocker](../README.md#status-of-the-unlocker) in the README for what is known today.*

3. Convert the downloaded macOS major release to an ISO (here is a nice guide for Monterey, but it also applies, adapted, to Ventura: <https://nishtahir.com/how-to-create-a-macos-iso>).

4. Set up VMware storage.

5. Create the VM and do the basic setup. Don't forget to give the VM's NIC the adapter type **VMXNET 3**.

6. Roll out the macOS image and do the basic setup, then manually download the current VMware Tools for macOS and install them under macOS.

7. Enable ARD on the VM over the LAN.

8. I recommend, as a precaution, going to **Manage → System → Advanced Settings**, using the search for `pcie`, and setting the key `VMkernel.Boot.disableACSCheck` to `true` in order to override the PCIe function check at system start. ([image 2][img2])

   > *TN: the original names the German Host Client menus (“Verwalten → System → Erweiterte Einstellungen”); the English labels are given here.*

9. Disable the VMkernel VGA driver via an ESXCLI command, so that the passthrough GPU devices do not have to be manually enabled again after every reboot. Via SSH on the host, the following syntax:

   ```sh
   esxcli system settings kernel set -s vga -v FALSE
   ```

   (Caution: from this point on the DCUI quits with a black screen, see above) → restart.

10. Check whether the desired passthrough devices are active in the hypervisor's device management; if not, set them manually → restart. ([image 3][img3])

    > *TN: “device management” is **Manage → Hardware → PCI Devices** in the English Host Client (button “Toggle passthrough”).*

11. In the VM configuration, add the PCIe passthrough GPU as a **PCI device**. Do **not** use the dynamic PCIe variant. At least directly on the hypervisor, that did not work. ([image 4][img4])

12. **NOTE: SEE BELOW** Set `svga.present` to `FALSE` in the VMX (Caution: from here on, the VM web console no longer works. But that is not important either, since ARD is active and passthrough is being set up as well).

13. Obtain a matching VBIOS dump or read out your own (there are suitable ones here, but pay close attention to the exact specification. Example here: <https://www.techpowerup.com/vgabios/187376/powercolor-rx480-8192-160923>).

14. It is best to store the VBIOS dump directly on the VM storage, without any elaborate directory nesting.

15. Set the new parameter `pciPassthru0.opromEnabled` to `TRUE` in the VMX. ([image 9][img9])

16. Set the new parameter `pciPassthru0.filename` in the VMX to the correct path to the VBIOS dump on the VM storage. Example: `../Powercolor.RX480.8192.160923.rom`. ([image 9][img9])

17. Start the VM. PCIe passthrough should now work once the monitor has been set to the correct port. I just want to mention it: I have read that PCIe GPU passthrough is supposedly only possible via HDMI and not via DP. I cannot verify that at the moment. HDMI works for me with a 7 m cable.

18. If applicable, add further PCIe passthrough devices, such as HDMI sound or USB 3.1 (if present), to the VM configuration as PCI devices. Which devices of the overall system are passthrough-capable and supported at all can be seen in the ESXi device management. ([image 3][img3])

That's it, really. Anyone who now still wants to pass certain HID USB devices such as mouse and keyboard (in my case an Apple USB cable [keyboard] and a Logitech MX Master 3 USB receiver) through continues here…

### Passing through USB HID devices (keyboard and mouse)

- Log in to the hypervisor via SSH and determine the vendor and device ID of the desired HID passthrough USB devices with:

  ```sh
  lsusb -v | grep -E '(^Bus|HID)'
  ```

  When reading the output, the values after `ID` are the decisive ones (`vendorID:deviceID`). ([image 6][img6])

  Example:

  ```text
  Bus 001 Device 002: ID 1a40:0101 Terminus Technology Inc. Hub
  ```

- **Important:** from here on, the values get a `0x` prefixed. E.g. `0xXXXX` = vendorId and `0xYYYY` = deviceId.

- Configure `/etc/vmware/config` with vi, enter the values you determined according to the following scheme, and save… ([image 8][img8])

  Example:

  ```text
  usb.quirks.device0 = "0x05ac:0x0250 allow"
  usb.quirks.device1 = "0x046d:0xc52b allow"
  ```

- Now the VMkernel has to be told to stop constantly claiming the USB input devices for itself. To do this, open `/bootbank/boot.cfg` in vi and aim for the `kernelopt` line. ([image 7][img7])

  Example:

  ```text
  kernelopt=autoPartition=FALSE
  ```

  Directly behind it, separated by a space, the following notation is entered with your own determined vendor and device IDs — **vendorID:deviceID:minRevision:maxRevision:quirkName**

  Example for one device:

  ```text
  CONFIG./USB/quirks=0x05ac:0x0250:0x0000:0xffff:UQ_KBD_IGNORE
  ```

  Example for two devices:

  ```text
  CONFIG./USB/quirks=0x05ac:0x0250:0x0000:0xffff:UQ_KBD_IGNORE:0x046d:0xc52b:0x0000:0xffff:UQ_KBD_IGNORE
  ```

  Example of the whole `kernelopt` line with two devices:

  ```text
  kernelopt=autoPartition=FALSE CONFIG./USB/quirks=0x05ac:0x0250:0x0000:0xffff:UQ_KBD_IGNORE:0x046d:0xc52b:0x0000:0xffff:UQ_KBD_IGNORE
  ```

- The VM must likewise be told about the passthrough of the USB HID devices by means of the vendor and device ID. This can be done via the ESXi web UI in the VM's advanced configuration, or in the shell. The values, as entered previously in `/etc/vmware/config`, can be taken over here. The VMX is found in the shell under `/vmfs/volumes/VM Storage (share)/…` ([image 9][img9] and the **NOTE** below.)

  Example excerpt of the VMX with the newly entered values, in the shell:

  ```text
  usb.generic.allowHID = "TRUE"
  usb.quirks.device0 = "0x05ac:0x0250 allow"
  usb.quirks.device1 = "0x046d:0xc52b allow"
  ```

- Restart the hypervisor.

- Finally, the new USB HID devices still have to be added to the VM configuration in the ESXi web UI. ([image 4][img4])

After that everything is done, and it should correspond to the state described at the very top, with all PCIe + USB HID passthrough devices.

### Note on editing the VMX

**NOTE**

From step 11 on I keep mentioning the VMX. By this I mean, among other things, the configuration of the VM. There are basically two ways of editing it. Via the ESXi web UI in the GUI: **VM → Edit → VM Options → Advanced → Configuration Parameters → Edit Configuration**.

> *TN: the original names the German dialogs (“VM → bearbeiten → VM Optionen → Erweitert → Konfigurationsparameter → Konfiguration bearbeiten”).*

Or in the shell, in the VM's own directory: `/vmfs/volumes/VM Storage (share)/…/….vmx`

Two things are important here. Whether in the GUI or in the shell → the syntax should be watched meticulously. One space too many, a typo — easily done; you can't see the wood for the trees — it doesn't work, or the VM doesn't start, or it behaves strangely. It should also be clear that the way in which the parameters are entered differs from the GUI to the shell and the other way around — even though both end up in the VMX.

There is no single “right way” here. Depending on the situation, sometimes one way, sometimes the other is better.

Example with the same parameter…

via the web UI:

```text
pciPassthru0.opromEnabled TRUE
pciPassthru0.filename ../Powercolor.RX480.8192.160923.rom
```

via the shell in the `.vmx`:

```text
pciPassthru0.opromEnabled = "TRUE"
pciPassthru0.filename = "../Powercolor.RX480.8192.160923.rom"
```

I hope this helps someone. And always remember to put the hypervisor into maintenance mode before restarting or shutting it down! 🙂

The images for this how-to are attached below.

### Screenshots attached to the guide

All screenshots were taken by the author in a German-language interface and are hosted on hackintosh-forum.de.

| Image | What it shows |
| --- | --- |
| [1][img1] | ESXi Host Client, host overview: ESXi 7.0 Update 3 (image profile `ESXi-7.0U3g-20328353-standard`) on a Gigabyte Z170X-Gaming 3 with an Intel Core i7-6700K, 32 GB RAM, one datastore “VM Storage”, one VM “OSX Monterey”. |
| [2][img2] | *Manage → System → Advanced Settings*, filtered on `pcie`: `VMkernel.Boot.disableACSCheck` is set to `true` (default `false`). |
| [3][img3] | *Manage → Hardware → PCI Devices*: the Radeon RX 480 (`0000:01:00.0`), its HDMI audio function (`0000:01:00.1`) and the DSL6540 USB 3.1 controller (`0000:09:00.0`) are set to passthrough “Active”. |
| [4][img4] | *Edit Settings* of the VM: PCI device 1 = Radeon RX 480, 2 = Ellesmere HDMI audio, 3 = DSL6540 USB 3.1 controller; USB device 1 = Apple Matias Wired Keyboard, 2 = Logitech USB Receiver. |
| [5][img5] | VM overview: guest OS “Apple macOS 12 (64-bit)”, VMware Tools running, 8 vCPUs, 26 GB RAM; the hardware list shows the graphics card as “0 B”. |
| [6][img6] | SSH session: output of `lsusb -v \| grep -E '(^Bus\|HID)'`. |
| [7][img7] | `vi` on `/bootbank/boot.cfg` with the completed `kernelopt` line. |
| [8][img8] | `vi` on `/etc/vmware/config` with the two `usb.quirks.deviceN` lines. |
| [9][img9] | *VM Options → Advanced → Configuration Parameters*: `pciPassthru0.opromEnabled`, `pciPassthru0.filename`, `usb.generic.allowHID`, `usb.quirks.device0/1`. |
| [10][img10] | macOS Monterey 12.6.2 over Screen Sharing: System Information (model “VMware7,1”), About This Mac (“AMD Radeon RX 480 8 GB”), Displays (“LG ULTRAWIDE”, 60 Hertz), and `system_profiler SPDisplaysDataType \| grep Resolution` → 3440 × 1440. |
| [10.5][img10-5] | Enlarged view of About This Mac and the Displays settings. |
| [11][img11] | *System Information → Graphics/Displays*: AMD Radeon RX 480, 8 GB VRAM, device ID `0x67df`, Metal supported, LG ULTRAWIDE at 3440 × 1440 @ 60 Hz. |
| [12][img12] | *System Information → USB*: the USB 3.1 bus with the Logitech USB receiver and the Matias keyboard behind a VMware virtual USB hub. |
| [13][img13] | *System Information → Ethernet*: the VMXNET 3 adapter (`AppleVMnet3Ethernet`, `en0`). |
| [14][img14] | *System Settings → Sound*: output device “LG ULTRAWIDE” over HDMI. |
| [15][img15] | ESXi Host Client: a second VM “OSX Ventura” with the same three PCI devices; the Host Client notes that the configured guest OS (macOS 12) differs from the running guest (macOS 13). |
| [16][img16] | macOS Ventura 13.1 desktop: System Information, About This Mac and the Displays settings. |
| [16.5][img16-5] | Enlarged: Ventura's System Information for the RX 480 (“Metal 2”) and *System Settings → Displays* (3440 × 1440, 60 Hertz). |

---

## Post #2 — audience and host hardware

**eldxmgw** · 7 January 2023

This how-to is aimed primarily at those who have at least basic experience with type-1 hypervisors.

I hope that anyone interested in this recognises the dimension that this approach opens up.

Everyone is free to make further optimisations or changes as things develop.

**Bottom line:**

The now 5-year-old Hackintosh system, now a hypervisor host, is based on the following:

- GA-Z170X-Gaming 3
- Intel Skylake i7 4 GHz 6700K
- 32 GB RAM
- PowerColor Red Devil RX 480 8 GB VRAM
- various SSD and HDD storage

Most recently, a PCIe I210-T1 GbE NIC was bought for €9 for ESXi 7 and 8 compatibility. The on-board NIC was disabled.

In general, I recommend consulting the VMware compatibility chart: <https://www.vmware.com/resources/compatibility/search.php>

The system at the time was built modelled on an iMac 17,1 and worked in the classic fat-client Hackintosh way from Sierra to Mojave, as I used it before ESXi, mostly out of the box.

Since it still does that now, I will continue to use the macOS VM with the native passthrough devices, productively and as before, as an NLE workstation and photo-editing box. The system is not a playground. 🙂

---

## Post #3 — Ventura update

**eldxmgw** · 7 January 2023

*** VENTURA UPDATE ***

The new Ventura VM also runs flawlessly, just like the Monterey VM before it, with all passthrough devices. GPU with Metal support, USB 3.1, HDMI audio, mouse + keyboard passthrough — all out of the box.

As always, nothing was changed in macOS after installation. And that even with an obsolete Skylake architecture — thanks to the hypervisor layer, as always without having added anything like kexts, OC or anything else.

The procedure was the same as for Monterey.

Images attached as proof ([15][img15], [16][img16], [16.5][img16-5]).

---

## Post #4 — licensing question

**edifant** · 7 January 2023

> eldxmgw

Which licence are you working with? Free, or that thing —

Data Center Virtualization & Cloud Infrastructure

\# VMware vSphere Essentials Kit Term

Price: $268.00 ?

I only have licences for Fusion for Mac and VMware “Würgstation”*, otherwise I use Proxmox.

> *TN: “Würgstation” — a pun on “Workstation”, roughly “choking station”.*

---

## Post #5 — licensing answer

**eldxmgw** · 7 January 2023

As far as the vSphere package for ESXi is concerned, my infrastructure cluster, in terms of its hosts, is licensed with vSphere 7 Enterprise Plus including the add-on for Kubernetes.

For the procedure with the system as described in [#2](#post-2--audience-and-host-hardware), I used that same licence.

However, ESXi has a 60-day full evaluation period. No licence is needed at first.

As far as I remember — and I'm not completely wrong — the “free version” does not come with any real obstacle that would hinder the above in any way.

Well, a maximum of 8 vCPUs in the free version, but is that really a limit? 🙂

Everything else, compared with the paid versions, is irrelevant for most users and for this undertaking anyway, since the focus there is on infrastructure matters.

Perhaps this overview helps a little: <https://www.ubackup.com/enterprise-backup/vmware-esxi-free-limitations.html>

> *TN (Nov 2026): the licensing situation changed after this was written — see [ESXi licensing today](../README.md#esxi-licensing-today) in the README.*

> *TN (Nov 2026): the author returned to the subject in English in November 2026, in a [thread on MacRumors about eGPUs on the Mac Pro 2013](https://forums.macrumors.com/threads/egpu-working-on-linux-and-windows-macpro-6-1-macpro-2013.2488015/?post=34976634#post-34976634), and wrote that he still uses the system described here — see [On a real Mac](../README.md#on-a-real-mac).*

---

## Links to the original screenshots

[img1]: https://www.hackintosh-forum.de/attachment/203457-1-png/ "1.png"
[img2]: https://www.hackintosh-forum.de/attachment/203458-2-png/ "2.png"
[img3]: https://www.hackintosh-forum.de/attachment/203459-3-png/ "3.png"
[img4]: https://www.hackintosh-forum.de/attachment/203460-4-png/ "4.png"
[img5]: https://www.hackintosh-forum.de/attachment/203461-5-png/ "5.png"
[img6]: https://www.hackintosh-forum.de/attachment/203462-6-png/ "6.png"
[img7]: https://www.hackintosh-forum.de/attachment/203463-7-png/ "7.png"
[img8]: https://www.hackintosh-forum.de/attachment/203464-8-png/ "8.png"
[img9]: https://www.hackintosh-forum.de/attachment/203465-9-png/ "9.png"
[img10]: https://www.hackintosh-forum.de/attachment/203466-10-png/ "10.png"
[img10-5]: https://www.hackintosh-forum.de/attachment/203467-10-5-png/ "10.5.png"
[img11]: https://www.hackintosh-forum.de/attachment/203468-11-png/ "11.png"
[img12]: https://www.hackintosh-forum.de/attachment/203469-12-png/ "12.png"
[img13]: https://www.hackintosh-forum.de/attachment/203470-13-png/ "13.png"
[img14]: https://www.hackintosh-forum.de/attachment/203471-14-png/ "14.png"
[img15]: https://www.hackintosh-forum.de/attachment/203481-15-png/ "15.png"
[img16]: https://www.hackintosh-forum.de/attachment/203480-16-png/ "16.png"
[img16-5]: https://www.hackintosh-forum.de/attachment/203479-16-5-png/ "16.5.png"
