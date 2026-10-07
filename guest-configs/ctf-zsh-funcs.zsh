# ctf-zsh-funcs.zsh: CTF shell helpers, deployed by 07-zsh-tweaks.sh to
# ~/.local/share/ctf-zsh-funcs.zsh, sourced from /etc/zsh/zshenv (every
# zsh instance: tmux panes, kssh `zsh -c`, scripts).
#
#   t            print the current box context (BOX/IP/PLATFORM/STAGE/PWD)
#   stage <s>    switch the box's STAGE (rewrites .envrc; `n` targets it)
#   proxyon      route HTTP(S) through the box's Burp (127.0.0.1:$BURP_PORT)
#   proxyoff     go direct (unset proxies); use for ssh/smb to the same IP
#   kt [cmd]     new tab in the focused kitty window (kitty @ remote control)
#
# Also registers two INTERACTIVE tmux-pane hooks: _nb_tgt_sync (pane title +
# /tmp/nb-current-target, repainted every prompt) and _nb_cmd_sep (the
# "──▶ [user@host ts] cmd" termlog trail separator that `n -l` parses).

# -- per-pane target context (pane title → tmux border + polybar target
# -- module), re-derived on every prompt (precmd) and command start (preexec).
# -- TRAP: this stripped tmux build has NO select-pane -p/-P → the context
# -- lives in the pane TITLE (tmux.conf's pane-border-format renders it).
# -- INTERACTIVE-only: non-interactive zsh inherits $TMUX and this build
# -- fires preexec per script line with an EMPTY cmdline → phantom
# -- separators that poison `n -l`'s trail. Pane shells are interactive.
if [ -n "${TMUX:-}" ] && [[ -o interactive ]]; then
  # ALWAYS register (never guard via an exported marker): an exported one
  # leaks into child envs and disarms the hooks in every pane of a session
  # created from this shell.
  unset _NB_TGT_DONE
  _nb_tgt_sync() {
    local t=""
    if [ -n "${BOX:-}" ]; then
      t="${BOX}${IP:+ · ${IP}}"
      # stage from the box's .envrc — the FILE is the source of truth, so a
      # `stage` switch repaints every pane at its next prompt
      local st
      st=$(sed -n 's/^export STAGE=//p' "${CTFS_ROOT:-$HOME/work/ctf}/$BOX/.envrc" 2>/dev/null | head -1)
      [ -n "$st" ] && t="$t · $st"
    fi
    printf '%s' "$t" > /tmp/nb-current-target 2>/dev/null
    if [ -n "${TMUX:-}" ]; then
      # Kill the rc's OSC title escape: tmux would overwrite our pane title
      # with it every prompt; ours is re-applied last so it wins regardless
      # of hook order.
      TERM_TITLE=""
      if [ "$t" != "${_NB_TGT_LAST:-}" ]; then
        # $TMUX_PANE targets THIS pane; `-t =` fails in detached sessions
        # (where box's auto-panes live most of their life).
        tmux select-pane -t "${TMUX_PANE:-=}" -T "$t" 2>/dev/null
        _NB_TGT_LAST=$t
      fi
    fi
  }
  # Hook registration: membership-guarded against a same-shell double
  # source. TRAP: ${arr[(I)pat]} returns "0" (not empty) on misses in this
  # zsh build, so [ -z ]-style guards never fire; the case/string form is safe.
  case " ${precmd_functions} " in *" _nb_tgt_sync "*) ;; *) precmd_functions+=(_nb_tgt_sync) ;; esac
  case " ${preexec_functions} " in *" _nb_tgt_sync "*) ;; *) preexec_functions+=(_nb_tgt_sync) ;; esac
  _nb_tgt_sync

  # termlog command separator: "──▶ [user@host date] cmd" as each command
  # starts — the trail `n -l` splits on EXACTLY this shape (the ▶ sentinel
  # makes it unmatchable by tool output).
  # The line is VARIABLE-EXPANDED via zsh's (e) flag so `echo $IP` trails as
  # `echo 10.x.x.x` — but $(...) substitutions DO execute at trail time (and
  # again for real right after; avoid trail-time side effects). Malformed
  # input falls back to the raw line; embedded newlines are flattened.
  _nb_cmd_sep() {
    local cmd="$1" exp
    exp="${(e)cmd}" 2>/dev/null || exp=''
    exp="${exp//$'\n'/ }"
    printf '──▶ [%s@%s %s] %s\n' "${USER:-$(id -un)}" "${HOST%%.*}" "$(date '+%F %T')" "${exp:-$cmd}"
  }
  case " ${preexec_functions} " in *" _nb_cmd_sep "*) ;; *) preexec_functions+=(_nb_cmd_sep) ;; esac
fi


stage() {
  # rewrites STAGE= in the box's .envrc (the source of truth: every pane's
  # direnv reloads it at its next prompt; `n` reads the file directly) and
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
