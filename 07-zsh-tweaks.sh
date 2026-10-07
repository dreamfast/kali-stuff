#!/usr/bin/env bash
# 07-zsh-tweaks.sh: deploy guest skeletons + shell setup into the running
# Kali VM (via kssh). Idempotent: marker-guarded rc blocks, md5-guarded
# config sync (differing live copies backed up to <file>.bak-<date>).
# Re-run any time after editing anything in guest-configs/.
#
# Covers: zsh rc blocks (history/fzf/zoxide/direnv/extract/kwp), WPSCAN key,
# /etc/zsh/zshenv blocks (PATH-HEAL/WPSCAN/CTF-FUNCS), the CTF helpers
# (box n nhosts polybar-target polybar-vpn wrec pane-cmd clean.sh
# ctf-zsh-funcs.zsh), the desktop configs (i3 tmux kitty picom polybar rofi
# + root-owned lightdm/xorg) and the pi agent config (guest-configs/pi/).
#
# Usage:  bash 07-zsh-tweaks.sh    (guest must be RUNNING)
# Undo:   guest: mv ~/.zshrc.bak-zsh-tweaks ~/.zshrc
set -euo pipefail
cd "$(dirname "$0")"

# kssh may be missing from PATH in non-login shells; self-heal before use.
if ! command -v kssh >/dev/null 2>&1 && [ -x "$HOME/.local/bin/kssh" ]; then
  PATH="$HOME/.local/bin:$PATH"
fi
command -v kssh >/dev/null 2>&1 || {
  echo "07: kssh not found; this script deploys to the guest over ssh" >&2
  echo "07: (wraps: ssh -F .ssh/config kali@10.170.0.2). Run it from the" >&2
  echo "07: dev container, or see README for what kssh is." >&2
  exit 1
}

# secrets come from values.sh (gitignored; copy values.sh.example).
# shellcheck source=/dev/null
[ -f ./values.sh ] && . ./values.sh
if [ -z "${WPSCAN_API_KEY:-}" ]; then
  echo "07: WPSCAN_API_KEY not set; put it in values.sh (see values.sh.example)" >&2
  exit 1
fi

# ---------------------------------------------------------------- guest part
# NB: the env-prefix carries the key into the guest bash; the two key
# heredocs below are UNquoted so it expands there.
kssh "WPSCAN_API_KEY='$WPSCAN_API_KEY' bash -s" <<'EOF'
set -euo pipefail
RC=~/.zshrc

[ -f "$RC.bak-zsh-tweaks" ] || cp "$RC" "$RC.bak-zsh-tweaks"

# WPSCAN key in every zsh: rc (interactive) + zshenv (panes/scripts — the
# rc blocks land after its interactive early-exit).
if ! grep -q 'WPSCAN-KEY-START' "$RC"; then
  cat >> "$RC" <<WPSRC

# === WPSCAN-KEY-START (07-zsh-tweaks.sh) ========================
export WPSCAN_API_KEY=$WPSCAN_API_KEY
# === WPSCAN-KEY-END ============================================
WPSRC
fi
sudo bash -c 'grep -q WPSCAN-KEY /etc/zsh/zshenv' || sudo tee -a /etc/zsh/zshenv >/dev/null <<WPSENV

# === WPSCAN-KEY (07-zsh-tweaks.sh) ===
export WPSCAN_API_KEY=$WPSCAN_API_KEY
# === WPSCAN-KEY-END ===
WPSENV

# NEWBOX-PANE-READY: pane shells touch /tmp/nb-pane-ready-<pane>-<pid> as
# their LAST rc step (tmux only); box polls it instead of a blind sleep
# (this zsh build swallows pre-prompt input).
if ! grep -q 'NEWBOX-PANE-READY' "$RC"; then
  cat >> "$RC" <<'READY'

# === NEWBOX-PANE-READY (07-zsh-tweaks.sh) ======================
if [ -n "${TMUX:-}" ]; then
  touch "/tmp/nb-pane-ready-${TMUX_PANE}-$$" 2>/dev/null
  ls -t /tmp/nb-pane-ready-* 2>/dev/null | tail -n +5 | xargs -r rm -f 2>/dev/null
fi
# === NEWBOX-PANE-READY-END =====================================
READY
fi

# pi harness: put ~/.pi/agent/bin on PATH (the installer doesn't).
if ! grep -q 'PI-BIN-PATH' "$RC"; then
  cat >> "$RC" <<'PIPATH'

# === PI-BIN-PATH (07-zsh-tweaks.sh) ===
[ -d "$HOME/.pi/agent/bin" ] && export PATH="$HOME/.pi/agent/bin:$PATH"
# === PI-BIN-PATH-END ===
PIPATH
fi

# pi rice prompt: Kali stock twoline riced with native zsh parts (BOX·STAGE
# link from direnv, vcs_info git segment, RPROMPT exit code + jobs).
# SELF-UPDATING: the sed strips any previous version of the block first,
# so edits here re-deploy cleanly.
sed -i '/PI-RICE-PROMPT (07-zsh-tweaks.sh)/,/PI-RICE-PROMPT-END/d' "$RC"
cat >> "$RC" <<'RICEP'

# === PI-RICE-PROMPT (07-zsh-tweaks.sh) =========================
setopt prompt_subst
autoload -Uz vcs_info
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:*' check-for-changes true
zstyle ':vcs_info:*' unstagedstr ' ✱'
zstyle ':vcs_info:*' stagedstr ' ✚'
zstyle ':vcs_info:git:*' formats '%F{#dcde7b} git:(%F{#cc8a3e}%b%F{#dcde7b})%F{#d33060}%u%c%f'
zstyle ':vcs_info:git:*' actionformats '%F{#dcde7b} git:(%F{#cc8a3e}%b%F{#d33060}|%a%F{#dcde7b})'
_pi_rice_prompt() {
  vcs_info
  local sym=㉿ link=""
  # TRAP: no nested ${BOX:+...} inside PROMPT — a bare } in a ${:+} word
  # (e.g. %F{#hex}) terminates the expansion; build the link HERE instead.
  if [ -n "${BOX:-}" ]; then
    link="─(%F{#cc8a3e}${BOX}"
    [ -n "${STAGE:-}" ] && link="${link}%F{#dcde7b} · ${STAGE}"
    link="${link}%F{%(#.blue.green)})"
  fi
  PROMPT=$'%F{%(#.blue.green)}┌──${debian_chroot:+($debian_chroot)─}${VIRTUAL_ENV:+($(basename $VIRTUAL_ENV))─}(%B%F{%(#.red.blue)}%n'$sym$'%m%b%F{%(#.blue.green)})'$link$'-[%B%F{reset}%(6~.%-1~/…/%4~.%5~)%b%F{%(#.blue.green)}]${vcs_info_msg_0_}\n└─%B%(#.%F{red}#.%F{blue}$)%b%F{reset} '
  RPROMPT=$'%(?..%F{#d33060}⨯ %?%f )%(1j.%F{#dcde7b}⚙ %j%f )'
}
precmd_functions=(${precmd_functions:#_pi_rice_prompt} _pi_rice_prompt)
_pi_rice_prompt
# === PI-RICE-PROMPT-END ========================================
RICEP

# zshenv: PATH self-heal (non-interactive zsh never reads .zshrc) + the
# CTF-FUNCS source hook (helpers available in EVERY zsh instance).
sudo bash -c 'grep -q PATH-HEAL /etc/zsh/zshenv' || sudo tee -a /etc/zsh/zshenv >/dev/null <<'PATHHEAL'

# === PATH-HEAL (07-zsh-tweaks.sh) ===
case ":$PATH:" in
  *":/usr/bin:"*) ;;
  *) PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" ;;
esac
# === PATH-HEAL-END ===
PATHHEAL

sudo bash -c 'grep -q CTF-FUNCS /etc/zsh/zshenv' || sudo tee -a /etc/zsh/zshenv >/dev/null <<'CTFENV'

# === CTF-FUNCS (07-zsh-tweaks.sh) ===
[ -f "$HOME/.local/share/ctf-zsh-funcs.zsh" ] && source "$HOME/.local/share/ctf-zsh-funcs.zsh"
# === CTF-FUNCS-END ===
CTFENV

if grep -q 'ZSH-TWEAKS-START' "$RC"; then
  echo "rc part already applied; skipped (WPSCAN/PATH-HEAL/CTF-FUNCS ensured)"
  exit 0
fi

# Infinite history + live sharing across all terminals/panes
sed -i \
  -e 's/^HISTSIZE=.*/HISTSIZE=100000/' \
  -e 's/^SAVEHIST=.*/SAVEHIST=100000/' \
  -e 's/^#setopt share_history.*/setopt share_history/' \
  "$RC"
sed -i '/^setopt share_history/a setopt hist_save_no_dups' "$RC"
sed -i '/^setopt hist_save_no_dups/a setopt extendedglob' "$RC"
sed -i '/^setopt extendedglob/a HIST_STAMPS=long' "$RC"
# extendedglob makes unquoted `bindkey ^P` parse as a glob → quote it
sed -i 's/^bindkey \^P toggle_oneline_prompt$/bindkey "^P" toggle_oneline_prompt/' "$RC"

# packages the rc blocks below depend on (best effort)
command -v fzf >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y fzf; }
command -v direnv >/dev/null 2>&1 || { sudo apt-get update -qq && sudo apt-get install -y direnv; }
command -v zoxide >/dev/null 2>&1 || sudo apt-get install -y zoxide || echo "(zoxide unavailable)"
command -v enum4linux-ng >/dev/null 2>&1 || sudo apt-get install -y enum4linux-ng || echo "(enum4linux-ng unavailable)"
if [ ! -e /usr/share/zsh-history-substring-search/zsh-history-substring-search.zsh ] \
   && [ ! -e /usr/local/share/zsh-history-substring-search/zsh-history-substring-search.zsh ]; then
  sudo apt-get install -y zsh-history-substring-search 2>/dev/null \
    || { command -v git >/dev/null && sudo git clone -q --depth 1 https://github.com/zsh-users/zsh-history-substring-search.git /usr/local/share/zsh-history-substring-search; } \
    || true
fi

cat >> "$RC" <<'BLOCK'

# === ZSH-TWEAKS-START (07-zsh-tweaks.sh) ======================
eval "$(zoxide init zsh)"

fzf-history-widget() {
  local out key sel
  local -a opts=(--ansi --info=inline --reverse --preview 'echo {}' --preview-window right:50%:wrap --expect ctrl-o)
  if [[ -n "${TMUX:-}" ]] && fzf --help 2>/dev/null | grep -q -- --tmux; then
    opts+=(--tmux center,90%,80%)   # tmux: centered floating popup
  else
    opts+=(--height=70% --border=rounded)  # plain terminal: bottom 70%, shell stays visible
  fi
  out=$(fc -rln 1 | fzf $opts) || return 0
  key=$(head -n1 <<<"$out")
  sel=$(tail -n +2 <<<"$out")
  [ -n "$sel" ] || return 0
  LBUFFER=$sel
  # Enter = run immediately; ctrl-o = fill the line editable instead
  [ "$key" = ctrl-o ] || zle accept-line
}
zle -N fzf-history-widget
bindkey '^R' fzf-history-widget

# ghost suggestions visible (fg=250); autosuggestions/highlighting are stock
[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] \
  && ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=250'

eval "$(direnv hook zsh)"

extract() {
  local a
  for a in "$@"; do
    [ -e "$a" ] || { echo "extract: no such file: $a"; continue; }
    case "$a" in
      *.tar.bz2|*.tbz)  tar xjf "$a" ;;
      *.tar.gz|*.tgz)   tar xzf "$a" ;;
      *.tar.xz|*.txz)   tar xJf "$a" ;;
      *.tar.zst)        tar --zstd -xf "$a" ;;
      *.tar)            tar xf  "$a" ;;
      *.bz2)  bunzip2 "$a" ;;
      *.gz)   gunzip  "$a" ;;
      *.xz)   unxz    "$a" ;;
      *.zip)  unzip   "$a" ;;
      *.7z)   7z x    "$a" ;;
      *.rar)  unrar x "$a" ;;
      *) echo "extract: don't know how to handle '$a'" ;;
    esac
  done
}
# === ZSH-TWEAKS-END ===========================================
BLOCK

for d in /usr/share /usr/local/share; do
  if [ -e "$d/zsh-history-substring-search/zsh-history-substring-search.zsh" ]; then
    printf '\nsource %s/zsh-history-substring-search/zsh-history-substring-search.zsh\nHIST_SUBSTRING_SEARCH_HIGHLIGHT_FOUND="fg=255,underline"\n' "$d" >> "$RC"
    break
  fi
done

echo "zsh tweaks applied. Live in a NEW shell (or: source ~/.zshrc)"
EOF

# ------------------------------------------------------------- helper pushes
for b in box n nhosts polybar-target polybar-vpn wrec pane-cmd; do
  kssh "cat > ~/.local/bin/$b && chmod 755 ~/.local/bin/$b" < "guest-configs/$b"
done
# fresh-start hygiene script lives in HOME per user preference, not on PATH
kssh "cat > ~/clean.sh && chmod 755 ~/clean.sh" < guest-configs/clean.sh
# retire the pre-rename `newbox` binary name (fresh-snapshot policy)
kssh 'rm -f ~/.local/bin/newbox' >/dev/null 2>&1 || true
kssh "mkdir -p ~/.local/share && cat > ~/.local/share/ctf-zsh-funcs.zsh" < guest-configs/ctf-zsh-funcs.zsh

# kwp(): wallpaper swap helper (no-arg = random from ~/work/wallpaper)
if ! kssh "grep -q '^kwp()' ~/.zshrc" >/dev/null 2>&1; then
  kssh "cat >> ~/.zshrc" <<'EOF'

kwp() {  # kwp <img> | kwp (random); if/else so a feh failure doesn't fall through to wp-rotate
  if [ -n "${1:-}" ]; then feh --bg-fill "$1"; else wp-rotate; fi
}
EOF
  echo "07: kwp() added to .zshrc"
fi

# ------------------------------------------------------------- config sync
# sync_cfg <guest-dest> <local-source> [tag] [sudo]: md5-guarded, live copy
# backed up to <dst>.bak-<date> first; tag i3/tmux/polybar re-fires the
# matching reload after the sync; sudo=1 writes root-owned targets (they
# apply at next lightdm restart, no service restarts).
# NB: remote paths must stay UNQUOTED on the guest side so zsh tilde-expands
# them (a quoted '~' is literal → files would land in /home/kali/~/)
render() {  # render <file> > stdout: %%TOKEN%% -> real values (values.sh)
  sed -e "s|%%INFERENCE_IP%%|${INFERENCE_IP:-}|g" "$1"
}

sync_cfg() {
  local dst=$1 src=$2 tag=${3:-} use_sudo=${4:-} h g d
  [ -f "$src" ] || { echo "07: (missing $src; skipped)"; return 0; }
  h=$(render "$src" | md5sum | cut -d' ' -f1)
  g=$(kssh "md5sum $dst 2>/dev/null | cut -d' ' -f1" || true)
  [ "$h" = "$g" ] && return 0
  d=$(date +%Y%m%d)
  if [ "$use_sudo" = 1 ]; then
    render "$src" | kssh "sudo cp $dst $dst.bak-$d 2>/dev/null; sudo mkdir -p \"\$(dirname $dst)\"; sudo tee $dst >/dev/null"
  else
    kssh "[ -f $dst ] && cp $dst $dst.bak-$d || true"
    render "$src" | kssh "mkdir -p \"\$(dirname $dst)\" && cat > $dst"
  fi
  echo "07: synced $src -> $dst (backup: $dst.bak-$d)"
  case $tag in
    i3)      SYNCED_i3=1 ;;
    tmux)    SYNCED_tmux=1 ;;
    polybar) SYNCED_polybar=1 ;;
  esac
}
SYNCED_i3=0; SYNCED_tmux=0; SYNCED_polybar=0
# Guest-side destinations: '~' must stay single-quoted so the GUEST shell
# expands it (kssh), not this one; hence the per-line SC2088 disables.
# shellcheck disable=SC2088
sync_cfg '~/.config/i3/config'                    guest-configs/i3.config            i3
# shellcheck disable=SC2088
sync_cfg '~/.config/tmux/tmux.conf'               guest-configs/tmux.conf            tmux
# shellcheck disable=SC2088
sync_cfg '~/.config/kitty/kitty.conf'             guest-configs/kitty.conf
# shellcheck disable=SC2088
sync_cfg '~/.config/kitty/dexpota-theme.conf'     guest-configs/dexpota-theme.conf
# shellcheck disable=SC2088
sync_cfg '~/.config/picom/picom.conf'             guest-configs/picom.conf
# shellcheck disable=SC2088
sync_cfg '~/.config/dunst/dunstrc'                guest-configs/dunstrc
# shellcheck disable=SC2088
sync_cfg '~/.config/rofi/config.rasi'             guest-configs/rofi-config.rasi
# shellcheck disable=SC2088
sync_cfg '~/.config/rofi/dexpota-frost.rasi'      guest-configs/rofi-theme.rasi
# shellcheck disable=SC2088
sync_cfg '~/.config/polybar/config.ini'           guest-configs/polybar.conf         polybar
# shellcheck disable=SC2088
sync_cfg '~/.config/polybar/launch.sh'            guest-configs/polybar-launch.sh
# shellcheck disable=SC2088
sync_cfg '~/.config/flameshot/flameshot.ini'      guest-configs/flameshot.ini
# shellcheck disable=SC2088
sync_cfg '~/.config/gtk-3.0/settings.ini'           guest-configs/gtk-settings.ini
# shellcheck disable=SC2088
sync_cfg '~/.config/gtk-4.0/settings.ini'           guest-configs/gtk-settings.ini
# shellcheck disable=SC2088
sync_cfg '~/.local/bin/wp-rotate'                 guest-configs/wp-rotate
# shellcheck disable=SC2088
sync_cfg '~/.pi/agent/settings.json'              guest-configs/pi/settings.json
# shellcheck disable=SC2088
sync_cfg '~/.pi/agent/models.json'                guest-configs/pi/models.json
# shellcheck disable=SC2088
sync_cfg '~/.pi/agent/mcp.json'                   guest-configs/pi/mcp.json
# shellcheck disable=SC2088
sync_cfg '~/.pi/agent/AGENTS.md'                  guest-configs/pi/AGENTS.md
for _ag in guest-configs/pi/agents/*.md; do
  [ -e "$_ag" ] || continue
  # shellcheck disable=SC2088
  sync_cfg "~/.pi/agent/agents/${_ag##*/}" "$_ag"
done
sync_cfg '/etc/X11/xorg.conf.d/10-virtio.conf'    guest-configs/10-virtio.conf       '' 1
sync_cfg '/etc/lightdm/lightdm.conf'              guest-configs/lightdm.conf         '' 1
kssh 'chmod 755 ~/.local/bin/wp-rotate'
# i3.config execs launch.sh DIRECTLY (no `sh`); a first-create sync leaves it non-executable
kssh 'chmod 755 ~/.config/polybar/launch.sh'

# re-fire only what actually changed
if [ "$SYNCED_i3" = 1 ]; then
  # $() must expand on the GUEST; keep single-quoted
  # shellcheck disable=SC2016
  kssh 'i3-msg -s /run/user/$(id -u)/i3/ipc-socket.$(pgrep -x i3 | head -1) reload' 2>/dev/null \
    && echo "07: i3 reloaded" || echo "07: (i3 not running; applies at next start)"
fi
if [ "$SYNCED_tmux" = 1 ]; then
  kssh 'tmux source-file ~/.config/tmux/tmux.conf 2>/dev/null' && echo "07: tmux config re-sourced"
fi
if [ "$SYNCED_polybar" = 1 ]; then
  # background job + no stdio = survives the ssh exit (setsid HANGS here)
  kssh 'DISPLAY=:0 sh ~/.config/polybar/launch.sh </dev/null >/dev/null 2>&1 & sleep 1; pgrep -x polybar >/dev/null && echo polybar-up || echo polybar-down' \
    | grep -q polybar-up && echo "07: polybar restarted"
fi
