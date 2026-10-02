# ctf-zsh-funcs.zsh: CTF shell helpers, installed by 07-zsh-tweaks.sh to
# ~/.local/share/ctf-zsh-funcs.zsh and sourced from /etc/zsh/zshenv, so
# every zsh instance has them (tmux panes, kssh `zsh -c`, scripts).
#
#   box [name]   no arg: list boxes (name/ip/platform/session state)
#                name: cd into the box + attach to its tmux session
#   drop <f...>  copy file(s) to the host (lands in the host's shared/drops)
#   rl [port]    reverse-shell listener (/bin/sh) on the port (default 4444)
#   t            print the current box context (BOX/IP/PLATFORM/PWD)
#   proxyon      route HTTP(S) through the box's Burp (127.0.0.1:$BURP_PORT)
#   proxyoff     go direct (unset proxies); use for ssh/smb to the same IP
#   kt [cmd]     new tab in the focused kitty window (kitty @ remote control)
#   burpbox      per-box Burp (own data dir/proxy port/project; see script)
#   browserbox   per-box Chromium (own profile dir + proxy to box Burp)

# -- per-pane target context (feeds tmux pane borders + the polybar target
# -- module). Runs on every prompt (precmd) and command start (preexec), so
# -- "what am I looking at" stays current even when focus jumps panes.
# NOTE: this stripped tmux build has NO select-pane -p/-P (per-pane border
# string); the context goes into the pane TITLE instead, which tmux.conf's
# pane-border-format renders on the pane's top border line.
# INTERACTIVE-only on purpose: non-interactive zsh (any script run inside a
# pane; `zsh recon/autoscan.sh`) inherits $TMUX, sources this file from
# /etc/zsh/zshenv, and this build fires preexec per script line with an EMPTY
# cmdline → phantom "── [user@host ts] " separators in the termlog that poison
# `n -l`'s trail parsing. Pane shells (script -c zsh) ARE interactive.
if [ -n "${TMUX:-}" ] && [[ -o interactive ]]; then
  # ALWAYS register in a pane shell. The old guard (export _NB_TGT_DONE)
  # leaked into child environments: a tmux server/session created from a
  # pane shell (box!) inherited the marker and every pane in it skipped
  # registration; borders lost their "box · ip". An inherited value is
  # meaningless here, so drop it.
  unset _NB_TGT_DONE
  _nb_tgt_sync() {
    local t=""
    if [ -n "${BOX:-}" ]; then
      t="${BOX}${IP:+ · ${IP}}"
      # stage from the box's .envrc; the FILE is the source of truth, so a
      # `stage` switch repaints every pane's border at its next prompt
      # (independent of direnv allow state / stale $STAGE env)
      local st
      st=$(sed -n 's/^export STAGE=//p' "${CTFS_ROOT:-$HOME/work/ctf}/$BOX/.envrc" 2>/dev/null | head -1)
      [ -n "$st" ] && t="$t · $st"
    fi
    printf '%s' "$t" > /tmp/nb-current-target 2>/dev/null
    if [ -n "${TMUX:-}" ]; then
      # Kill the rc's OSC title escape (TERM_TITLE, \e]0;user@host:dir);
      # tmux would otherwise overwrite our pane title with it at every
      # prompt. Re-apply OUR title last, so it wins regardless of the rc's
      # named precmd() vs. this hook's execution order.
      TERM_TITLE=""
      if [ "$t" != "${_NB_TGT_LAST:-}" ]; then
        # $TMUX_PANE targets THIS pane explicitly; `-t =` ("current pane of
        # the current client") fails in detached sessions, where box's
        # auto-panes live most of their life.
        tmux select-pane -t "${TMUX_PANE:-=}" -T "$t" 2>/dev/null
        _NB_TGT_LAST=$t
      fi
    fi
  }
  # Hook registration: membership-guarded so a same-shell double source of
  # this file doesn't duplicate hooks. NOTE: this zsh 5.9.2 build returns
  # "0" (not empty) for ${arr[(I)pat]} misses; [ -z ]/(I) guards silently
  # never fire once the array exists; the case/string-membership form is
  # build-proof (same idiom as the box() session check below).
  case " ${precmd_functions} " in *" _nb_tgt_sync "*) ;; *) precmd_functions+=(_nb_tgt_sync) ;; esac
  case " ${preexec_functions} " in *" _nb_tgt_sync "*) ;; *) preexec_functions+=(_nb_tgt_sync) ;; esac
  _nb_tgt_sync

  # termlog command separator: print "──▶ [user@host date] cmd" as each
  # command starts, so pane recordings (~/work/termlogs/<session>/) carry a
  # timestamped command trail. The ▶ sentinel makes the line unmatchable by
  # tool output; `n -l` splits its trail on exactly this shape (legacy
  # "── [" recordings are still recognized too).
  _nb_cmd_sep() {
    printf '──▶ [%s@%s %s] %s\n' "${USER:-$(id -un)}" "${HOST%%.*}" "$(date '+%F %T')" "$1"
  }
  case " ${preexec_functions} " in *" _nb_cmd_sep "*) ;; *) preexec_functions+=(_nb_cmd_sep) ;; esac
fi


stage() {
  # stage [recon|findings|foothold|privesc|notes|flags]; rewrites STAGE=
  # in the box's .envrc (the single source of truth: every pane's direnv
  # reloads it at its next prompt; `n` reads the file directly) and
  # direnv-allows the change so no pane gets blocked.
  local ok=" recon findings foothold privesc notes flags "
  if [ $# -ne 1 ]; then
    echo "stage: ${STAGE:-<none>}   usage: stage <recon|findings|foothold|privesc|notes|flags>"
    return 0
  fi
  case "$ok" in
    *" $1 "*) ;;
    *) echo "stage: unknown stage '$1' (recon|findings|foothold|privesc|notes|flags)"; return 1 ;;
  esac
  local d=$PWD
  while [ "$d" != "/" ]; do
    [ -f "$d/.envrc" ] && grep -q '^export BOX=' "$d/.envrc" && break
    d=$(dirname "$d")
  done
  [ "$d" = "/" ] && { echo "stage: not inside a box (no .envrc with BOX= at/above $PWD)"; return 1; }
  if grep -q '^export STAGE=' "$d/.envrc"; then
    sed -i "s/^export STAGE=.*/export STAGE=$1/" "$d/.envrc"
  else
    echo "export STAGE=$1" >> "$d/.envrc"
  fi
  command direnv allow "$d" >/dev/null 2>&1
  export STAGE=$1
  local pretty=$1
  case $1 in
    recon) pretty=Recon ;;     findings) pretty=Findings ;;
    foothold) pretty=Foothold ;; privesc) pretty=Privesc ;;
    notes) pretty=Notes ;;      flags) pretty=Flags ;;
  esac
  echo "stage → $1 (n now appends to ## $pretty; all panes of this box pick it up at their next prompt)"
}



t() {
  printf 'BOX=%s  IP=%s  PLATFORM=%s  STAGE=%s\n%s\n' \
    "${BOX:-<none>}" "${IP:-<none>}" "${PLATFORM:-<none>}" "${STAGE:-<none>}" "$PWD"
}

proxyon() {
  local p=${BURP_PORT:-8080}
  export http_proxy="http://127.0.0.1:$p"
  export https_proxy="http://127.0.0.1:$p"
  export no_proxy="localhost,127.0.0.1${IP:+,$IP}"
  echo "proxy ON → 127.0.0.1:$p (no_proxy=$no_proxy); proxyoff to go direct"
}

proxyoff() {
  unset http_proxy https_proxy no_proxy
  echo "proxy OFF (direct)"
}

kt() {
  # kt [cmd...]; new tab in the focused kitty window (optional cmd, runs in
  # the current dir). Needs `listen_on unix:` in kitty.conf.
  command -v kitty >/dev/null 2>&1 || { echo "kt: kitty not found"; return 1; }
  if [ $# -gt 0 ]; then
    kitty @ new-tab sh -c "$*"
  else
    kitty @ new-tab
  fi
}
