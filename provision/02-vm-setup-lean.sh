#!/usr/bin/env bash
# 02-vm-setup.sh: make the Kali VM CTF/OSCP-ready. Run INSIDE the VM:
#   kssh 'sudo bash /tmp/02-vm-setup.sh'   (after: kscp 02-vm-setup.sh kali:/tmp/)
# Idempotent: safe to re-run. Installs whatever is missing, skips the rest.

set -uo pipefail
# under sudo, secure_path drops /usr/local/bin; restore it so need_cmd works
export PATH="/usr/local/bin:$PATH"
log() { echo; echo "==> $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }
have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- apt
APT_PKGS=(rlwrap htop p7zip-full sshuttle mate-polkit dunst jq)
APT_WANT=()
for p in "${APT_PKGS[@]}"; do have_pkg "$p" || APT_WANT+=("$p"); done
if [ "${#APT_WANT[@]}" -gt 0 ]; then
  log "apt: ${APT_WANT[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y "${APT_WANT[@]}"
else
  log "apt: (all present)"
fi

# ------------------------------------------------- bloodhound + neo4j
log "bloodhound + neo4j (AD mapping)"
if ! need_cmd bloodhound; then
  sudo apt-get install -y bloodhound
fi
# Kali's neo4j package ships no systemd unit; add one so it starts at boot
if [ ! -f /etc/systemd/system/neo4j.service ]; then
  sudo tee /etc/systemd/system/neo4j.service >/dev/null <<'EOF'
[Unit]
Description=Neo4j Graph Database
After=network.target

[Service]
Type=forking
ExecStart=/usr/bin/neo4j start
ExecStop=/usr/bin/neo4j stop
ExecReload=/usr/bin/neo4j restart
RemainAfterExit=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
fi
sudo systemctl daemon-reload
sudo systemctl enable neo4j 2>/dev/null || true
sudo systemctl restart neo4j 2>/dev/null || sudo neo4j start 2>/dev/null || \
  echo "    (neo4j not started; run: sudo neo4j start)"

# ------------------------------------------------------------ pip CLIs
# py3.14: cx-Oracle (certipy dep) fails under pip build isolation → --no-build-isolation fallback
log "pip: certipy ldapdomaindump patator"
python3 -m pip install -q --break-system-packages certipy ldapdomaindump patator 2>/dev/null \
  || python3 -m pip install -q --break-system-packages --no-build-isolation certipy ldapdomaindump patator \
  || sudo pip3 install -q --break-system-packages --no-build-isolation certipy ldapdomaindump patator

# ------------------------------------------------- GitHub release bins
BIN_DIR=/opt/bins
sudo mkdir -p "$BIN_DIR"

# repo -> asset url matching pattern (follows redirects, e.g. moved repos)
gh_asset() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
    | grep -oE '"browser_download_url": *"[^"]*"' \
    | grep -iE "$2" | head -1 | sed 's/.*": *"//; s/"$//'
}

# kerbrute (stable v1.0.3, no newer release)
if ! need_cmd kerbrute; then
  log "kerbrute"
  sudo curl -fsSL -o /usr/local/bin/kerbrute \
    https://github.com/ropnop/kerbrute/releases/download/v1.0.3/kerbrute_linux_amd64
  sudo chmod +x /usr/local/bin/kerbrute
fi

# chisel (client + windows exe for tunneling), v1.12.0
if ! need_cmd chisel; then
  log "chisel"
  url="$(gh_asset jpillora/chisel 'linux_amd64\.gz' || true)"
  [ -n "$url" ] || url="https://github.com/jpillora/chisel/releases/download/v1.12.0/chisel_1.12.0_linux_amd64.gz"
  sudo curl -fsSL "$url" | sudo gunzip | sudo tee "$BIN_DIR/chisel" > /dev/null
  sudo chmod +x "$BIN_DIR/chisel"
  uwl="$(gh_asset jpillora/chisel 'windows_amd64' || true)"
  [ -n "$uwl" ] || uwl="https://github.com/jpillora/chisel/releases/download/v1.12.0/chisel_1.12.0_windows_amd64.zip"
  sudo curl -fsSL -o /tmp/chisel.exe.zip "$uwl" && sudo unzip -o -q /tmp/chisel.exe.zip -d "$BIN_DIR"
fi
need_cmd chisel || sudo ln -sf "$BIN_DIR/chisel" /usr/local/bin/chisel

# rustscan: repo moved to bee-san/RustScan; asset is a zip wrapping a tar.gz
if ! need_cmd rustscan; then
  log "rustscan"
  url="$(gh_asset bee-san/RustScan 'x86_64-linux' || true)"
  [ -n "$url" ] || url="https://github.com/bee-san/RustScan/releases/download/2.4.1/x86_64-linux-rustscan.tar.gz.zip"
  curl -fsSL -o /tmp/rs.zip "$url"
  mkdir -p /tmp/rs && unzip -o -q /tmp/rs.zip -d /tmp/rs
  tgz=$(find /tmp/rs -name '*.tar.gz' | head -1)
  [ -n "$tgz" ] || tgz=$(find /tmp/rs -type f | head -1)
  tar xzf "$tgz" -C /tmp/rs 2>/dev/null || true
  f=$(find /tmp/rs -maxdepth 2 -name rustscan -type f | head -1)
  [ -n "$f" ] || f="$tgz"
  sudo cp "$f" "$BIN_DIR/rustscan"
  sudo chmod +x "$BIN_DIR/rustscan"
  sudo ln -sf "$BIN_DIR/rustscan" /usr/local/bin/rustscan
fi

# subfinder (projectdiscovery; nuclei/httpx already via apt)
if ! need_cmd subfinder; then
  log "subfinder"
  url="$(gh_asset projectdiscovery/subfinder 'linux_amd64' || true)"
  [ -n "$url" ] || url="https://github.com/projectdiscovery/subfinder/releases/download/v2.16.0/subfinder_2.16.0_linux_amd64.zip"
  curl -fsSL -o /tmp/subfinder.zip "$url"
  sudo unzip -o -q /tmp/subfinder.zip -d "$BIN_DIR"
  f=$(find "$BIN_DIR" -maxdepth 2 -name subfinder -type f | head -1)
  sudo chmod +x "$f" && sudo ln -sf "$f" /usr/local/bin/subfinder
fi

# gohttpserver (tiny static file server): repo moved to codeskyblue
if ! need_cmd gohttpserver; then
  log "gohttpserver"
  url="$(gh_asset codeskyblue/gohttpserver 'linux_amd64\.tar\.gz$' || true)"
  [ -n "$url" ] || url="https://github.com/codeskyblue/gohttpserver/releases/download/1.3.0/gohttpserver_1.3.0_linux_amd64.tar.gz"
  curl -fsSL "$url" | sudo tar xz -C "$BIN_DIR"
  f=$(find "$BIN_DIR" -maxdepth 2 -name gohttpserver -type f | head -1)
  sudo chmod +x "$f" && sudo ln -sf "$f" /usr/local/bin/gohttpserver
fi

# ------------------------------------------------ windows binaries
WIN=/opt/windows-binaries
log "windows binaries: rubeus mimikatz potatoes -> $WIN"
sudo mkdir -p "$WIN"
sudo wget -q -O "$WIN/Rubeus.exe" \
  https://github.com/r3motecontrol/Ghostpack-CompiledBinaries/raw/master/Rubeus.exe || true
# mimikatz latest tag is 2.2.0-20220919, asset mimikatz_trunk.zip
if [ ! -f "$WIN/mimikatz.x86_64/" ]; then
  url="$(gh_asset gentilkiwi/mimikatz 'mimikatz_trunk\.zip' || true)"
  [ -n "$url" ] || url="https://github.com/gentilkiwi/mimikatz/releases/download/2.2.0-20220919/mimikatz_trunk.zip"
  curl -fsSL -o /tmp/mimi.zip "$url" && sudo unzip -o -q /tmp/mimi.zip -d "$WIN"
fi
sudo wget -q -O "$WIN/JuicyPotato.exe" \
  https://github.com/ohpe/juicy-potato/releases/download/v0.1/JuicyPotato.exe || true
if [ ! -f "$WIN/RoguePotato.exe" ]; then
  sudo wget -q -O /tmp/rp.zip \
    https://github.com/antonioCoco/RoguePotato/releases/download/1.0/RoguePotato.zip || true
  [ -f /tmp/rp.zip ] && sudo unzip -o -q /tmp/rp.zip -d "$WIN"
fi
sudo wget -q -O "$WIN/PrintSpoofer64.exe" \
  https://github.com/itm4n/PrintSpoofer/releases/download/v1.0/PrintSpoofer64.exe || true

# -------------------------------------------------------- git sources
log "git: PayloadsAllTheThings"
if [ ! -d /opt/payloadsallthethings ]; then
  sudo git clone -q https://github.com/swisskyrepo/PayloadsAllTheThings /opt/payloadsallthethings \
    || echo "    (clone failed; check VM internet)"
fi

# ------------------------------------- toolkit expansion (2026 names)
# Kali 2026 RENAMED the tool metapackages (old kali-tools-*-attack/-sysadmin names are gone)
log "kali-tools metapackages (2026 names) + pwn/forensics/reverse targets"
# LEAN variant: 3 metapackages + core CTF tooling (no forensics/reverse/ghidra/wine)
META_PKGS=(kali-tools-web kali-tools-passwords kali-tools-information-gathering)
# python3-keystone is NOT apt-installable (eventlet chain Breaks python3-trio) → pip keystone-engine
TGT_PKGS=(gdb strace ltrace patchelf python3-pwntools python3-pycryptodome
  hcxtools dcfldd foremost steghide cabextract golang aria2 lftp ligolo-ng
  penelope python3-pyftpdlib)
WANT=()
for p in "${META_PKGS[@]}" "${TGT_PKGS[@]}"; do have_pkg "$p" || WANT+=("$p"); done
if [ "${#WANT[@]}" -gt 0 ]; then
  log "apt: ${WANT[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y "${WANT[@]}"
else
  log "apt: (all present)"
fi

log "pip: jarm keystone-engine pycryptodome"
python3 -m pip install -q --break-system-packages jarm keystone-engine pycryptodome 2>/dev/null \
  || python3 -m pip install -q --break-system-packages --no-build-isolation jarm keystone-engine pycryptodome \
  || sudo pip3 install -q --break-system-packages --no-build-isolation jarm keystone-engine pycryptodome
# jarm ships module-only via pip -> CLI shim
if ! need_cmd jarm; then
  sudo printf '#!/bin/sh\nexec python3 -m jarm "$@"\n' | sudo tee /usr/local/bin/jarm >/dev/null
  sudo chmod +x /usr/local/bin/jarm
fi

# (lean: volatility3 + gef/ghidra conveniences skipped)

# GitHub bins not in the repo: cloudflared, rclone, httpx (shadows apt), uncover
# (waybackurls + gau: deleted upstream, no fork; historical-URL recon gap)
log "github bins: cloudflared rclone httpx uncover"
gh_bin() { # name repo asset-regex [fallback-url]
  local name="$1" repo="$2" pat="$3" fb="${4:-}" url f i
  [ -e "/usr/local/bin/$name" ] && return 0
  url="$(gh_asset "$repo" "$pat" || true)"; [ -n "$url" ] || url="$fb"
  [ -n "$url" ] || { echo "    ($name: no asset url)"; return 0; }
  for i in 1 2 3 4 5; do curl -fsSL -o "/tmp/$name.dl" "$url" && break; echo "    retry $name ($i)"; sleep 8; done
  case "$name" in
    cloudflared)
      sudo install -m755 "/tmp/$name.dl" "$BIN_DIR/$name" && sudo ln -sf "$BIN_DIR/$name" "/usr/local/bin/$name" && echo "    ok $name" ;;
    *)
      unzip -o -q "/tmp/$name.dl" -d "/tmp/$name-x"
      f=$(find "/tmp/$name-x" -maxdepth 2 -name "$name" -type f | head -1)
      if [ -n "$f" ]; then sudo install -m755 "$f" "$BIN_DIR/$name" && sudo ln -sf "$BIN_DIR/$name" "/usr/local/bin/$name" && echo "    ok $name"; else echo "    ($name: binary not in zip)"; fi ;;
  esac
}
gh_bin cloudflared cloudflare/cloudflared 'cloudflared-linux-amd64$' \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
gh_bin rclone rclone/rclone 'rclone-current-linux-amd64\.zip' \
  "https://downloads.rclone.org/rclone-current-linux-amd64.zip"
gh_bin httpx projectdiscovery/httpx 'httpx_.*linux_amd64\.zip' \
  "https://github.com/projectdiscovery/httpx/releases/latest/download/httpx_1.12.0_linux_amd64.zip"
gh_bin uncover projectdiscovery/uncover 'uncover_.*linux_amd64\.zip'

# ---------------------------------------------------------------- done
log "verification"
for t in bloodhound neo4j kerbrute chisel rustscan subfinder gohttpserver \
         certipy ldapdomaindump patator sshuttle \
         gdb strace patchelf jarm uncover cloudflared rclone golang penelope python3-pyftpdlib; do
  if need_cmd "$t" || have_pkg "$t"; then echo "  OK  $t"; else echo "  --  $t"; fi
done
echo
echo "window tools: $(find "$WIN" -maxdepth 1 -printf '%f ' 2>/dev/null)"
echo "neo4j: $(sudo neo4j status 2>&1 | head -1)"
echo "done."
