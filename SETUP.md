# SETUP.md: rebuild the Kali attack VM from scratch

Ordered runbook. Every step is idempotent, re-running is safe.

## 0. Wrappers (once per machine)

```sh
ln -sfn "$PWD"/bin/{kssh,kvirsh,khost} ~/.local/bin/   # from the repo root
```

## The machine

| | |
|---|---|
| OS | Kali Rolling 2026.2 (kernel 6.19.14, x86_64), user `kali`, passwordless sudo |
| Hypervisor | QEMU/KVM (libvirt), domain `host/kali-domain.xml` |
| Disk | `kali-linux-2026.2-qemu-amd64.qcow2` |
| Network | flat bridge `br-kali` 10.170.0.0/24 (no NAT/filtering), VM at **10.170.0.2** |
| Resources | 12 vCPU, 20 GB RAM |
| Access | `kssh` → `kali@10.170.0.2` (project `.ssh/`, key `kalivm`) |

Flat network on purpose: OSCP-style labs want the attack box on the same L2/L3 segment as the targets.

## 1. Host side (physical machine)

```sh
host/01-setup-host.sh     # br-kali bridge + NAT/Mullvad masquerade + firewall
                          # (installs host/02-kali-vm-host.service to re-run at boot)
# (kvirsh needs libvirt-clients and access to the libvirt system socket)
virsh -c qemu:///system net-define host/kali-net.xml
virsh -c qemu:///system net-start br-kali
bin/render host/kali-domain.xml | virsh -c qemu:///system define /dev/stdin
```

`host/nftables.conf` is the host's exact `/etc/nftables.conf` copy (contains the bridge accepts); 01 only inserts fallback rules if those are missing.

## 2. Install the guest

Boot the Kali installer ISO against the qcow2, plain install (user `kali`). Inside the fresh VM:

```sh
sudo apt update && sudo apt full-upgrade -y
sudo systemctl enable --now ssh
# passwordless sudo for automation:
echo 'kali ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/kali
# seed the key (cat .ssh/kalivm.pub from the repo) into ~/.ssh/authorized_keys
```

Keyscan if the IP changed: `ssh-keyscan -H 10.170.0.2 >> .ssh/known_hosts`.

## 3. Guest toolkit

```sh
scp -F .ssh/config -i .ssh/kalivm provision/02-vm-setup.sh kali@10.170.0.2:/tmp/
kssh 'sudo bash /tmp/02-vm-setup.sh'
```

Installs everything missing, skips the rest: bloodhound + neo4j (incl. the systemd unit Kali's package lacks), pip tools (certipy, ldapdomaindump, patator), GitHub release binaries → `/opt/bins` (kerbrute, chisel + .exe, rustscan, subfinder, gohttpserver), Windows payloads → `/opt/windows-binaries`, PayloadsAllTheThings, the 2026.3.9 `kali-tools-*` metapackages, the pwn/reverse/forensics suite (ghidra, volatility3, wine, gef, pwntools...).

## 4. Desktop + helpers (guest RUNNING)

```sh
bash 07-zsh-tweaks.sh     # deploys ALL of guest-configs/ + rc/zshenv blocks
```

zsh environment, CTF workbench (newbox/n/nhosts/helpers), i3, picom, polybar, tmux, kitty, rofi, wallpaper rotation, termlog layer, pi agent config (guest-configs/pi/; install pi itself with its own installer first).

## 5. Snapshot

Internal qcow2 snapshots, host-side (the VM must be SHUTOFF; libvirt's
snapshot-revert is broken for these on qemu 11.1):

```sh
virsh -c qemu:///system shutdown kali-vm
sudo qemu-img snapshot -c base-provisioned kali-linux-2026.2-qemu-amd64.qcow2
virsh -c qemu:///system start kali-vm
```

## Where things land in the guest

```
/usr/local/bin/            kerbrute, chisel, certipy, ldapdomaindump, patator, ...
/opt/bins/                 chisel(.exe), rustscan, subfinder, gohttpserver, cloudflared, ...
/opt/windows-binaries/     Rubeus, mimikatz, Juicy/RoguePotato, PrintSpoofer
/opt/payloadsallthethings/
/opt/volatility3/  /opt/bins (ghidra under /opt)
/usr/share/seclists/  /usr/share/wordlists/   (rockyou.gz, ...)
~/.local/bin/              newbox, n, nhosts, wp-rotate, polybar-target, burpbox, browserbox, wrec
~/.local/share/ctf-zsh-funcs.zsh
~/work/ctf/<box>/          per-box dirs (.envrc + recon/ + termlogs/)
```

Services: ssh :22 · dnsmasq (DHCP/DNS for labs) · tftpd-hpa :69/udp · neo4j :7474 · bloodhound :7687.

## Keeping it current

```sh
kssh 'sudo apt update && sudo apt upgrade -y'
kssh 'sudo nuclei -ut'
# after editing anything in guest-configs/:
bash 07-zsh-tweaks.sh
```

## Gotchas that affect the scripts

- `sudo bash` inside the VM drops `/usr/local/bin` (secure_path); 02-vm-setup.sh re-exports PATH at the top; for ad-hoc checks use plain `kssh` or prefix `PATH=/usr/local/bin:$PATH`.
- GitHub API rate limits on the shared exit IP (60 req/h); release lookups fall back to pinned URLs; just re-run the script if a download fails.
- `mstsh-x86` isn't in Kali repos (→ rdesktop); `crackmapexec` is unmaintained (→ netexec, stock); two tool repos moved (rustscan → `bee-san/RustScan`, gohttpserver → `codeskyblue/`); pinned URLs account for it.
- certipy's `cx-Oracle` dep won't build isolated on Python 3.14 → the script falls back to `--no-build-isolation` after setuptools+wheel.
