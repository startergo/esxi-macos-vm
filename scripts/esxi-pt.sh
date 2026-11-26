#!/bin/sh
# ---------------------------------------------------------------------------
# esxi-pt.sh - host-side helper for the guide "macOS VM on VMware ESXi with
#              GPU and USB passthrough" (README.md in the repository root).
#
# Runs in the ESXi Shell or over SSH on the ESXi host itself, as root. Written
# for ESXi's BusyBox ash: POSIX sh only. Start with:  sh esxi-pt.sh --help
#
# Commands that change something show a preview first and ask for
# confirmation; --dry-run only previews. Every edited file is backed up.
# Exit status: 0 = done, anything else = error or declined at the prompt.
# ---------------------------------------------------------------------------

set -u

PROG=${0##*/}

DRY_RUN=0              # preview only
ASSUME_YES=0           # do not ask
FORCE=0                # ignore the VM lock check
QUIRK=UQ_KBD_IGNORE    # kernel quirk applied by 'usb host-ignore'
REV=0x0000:0xffff      # revision range of new quirks
ROOT=                  # prefix for /etc and /bootbank (used by the test-suite)

HOST_CONFIG=/etc/vmware/config
BOOTCFG=/bootbank/boot.cfg
DATASTORES=/vmfs/volumes
TMPFILES=
TMPN=0
TMPF=
SPEC=

usage() {
    cat <<EOF
Usage: $PROG [options] COMMAND [arguments]

Commands:
  status [--all]           Host version, VMkernel boot options, kernelopt line,
                           usb.quirks and the passthrough-capable PCI devices
                           (--all lists every PCI device; PT = passthrough on)
  acs-check on|off         VMkernel.Boot.disableACSCheck   (off = guide step 8)
  vga-console on|off       VMkernel.Boot.vga, the DCUI console (off = guide step 9)
  pci list                 The PCI device table of 'status'
  pci on|off ADDRESS       Passthrough for one device, e.g. 0000:01:00.0
                           (guide step 10; needs ESXi 7.0 or later)
  usb list                 USB devices; HID = keyboard, mouse or similar
  usb host-allow ID...     /etc/vmware/config:  usb.quirks.deviceN = "0xID allow"
  usb host-ignore ID...    /bootbank/boot.cfg:   CONFIG./USB/quirks=... in kernelopt
  vmx find                 The .vmx files on the datastores
  vmx show VMX             Passthrough-related parameters of a VM
  vmx usb VMX ID...        VMX: usb.generic.allowHID and usb.quirks.deviceN
  vmx gpu VMX --rom FILE   VMX: pciPassthruN.opromEnabled, pciPassthruN.filename and
                           svga.present (N = 0, or chosen with -i N or --device ID)
  vmx get VMX KEY          Print one parameter's value
  vmx set VMX KEY VALUE [...]  Set any parameter, e.g. vmx set VMX svga.present FALSE

Options (before the command):
  -n, --dry-run        Show what would change, write nothing
  -y, --yes            Do not ask for confirmation
  -f, --force          Edit the VMX although a lock directory exists next to it
      --quirk NAME     Kernel quirk for 'usb host-ignore' (default: UQ_KBD_IGNORE)
      --rev LOW:HIGH   Revision range for new quirks      (default: 0x0000:0xffff)
      --root DIR       Prefix for /etc and /bootbank      (test-suite only)

ID is a USB vendor:product ID:  05ac:0250  or  0x05ac:0x0250.
'usb host-allow' and 'usb host-ignore' accept --remove before the IDs.
EOF
}

# ------------------------------------------------------------- output ------

say()  { printf '%s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
add()  { printf '  + %s\n' "$*"; }
del()  { printf '  - %s\n' "$*"; }
ok()   { printf '[ok] %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# abort : the user declined. Exits the whole script - a command substitution
# would swallow a plain return, and the caller must not carry on.
abort() {
    say "Aborted - nothing was changed."
    exit 1
}

# ------------------------------------------------------------- plumbing ----

cleanup() { for _f in ${TMPFILES:-}; do rm -f "$_f"; done; }
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 1' HUP INT TERM

# newtmp -> a fresh empty temporary file in $TMPF, removed on exit.
# Called directly, never in a command substitution: the counter has to live on.
newtmp() {
    TMPN=$((TMPN + 1))
    TMPF="${TMPDIR:-/tmp}/$PROG.$$.$TMPN"
    : > "$TMPF" || die "cannot write $TMPF"
    TMPFILES="$TMPFILES $TMPF"
}

# confirm QUESTION -> 0 to go ahead (always, under --yes or --dry-run)
confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    printf '%s [y/N] ' "$1"
    if read -r _ans; then
        case $_ans in
            [yY]|[yY][eE][sS]) return 0 ;;
        esac
    fi
    return 1
}

# run COMMAND... : execute it, or only echo it under --dry-run
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry run] would run: $*"
        return 0
    fi
    "$@"
}

# backup FILE -> FILE.bak.<timestamp>; a second backup within the same second
# gets a suffix, so an earlier backup is never overwritten
backup() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    _b="$1.bak.$(date +%Y%m%d-%H%M%S)"
    _n=1
    while [ -e "$_b" ]; do
        _n=$((_n + 1))
        _b="$1.bak.$(date +%Y%m%d-%H%M%S).$_n"
    done
    cp -p "$1" "$_b" || die "could not write backup $_b"
    say "  backup: $_b"
}

# commit NEWFILE TARGET MESSAGE : replace TARGET's content with NEWFILE's,
# keeping its mode, owner and inode
commit() {
    if [ "$DRY_RUN" -eq 1 ]; then
        say "[dry run] nothing was written."
        return 0
    fi
    cat "$1" > "$2" || die "cannot write $2"
    ok "$3"
}

# ends_with_newline FILE : 0 if the last line of FILE ends with a newline
ends_with_newline() {
    [ "$(awk 'END { print NR }' "$1")" -eq "$(wc -l < "$1")" ]
}

ensure_final_newline() {
    ends_with_newline "$1" || printf '\n' >> "$1"
}

# --------------------------------------------------------- ID handling -----

# norm_id ID -> "vvvv:dddd" (lower case, no 0x) or abort
norm_id() {
    _n=$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' \t' ':' | sed 's/0x//g' | tr -d '[:space:]')
    case $_n in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) die "'$1' is not a valid ID (four hex digits each, e.g. 05ac:0250 or 0x05ac:0x0250)" ;;
    esac
    printf '%s\n' "$_n"
}

# list_contains "a b c" b
list_contains() {
    case " $1 " in
        *" $2 "*) return 0 ;;
    esac
    return 1
}

# collect_ids ID... -> "vvvv:dddd vvvv:dddd" (normalised, duplicates dropped)
collect_ids() {
    _out=
    for _a in "$@"; do
        _i=$(norm_id "$_a") || exit
        list_contains "$_out" "$_i" && continue
        _out="$_out${_out:+ }$_i"
    done
    [ -n "$_out" ] || die "no device ID given"
    printf '%s\n' "$_out"
}

# next_index FILE PREFIX -> one more than the highest N in "PREFIX N =" (0 if none)
next_index() {
    _max=$(grep -i "^ *$2[0-9][0-9]* *=" "$1" 2>/dev/null \
            | sed 's/^ *[^0-9]*\([0-9][0-9]*\) *=.*/\1/' | sort -n | tail -n 1)
    if [ -n "$_max" ]; then printf '%s\n' "$((_max + 1))"; else printf '0\n'; fi
}

# allowed_ids FILE -> "vvvv:dddd ..." taken from usb.quirks.deviceN = "0xvvvv:0xdddd allow" lines
allowed_ids() {
    [ -f "$1" ] || return 0
    grep -i '^ *usb\.quirks\.device[0-9][0-9]* *= *"' "$1" \
        | sed 's/.*"\(0x\)\{0,1\}\([0-9a-fA-F]*\):\(0x\)\{0,1\}\([0-9a-fA-F]*\).*/\2:\4/' \
        | tr '[:upper:]' '[:lower:]' | tr '\n' ' '
}

# --------------------------------------------------------- VMX helpers -----
# A VMX file is a list of "key = "value"" lines; keys are case-insensitive.

# vmx_resolve PATH -> sets VMX after checking that the file exists and is not locked
vmx_resolve() {
    VMX=$1
    [ -f "$VMX" ] || die "VMX file not found: $VMX"
    case $VMX in
        *.vmx) ;;
        *) warn "$VMX does not end in .vmx" ;;
    esac
    if [ -d "${VMX%.vmx}.vmx.lck" ] || [ -d "$VMX.lck" ]; then
        if [ "$FORCE" -eq 1 ]; then
            warn "a lock directory exists next to $VMX - continuing because of --force"
        else
            die "a lock directory exists next to $VMX - the VM is probably running or in use.
Power it off first (or unregister it), or pass --force."
        fi
    fi
}

# vmx_line VMX KEY -> the raw line(s) for KEY, matched case-insensitively
vmx_line() {
    awk -v key="$2" '
        BEGIN { k = tolower(key) }
        {
            eq = index($0, "=")
            if (eq > 0) {
                kk = tolower(substr($0, 1, eq - 1))
                gsub(/^[ \t]+|[ \t]+$/, "", kk)
                if (kk == k) print
            }
        }' "$1"
}

# vmx_lines_prefix VMX PREFIX -> the raw lines of every KEY that starts with PREFIX
vmx_lines_prefix() {
    awk -v p="$2" '
        BEGIN { p = tolower(p) }
        {
            eq = index($0, "=")
            if (eq > 0) {
                kk = tolower(substr($0, 1, eq - 1))
                gsub(/^[ \t]+|[ \t]+$/, "", kk)
                if (index(kk, p) == 1) print
            }
        }' "$1"
}

# vmx_get VMX KEY -> value without quotes (exit 1 if the key is absent)
vmx_get() {
    awk -v key="$2" '
        BEGIN { k = tolower(key) }
        {
            eq = index($0, "=")
            if (eq > 0) {
                kk = tolower(substr($0, 1, eq - 1))
                gsub(/^[ \t]+|[ \t]+$/, "", kk)
                if (kk == k) {
                    v = substr($0, eq + 1)
                    gsub(/^[ \t]+|[ \t]+$/, "", v)
                    gsub(/^"|"$/, "", v)
                    print v
                    found = 1
                }
            }
        }
        END { exit (found ? 0 : 1) }' "$1"
}

vmx_is_true() {
    _v=$(vmx_get "$1" "$2") || return 1
    case $_v in
        [Tt][Rr][Uu][Ee]) return 0 ;;
    esac
    return 1
}

# vmx_show_change VMX KEY VALUE : preview "- old line" and "+ new line"
vmx_show_change() {
    vmx_line "$1" "$2" | while IFS= read -r _l; do del "$_l"; done
    add "$2 = \"$3\""
}

# spec_begin / spec_add : a list of "KEY=VALUE" lines to apply to a VMX
spec_begin() {
    newtmp
    SPEC=$TMPF
}

spec_add() {
    case $1 in
        ''|*=*|*\"*|*\\*) die "invalid parameter name: '$1'" ;;
    esac
    case $2 in
        *\"*|*\\*) die "a value must not contain quotes or backslashes: '$2'" ;;
    esac
    printf '%s=%s\n' "$1" "$2" >> "$SPEC"
}

# vmx_preview SPEC : show every change of a spec file for $VMX
vmx_preview() {
    while IFS= read -r _l; do
        vmx_show_change "$VMX" "${_l%%=*}" "${_l#*=}"
    done < "$1"
}

# vmx_apply OUT VMX SPEC : write to OUT the VMX with every "KEY=VALUE" line of SPEC applied.
# An existing KEY (whatever its spelling) is replaced in place; a new KEY is appended.
vmx_apply() {
    awk -v spec="$3" '
        BEGIN {
            while ((getline line < spec) > 0) {
                eq = index(line, "=")
                n++
                k[n] = tolower(substr(line, 1, eq - 1))
                o[n] = substr(line, 1, eq - 1)
                v[n] = substr(line, eq + 1)
            }
        }
        {
            eq = index($0, "=")
            if (eq > 0) {
                key = tolower(substr($0, 1, eq - 1))
                gsub(/^[ \t]+|[ \t]+$/, "", key)
                for (i = 1; i <= n; i++)
                    if (k[i] == key && !d[i]) {
                        d[i] = 1
                        print o[i] " = \"" v[i] "\""
                        next
                    }
            }
            print
        }
        END { for (i = 1; i <= n; i++) if (!d[i]) print o[i] " = \"" v[i] "\"" }' "$2" > "$1" \
        || die "cannot read $2"
}

# vmx_pt_index VMX VENDOR DEVICE -> N of the single "pciPassthruN" entry whose
# deviceId is DEVICE (and vendorId is VENDOR, when VENDOR is not empty), else exit 1
vmx_pt_index() {
    awk -v vid="$2" -v did="$3" '
        BEGIN { anyvendor = (vid == "") }
        tolower($0) ~ /^[ \t]*pcipassthru[0-9][0-9]*\.(deviceid|vendorid)[ \t]*=/ {
            l = tolower($0)
            key = l
            sub(/=.*/, "", key)
            val = l
            sub(/.*=[ \t]*"/, "", val)
            sub(/".*/, "", val)
            sub(/^0x/, "", val)
            idx = key
            sub(/^[ \t]*pcipassthru/, "", idx)
            sub(/\..*/, "", idx)
            if (key ~ /\.deviceid/) dev[idx] = val
            else ven[idx] = val
        }
        END {
            for (i in dev)
                if (dev[i] == did && (anyvendor || ven[i] == vid)) {
                    print i
                    hits++
                }
            exit (hits == 1) ? 0 : 1
        }' "$1"
}

# vmx_write SPEC MESSAGE : ask, back up and write $VMX
vmx_write() {
    confirm "Update the VMX?" || abort
    newtmp
    vmx_apply "$TMPF" "$VMX" "$1"
    ensure_final_newline "$TMPF"
    backup "$VMX"
    commit "$TMPF" "$VMX" "$2"
}

# ------------------------------------------------------ kernel settings ----

# kopt_get SETTING -> its Value column in 'esxcli system settings kernel list' (empty if absent)
kopt_get() {
    have esxcli || return 0
    esxcli system settings kernel list 2>/dev/null \
        | awk -v k="$1" 'tolower($1) == tolower(k) { print $3; exit }'
}

# kopt_show SETTING HINT
kopt_show() {
    _v=$(kopt_get "$1")
    say "    $1 = ${_v:-not listed}   ($2)"
}

# set_kopt SETTING VALUE WHAT
set_kopt() {
    say "VMkernel boot option $1 = $2   ($3)"
    confirm "Apply?" || abort
    run esxcli system settings kernel set -s "$1" -v "$2" || die "esxcli failed"
    [ "$DRY_RUN" -eq 1 ] && return 0
    ok "set. Put the host in maintenance mode and reboot for it to take effect."
}

# ------------------------------------------------------------ commands -----

cmd_status() {
    _all=0
    [ "${1:-}" = "--all" ] && _all=1
    say "== ESXi host =="
    if have esxcli; then
        esxcli system version get 2>/dev/null | awk -F ': *' \
            '/^(Product|Version|Build|Update|Patch):/ { printf "    %-8s %s\n", $1 ":", $2 }'
        say "== VMkernel boot options (a reboot applies them) =="
        kopt_show disableACSCheck "guide step 8: off"
        kopt_show vga "guide step 9: off"
    else
        warn "esxcli not found - this command is only useful on an ESXi host."
    fi
    say "== $BOOTCFG =="
    if [ -f "$ROOT$BOOTCFG" ]; then
        _k=$(grep '^kernelopt=' "$ROOT$BOOTCFG")
        if [ -n "$_k" ]; then info "${_k#kernelopt=}"; else warn "no kernelopt line found"; fi
    else
        warn "file not found"
    fi
    say "== $HOST_CONFIG =="
    if [ -f "$ROOT$HOST_CONFIG" ]; then
        _q=$(grep -i '^ *usb\.quirks\.device[0-9][0-9]* *=' "$ROOT$HOST_CONFIG")
        if [ -n "$_q" ]; then printf '%s\n' "$_q" | sed 's/^/    /'; else info "(no usb.quirks entries)"; fi
    else
        warn "file not found"
    fi
    if have esxcli; then
        say "== PCI devices  (PT = passthrough enabled, Cap = passthrough capable) =="
        pci_table "$_all"
        [ "$_all" -eq 1 ] || info "Only passthrough-capable devices are listed; 'status --all' lists every device."
    fi
    return 0
}

# One record of 'esxcli hardware pci list' starts at its "Address:" line.
pci_table() {
    esxcli hardware pci list 2>/dev/null | awk -v all="$1" '
        function value() {                 # the text after the colon of the current line
            v = substr($0, index($0, ":") + 1)
            sub(/^ +/, "", v)
            return v
        }
        function flush() {
            if (addr == "") return
            pt = (co ~ /[Pp]assthru/) ? "on" : "-"
            if (all != 1 && cap == "false" && pt == "-") return
            cap = (cap == "true" ? "yes" : (cap == "false" ? "no" : "?"))
            printf "    %-13s %-3s %-4s %-13s %s\n", addr, pt, cap, tolower(vid) ":" tolower(did), name
        }
        /^[ \t]*Address:/          { flush(); addr = $2; co = ""; cap = ""; vid = ""; did = ""; name = "" }
        /^[ \t]*Configured Owner:/ { co = value() }
        /^[ \t]*Passthru Capable:/ { cap = tolower($NF) }
        /^[ \t]*Vendor ID:/        { vid = $NF }
        /^[ \t]*Device ID:/        { did = $NF }
        /^[ \t]*Device Name:/      { name = value() }
        END { flush() }'
}

cmd_pci() {
    case ${1:-} in
        list)
            have esxcli || die "esxcli not found - run this on an ESXi host"
            pci_table 0
            ;;
        on|off)
            case ${2:-} in
                [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F].[0-9a-fA-F]) ;;
                *) die "usage: $PROG pci on|off ADDRESS   (e.g. $PROG pci on 0000:01:00.0)" ;;
            esac
            case $1 in
                on)  _en=true ;;
                off) _en=false ;;
            esac
            say "PCI device $2 - passthrough $_en"
            confirm "Apply?" || abort
            run esxcli hardware pci pcipassthru set -d "$2" -e "$_en" || die "esxcli failed"
            [ "$DRY_RUN" -eq 1 ] && return 0
            ok "set. Put the host in maintenance mode and reboot for it to take effect."
            ;;
        *) die "usage: $PROG pci list | on ADDRESS | off ADDRESS" ;;
    esac
    return 0
}

cmd_acs_check() {
    case ${1:-} in
        on)  set_kopt disableACSCheck FALSE "ACS check enabled - the ESXi default" ;;
        off) set_kopt disableACSCheck TRUE  "ACS check disabled - guide step 8" ;;
        *) die "usage: $PROG acs-check on|off" ;;
    esac
}

cmd_vga_console() {
    case ${1:-} in
        on)  set_kopt vga TRUE "VGA console / DCUI enabled - the ESXi default" ;;
        off)
            warn "with the VGA console disabled the DCUI shows a black screen."
            warn "SSH and the Host Client keep working; '$PROG vga-console on' reverts it."
            set_kopt vga FALSE "VGA console / DCUI disabled - guide step 9"
            ;;
        *) die "usage: $PROG vga-console on|off" ;;
    esac
}

cmd_usb_list() {
    have lsusb || die "lsusb not found - run this in the ESXi host shell"
    _allowed=$(allowed_ids "$ROOT$HOST_CONFIG")
    say "  ID            HID allow  name"
    say "  ------------  --- -----  ----"
    # "Bus 001 Device 004: ID 05ac:0250 Apple, Inc. Aluminium Keyboard (ISO)"
    lsusb -v 2>/dev/null | awk -v allowed="$_allowed" '
        function flush() {
            if (id != "") {
                st = ""
                n = split(allowed, a, " ")
                for (i = 1; i <= n; i++) if (a[i] == id) st = "yes"
                printf "  %-13s %-3s %-5s  %s\n", id, (hid ? "HID" : "-"), st, name
            }
        }
        /^Bus [0-9]+ Device [0-9]+: ID [0-9a-fA-F]+:[0-9a-fA-F]+/ {
            flush()
            id = tolower($6)
            hid = 0
            name = $7
            for (f = 8; f <= NF; f++) name = name " " $f
        }
        /HID Device Descriptor:/ { hid = 1 }
        END { flush() }'
    say
    say "HID devices are the ones that need the quirks. Next:"
    say "  $PROG usb host-allow ID...   then   $PROG usb host-ignore ID...   then   $PROG vmx usb VMX ID..."
    return 0
}

cmd_usb_host_allow() {
    _mode=add
    if [ "${1:-}" = "--remove" ]; then _mode=remove; shift; fi
    _ids=$(collect_ids "$@") || exit
    _cfg="$ROOT$HOST_CONFIG"
    [ -f "$_cfg" ] || die "$HOST_CONFIG not found"
    newtmp

    if [ "$_mode" = remove ]; then
        say "$HOST_CONFIG - remove:"
        for _id in $_ids; do
            grep -i "\"0x${_id%%:*}:0x${_id##*:}" "$_cfg" | sed 's/^/  - /'
        done
        awk -v ids="$_ids" '
            BEGIN { n = split(ids, w, " "); for (i = 1; i <= n; i++) want[w[i]] = 1 }
            tolower($0) ~ /^ *usb\.quirks\.device[0-9][0-9]* *= *"/ {
                l = tolower($0)
                key = ""
                if (match(l, /0x[0-9a-f]+:0x[0-9a-f]+/)) {
                    key = substr(l, RSTART, RLENGTH)
                    gsub(/0x/, "", key)
                }
                if (key in want) { dropped++; next }
                printf "usb.quirks.device%d = %s\n", cnt++, substr($0, index($0, "\""))
                next
            }
            { print }
            END { exit (dropped ? 0 : 4) }' "$_cfg" > "$TMPF"
        case $? in
            0) ;;
            4) ok "nothing to do - none of these IDs is in $HOST_CONFIG"; return 0 ;;
            *) die "cannot read $_cfg" ;;
        esac
        say "  the remaining entries keep their order and are renumbered:"
        grep -i '^usb\.quirks\.device' "$TMPF" | sed 's/^/  + /'
    else
        _existing=$(allowed_ids "$_cfg")
        _next=$(next_index "$_cfg" usb.quirks.device)
        _lines=
        for _id in $_ids; do
            if list_contains "$_existing" "$_id"; then
                info "$_id is already in $HOST_CONFIG"
                continue
            fi
            _lines="${_lines}usb.quirks.device${_next} = \"0x${_id%%:*}:0x${_id##*:} allow\"
"
            _next=$((_next + 1))
        done
        [ -n "$_lines" ] || { ok "nothing to do"; return 0; }
        cat "$_cfg" > "$TMPF"
        ensure_final_newline "$TMPF"
        printf '%s' "$_lines" >> "$TMPF"
        say "$HOST_CONFIG - append:"
        printf '%s' "$_lines" | sed 's/^/  + /'
    fi
    confirm "Edit $HOST_CONFIG?" || abort
    backup "$_cfg"
    commit "$TMPF" "$_cfg" "done. A host reboot is needed for it to take effect."
}

cmd_usb_host_ignore() {
    _mode=add
    if [ "${1:-}" = "--remove" ]; then _mode=remove; shift; fi
    _ids=$(collect_ids "$@") || exit
    _cfg="$ROOT$BOOTCFG"
    [ -f "$_cfg" ] || die "$BOOTCFG not found"
    grep -q '^kernelopt=' "$_cfg" || die "no kernelopt= line in $BOOTCFG"
    case $QUIRK in
        ''|*[!A-Za-z0-9_]*) die "--quirk wants a quirk name such as UQ_KBD_IGNORE" ;;
    esac
    case $REV in
        *[!0-9a-fA-Fx:]*|*:*:*) die "--rev wants LOW:HIGH, e.g. 0x0000:0xffff or :0xffff" ;;
    esac

    newtmp
    # The kernelopt line is rewritten in place; every other line is copied as it is.
    awk -v ids="$_ids" -v quirk="$QUIRK" -v mode="$_mode" -v rev="$REV" '
        BEGIN {
            nids = split(ids, idl, " ")
            if (mode == "remove") for (i = 1; i <= nids; i++) wanted[idl[i]] = 1
            low = rev
            high = rev
            sub(/:.*/, "", low)
            sub(/.*:/, "", high)
        }
        function load_units(opt,   n, part, i, key, v, d) {
            n = split(opt, part, ":")
            for (i = 1; i + 4 <= n; i += 5) {       # groups of five: vendor:device:min:max:quirk
                key = tolower(part[i] ":" part[i + 1])
                gsub(/0x/, "", key)
                if (key in seen) continue
                seen[key] = 1
                if (mode == "remove" && key in wanted) { changed++; continue }
                m++
                u[m] = part[i] ":" part[i + 1] ":" part[i + 2] ":" part[i + 3] ":" part[i + 4]
            }
            if (mode == "add")
                for (i = 1; i <= nids; i++) {
                    if (idl[i] in seen) continue
                    v = idl[i]
                    d = v
                    sub(/:.*/, "", v)
                    sub(/.*:/, "", d)
                    m++
                    u[m] = "0x" v ":0x" d ":" low ":" high ":" quirk
                    changed++
                }
        }
        /^kernelopt=/ {
            nk++
            val = substr($0, 11)                 # strip "kernelopt="
            if (val ~ /^"/) quoted = 1
            keep = ""
            opt = ""
            n = split(val, tok, " ")
            for (i = 1; i <= n; i++) {
                if (tok[i] ~ /^CONFIG\.\/USB\/quirks=/) opt = tok[i]
                else keep = keep (keep == "" ? "" : " ") tok[i]
            }
            opt = substr(opt, 20)                # strip "CONFIG./USB/quirks="
            load_units(opt)
            merged = ""
            for (i = 1; i <= m; i++) merged = merged (i > 1 ? ":" : "") u[i]
            $0 = "kernelopt=" keep (keep == "" ? "" : " ") (m > 0 ? "CONFIG./USB/quirks=" merged : "")
        }
        { print }
        END {
            if (nk != 1 || quoted) exit 3
            if (!changed) exit 4
        }' "$_cfg" > "$TMPF"
    case $? in
        0) ;;
        3) die "unexpected format in $BOOTCFG - need exactly one unquoted kernelopt line" ;;
        4) ok "nothing to do - the kernelopt line is already in the requested state"; return 0 ;;
        *) die "cannot read $_cfg" ;;
    esac
    ensure_final_newline "$TMPF"
    [ "$(awk 'END { print NR }' "$_cfg")" -eq "$(awk 'END { print NR }' "$TMPF")" ] \
        || die "internal error: the line count of $BOOTCFG would change"

    say "$BOOTCFG:"
    del "$(grep '^kernelopt=' "$_cfg")"
    add "$(grep '^kernelopt=' "$TMPF")"
    confirm "Rewrite the kernelopt line?" || abort
    backup "$_cfg"
    commit "$TMPF" "$_cfg" "done. Put the host in maintenance mode and reboot for it to take effect."
}

cmd_vmx_find() {
    [ -d "$ROOT$DATASTORES" ] || die "$DATASTORES not found - run this on an ESXi host"
    # Each datastore appears twice under /vmfs/volumes, by name and by UUID;
    # the UUID form (8-4-4-4-12 hex digits) is dropped so every VMX is listed once.
    find "$ROOT$DATASTORES"/*/ -maxdepth 2 -name '*.vmx' 2>/dev/null \
        | grep -Ev "^$ROOT$DATASTORES/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-" \
        | sort
    return 0
}

cmd_vmx_show() {
    vmx_resolve "$1"
    say "$VMX:"
    awk 'tolower($0) ~ /^[ \t]*(pcipassthru[0-9]+|svga\.present|usb|guestos|virtualhw\.version|firmware|ethernet0\.virtualdev)/' "$VMX" \
        | sed 's/^/    /'
    return 0
}

cmd_vmx_usb() {
    vmx_resolve "$1"
    shift
    _ids=$(collect_ids "$@") || exit
    _existing=$(allowed_ids "$VMX")
    _next=$(next_index "$VMX" usb.quirks.device)
    spec_begin
    if ! vmx_is_true "$VMX" usb.generic.allowHID; then
        spec_add usb.generic.allowHID TRUE
        _changed=1
    fi
    for _id in $_ids; do
        if list_contains "$_existing" "$_id"; then
            info "$_id is already in the VMX"
            continue
        fi
        spec_add "usb.quirks.device$_next" "0x${_id%%:*}:0x${_id##*:} allow"
        _next=$((_next + 1))
        _changed=1
    done
    if [ -z "${_changed:-}" ]; then
        ok "nothing to do - the VMX already has everything"
        return 0
    fi
    say "$VMX:"
    vmx_preview "$SPEC"
    vmx_write "$SPEC" "done. Add the USB devices to the VM in the Host Client next (guide part 3)."
}

cmd_vmx_gpu() {
    vmx_resolve "$1"
    shift
    _rom=
    _idx=
    _dev=
    while [ $# -gt 0 ]; do
        case $1 in
            --rom)      [ $# -ge 2 ] || die "--rom needs a file path"; _rom=$2; shift 2 ;;
            -i|--index) [ $# -ge 2 ] || die "$1 needs a number"; _idx=$2; shift 2 ;;
            --device)   [ $# -ge 2 ] || die "--device needs an ID"; _dev=$2; shift 2 ;;
            *) die "unknown option: $1" ;;
        esac
    done
    [ -n "$_rom" ] || die "usage: $PROG vmx gpu VMX --rom FILE [-i N | --device ID]"

    _p=pciPassthru0
    if [ -z "$_idx" ] && [ -n "$_dev" ]; then
        # --device takes "vendor:device" (1002:67df) or the device ID alone (67df)
        _any=0
        case $_dev in
            *:*) _dev=$(norm_id "$_dev") || exit ;;
            *)
                _dev=$(norm_id "0000:$_dev") || exit
                _dev=${_dev#*:}
                _any=1
                ;;
        esac
        if [ $_any -eq 1 ]; then
            _dvid=
            _ddid=$_dev
        else
            _dvid=${_dev%%:*}
            _ddid=${_dev##*:}
        fi
        _found=$(vmx_pt_index "$VMX" "$_dvid" "$_ddid") \
            || warn "no single pciPassthruN entry with deviceId 0x$_ddid${_dvid:+ and vendorId 0x$_dvid} found - using index 0."
        [ -z "$_found" ] || _idx=$_found
    fi
    if [ -n "$_idx" ]; then
        case $_idx in
            ''|*[!0-9]*) die "the index must be a number" ;;
        esac
        _p="pciPassthru$_idx"
    fi

    say "$VMX - entries of $_p:"
    vmx_lines_prefix "$VMX" "$_p." | sed 's/^/    /'
    vmx_is_true "$VMX" "$_p.present" \
        || warn "no '$_p.present = \"TRUE\"' in this VMX - add the GPU to the VM in the Host Client first."
    case $_rom in
        /*) ;;
        *)  [ -f "$(dirname "$VMX")/$_rom" ] \
                || warn "$(dirname "$VMX")/$_rom does not exist - a relative filename is resolved from the VM's folder." ;;
    esac

    spec_begin
    spec_add "$_p.opromEnabled" TRUE
    spec_add "$_p.filename" "$_rom"
    spec_add svga.present FALSE
    say "  changes:"
    vmx_preview "$SPEC"
    vmx_write "$SPEC" "done."
}

cmd_vmx_get() {
    vmx_resolve "$1"
    [ $# -ge 2 ] || die "usage: $PROG vmx get VMX KEY"
    _v=$(vmx_get "$VMX" "$2") || die "no line for '$2' in $VMX"
    say "$_v"
}

cmd_vmx_set() {
    vmx_resolve "$1"
    shift
    if [ $# -lt 2 ] || [ $(( $# % 2 )) -ne 0 ]; then
        die "usage: $PROG vmx set VMX KEY VALUE [KEY VALUE ...]"
    fi
    spec_begin
    while [ $# -ge 2 ]; do
        spec_add "$1" "$2"
        shift 2
    done
    say "$VMX:"
    vmx_preview "$SPEC"
    vmx_write "$SPEC" "done."
}

# ---------------------------------------------------------------- main -----

while [ $# -gt 0 ]; do
    case $1 in
        -n|--dry-run)  DRY_RUN=1 ;;
        -y|--yes)      ASSUME_YES=1 ;;
        -f|--force)    FORCE=1 ;;
        --quirk)       [ $# -ge 2 ] || die "--quirk needs a name"; QUIRK=$2; shift ;;
        --rev)         [ $# -ge 2 ] || die "--rev needs LOW:HIGH"; REV=$2; shift ;;
        --root)        [ $# -ge 2 ] || die "--root needs a directory"; ROOT=$2; shift ;;
        -h|--help)     usage; exit 0 ;;
        --)            shift; break ;;
        -*)            die "unknown option: $1 (see --help)" ;;
        *)             break ;;
    esac
    shift
done

if [ -z "$ROOT" ] && [ "$(id -u)" != 0 ]; then
    warn "not running as root - changes will probably fail."
fi

CMD=${1:-}
[ $# -gt 0 ] && shift

case $CMD in
    status)      cmd_status "$@" ;;
    acs-check)   cmd_acs_check "$@" ;;
    vga-console) cmd_vga_console "$@" ;;
    pci)         cmd_pci "$@" ;;

    usb)
        SUB=${1:-}
        [ $# -gt 0 ] && shift
        case $SUB in
            list)        cmd_usb_list "$@" ;;
            host-allow)  cmd_usb_host_allow "$@" ;;
            host-ignore) cmd_usb_host_ignore "$@" ;;
            *) die "usage: $PROG usb list | host-allow ID... | host-ignore ID..." ;;
        esac
        ;;

    vmx)
        SUB=${1:-}
        [ $# -gt 0 ] && shift
        case $SUB in
            find) cmd_vmx_find "$@" ;;
            show) cmd_vmx_show "$@" ;;
            usb)  cmd_vmx_usb "$@" ;;
            gpu)  cmd_vmx_gpu "$@" ;;
            get)  cmd_vmx_get "$@" ;;
            set)  cmd_vmx_set "$@" ;;
            *) die "usage: $PROG vmx find | show VMX | usb VMX ID... | gpu VMX --rom FILE | get VMX KEY | set VMX KEY VALUE" ;;
        esac
        ;;

    help)        usage ;;
    '')          usage >&2; exit 1 ;;
    *)           die "unknown command: $CMD (see --help)" ;;
esac
