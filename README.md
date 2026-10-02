# Kali Attack VM

My personal Kali setup for QEMU/KVM, kept in a repo so the machine can be rebuilt from a stock Kali image quickly. It is built for my hardware, my network and my workflow. If you want to use any of it, expect to adjust IPs, paths and ssh assumptions before it works for you.

Parts that are reusable on their own: the guest config sync (`guest-configs/` + `07-zsh-tweaks.sh`), the toolkit installer (`provision/`), and the CTF workbench (`box`, `n`, `nhosts`).

## How it fits together

Two machines, one repo:

```
┌────────────────────────── physical host ──────────────────────────┐
│ libvirtd (qemu:///system) · br-kali 10.170.0.0/24 · nftables      │
│ VM egress masqueraded through Mullvad wg0 (kill-switch + LAN allow)│
└───────▲───────────────────────────────────────┬──────────────────┐
        │ kvirsh (libvirt socket)               │ virtiofs shares  │
        │ kssh (ssh, project .ssh/)              │ (work/ obsidian/ │
        │                                        │  shared/)        │
┌───────┴────────────────────────────────────────▼──────────────────┐
│  kali-vm guest · kali@10.170.0.2 · i3 + workbench                 │
└───────────────────────────────────────────────────────────────────┘
```

The repo's wrappers drive both machines: `kssh` (guest ssh), `kvirsh`
(host libvirt), `khost` (host ssh). They live in `bin/` and resolve the
repo root from their own location, so symlink them once:

```sh
ln -sfn "$PWD"/bin/{kssh,kvirsh,khost} ~/.local/bin/
```

They depend on `.ssh/` in the repo root (gitignored: key, config, known_hosts; bring your own).

## Layout

```
bin/             wrappers: kssh (guest ssh), kvirsh (host libvirt),
                 khost (host ssh); symlink into ~/.local/bin
host/            host side: bridge/firewall setup, boot service, libvirt XML
                 (domain, net, work share), nftables copy
provision/       guest toolkit installer, run inside the VM, idempotent
guest-configs/   all guest configs and helpers, deployed by 07-zsh-tweaks.sh
                 (includes pi/: the pi coding agent's settings, models, MCP and
                 AGENTS instructions; local inference only, no cloud keys)
07-zsh-tweaks.sh the deployer: rc/zshenv blocks, checksum-guarded config sync,
                 helper pushes, reloads i3/tmux/polybar when they change
work/            virtiofs share target, only wallpaper/ and the fallback png
                 belong to the repo, the rest is live data (gitignored)
```

Documentation: [SETUP.md](SETUP.md) is the ordered rebuild runbook.

## Prerequisites

First, create your local values file (secrets and machine-specific addresses
live there, gitignored):

```sh
cp values.sh.example values.sh   # fill in: host paths/user, inference IP, WPScan key
```

Host: Linux with QEMU/KVM, libvirt and nftables. The firewall rules assume a Mullvad VPN (edit `host/01-setup-host.sh` if you don't use one). The Kali qcow2 is downloaded at rebuild time from [kali.download](https://www.kali.org/get-kali/#kali-virtual) and is gitignored.

## The CTF workbench

Runs inside the guest.

### box

The workbench entry point (Python). One target = a directory under `~/work/ctf/` with direnv (BOX/IP/PLATFORM/STAGE), a per-box `AGENTS.md` (context for the pi agent), a three-pane tmux session with recon layout, and an Obsidian note indexed per platform:

```sh
box ServMon -i 10.10.10.184 -p htb -s -u   # scaffold a NEW box (bare name or -b)
box                                        # list LIVE sessions (attached/detached)
box -a                                     # every box, newest first
box ServMon                                # re-enter an existing box + ATTACH
#   -p htb|hs|cjca  where the note goes
#   -s              tcp autoscan: rustscan full range, nmap -sV -sC on open
#                   ports, whatweb, then enum4linux-ng or wpscan on detection
#   -u              nmap top-100 UDP scan
```

Re-entering refreshes the `.envrc` IP when `-i` is given; a session created
without an IP is killed + recreated (with recon) once the IP and `-s`/`-u`
arrive. Attaching switches tmux clients when already inside tmux.

### n

Appends to the box's note from the shell. No quoting needed:

```sh
n found sqli on /login          # timestamped bullet in the current stage
n -c 'nmap -p- 10.10.10.184'    # capture a command and its output
n -l false positive, needs auth # quote the previous command and its output
n -f loot/exploit.py            # dump a file as a fenced block
n -t privesc                    # switch target section
```

If an image is on the X clipboard when n appends (flameshot Print, or Print then copy), it is saved into the vault and embedded under the new text.

### nhosts and shell helpers

- `nhosts` — parse enum4linux-ng/nmap SMB output into `/etc/hosts`
- `stage` — move a box through recon/findings/foothold/privesc/notes/flags; prompt, pane headers and polybar follow
- `t` — print the current box context (name, ip, stage)
- `proxyon` / `proxyoff` — route guest traffic through the box's Burp
- `kt [cmd]` — open a kitty tab

### Termlog

Every interactive tmux pane is recorded with `script`. Recordings read like a lab notebook: commands are prefixed with `──▶ [user@host ts] cmd` separators, `tlog` tails the newest one, and `n -l` quotes from them.

## Daily operations

```sh
bash 07-zsh-tweaks.sh                 # deploy config/helper changes, the only
                                      # path, keeps guest and repo in sync
# before risky experiments: VM off, then host-side
# sudo qemu-img snapshot -c risky <disk.qcow2>   (list: -l, revert: -a)
kssh 'sudo apt update && sudo apt upgrade -y'
```

## Gotchas

- Stock Kali resolves AAAA first with no v6 route, so apt and pip hang. Fix is IPv4-preferred resolution (`ForceIPv4` plus `gai.conf` precedence). Do not disable IPv6 system-wide, exam VPNs push v6 onto tun0 and OpenVPN exits if it is missing.
- libvirt `snapshot-revert` does not work for disk-only internal snapshots on qemu 11.1. Revert host-side with `qemu-img snapshot -a` on a shutoff domain.
- Never `vol-upload` over the live disk. An aborted upload leaves it half rewritten.
- lightdm: `autologin-session=i3` must be inside the `[Seat:*]` section, not appended at the end of the file.
- The Kali zsh build swallows input sent before the first prompt (the workbench polls a readiness marker before typing into fresh panes), and `${arr[(I)pat]}` returns 0 on a miss instead of empty.

