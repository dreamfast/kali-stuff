#!/bin/sh
# clean.sh — fresh-start hygiene for the Kali guest: wipe shell/tool/agent
# history and box leftovers. Guest-LOCAL only: NEVER touches the shares
# (~/work, ~/shared, ~/obsidian — host data); every config comes back via
# 07-zsh-tweaks.sh on a rebuild anyway.
#
#   ~/clean.sh              standard clean (safe, no confirmation)
#   ~/clean.sh --browser    also firefox + chromium: history, downloads,
#                           cookies, tab-restore, caches — BOOKMARKS and
#                           saved logins are kept (places.sqlite is pruned
#                           via sqlite, never deleted)
#   ~/clean.sh --dry-run    list what would happen, touch nothing
#   ~/clean.sh --yes        skip the --browser confirmation
#
# TRAP: run from a plain shell (kitty tab), NOT inside a tmux/box pane —
# this kills the tmux server first so panes can't re-append history.
set -u

DRY='' BROWSER=0 YES=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --browser) BROWSER=1 ;;
        --yes|-y)  YES=1 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "clean.sh: unknown flag '$a' (--browser --dry-run --yes)" >&2; exit 1 ;;
    esac
done

[ -n "${TMUX:-}" ] && { echo "clean.sh: inside tmux — run me from a plain shell (I kill the tmux server)"; exit 1; }

zap_file() {  # truncate history FILES (tools may hold open fds)
    for f in "$@"; do
        [ -f "$f" ] || continue
        if [ -n "$DRY" ]; then echo "  = $f"; else : > "$f"; echo "  = $f"; fi
    done
}
zap_dir() {   # remove state DIRS outright
    for d in "$@"; do
        [ -e "$d" ] || continue
        if [ -n "$DRY" ]; then echo "  x $d"; else rm -rf "$d"; echo "  x $d"; fi
    done
}

echo "clean: tmux"
if [ -n "$DRY" ]; then
    tmux ls >/dev/null 2>&1 && echo "  x tmux server (all sessions, termlogs stop)" || echo "  (no server)"
else
    tmux kill-server >/dev/null 2>&1 && echo "  x tmux server killed" || echo "  (no server)"
fi

echo "clean: shell + tool histories"
zap_file ~/.zsh_history ~/.bash_history ~/.python_history ~/.sqlite_history \
          ~/.gdb_history ~/.mysql_history ~/.psql_history ~/.lesshst \
          ~/.viminfo ~/.node_repl_history
zap_dir  ~/.rlwrap

echo "clean: metasploit + tmux-resurrect artifacts"
zap_dir  ~/.msf4/history ~/.msf4/loot ~/.tmux/resurrect

echo "clean: pi agent"
zap_dir  ~/.pi/agent/history ~/.pi/agent/sessions ~/.pi/subagent

echo "clean: workbench helpers"
zap_file ~/.cache/n-clip.json
if command -v cliphist >/dev/null 2>&1; then
    # clipboard history: copied creds live here in plaintext
    if [ -n "$DRY" ]; then echo "  = cliphist history"
    else cliphist wipe >/dev/null 2>&1 && echo "  = cliphist history"; fi
fi
for f in /tmp/nb-pane-ready-*; do
    [ -f "$f" ] || continue
    if [ -n "$DRY" ]; then echo "  x $f"; else rm -f "$f"; echo "  x $f"; fi
done
# keep the inode (polybar's tail -F follows it); just empty it
if [ -f /tmp/nb-current-target ]; then
    if [ -n "$DRY" ]; then echo "  = /tmp/nb-current-target"; else : > /tmp/nb-current-target; echo "  = /tmp/nb-current-target"; fi
fi

echo "clean: /etc/hosts box markers"
if grep -q '# box:' /etc/hosts 2>/dev/null; then
    if [ -n "$DRY" ]; then
        echo "  = $(grep -c '# box:' /etc/hosts) '# box:' line(s)"
    elif sudo -n sed -i '/# box:/d' /etc/hosts 2>/dev/null; then
        echo "  = removed '# box:' lines"
    else
        echo "  ! need sudo (NOPASSWD unavailable) — clean manually: sudo sed -i '/# box:/d' /etc/hosts"
    fi
else
    echo "  (none)"
fi

if [ "$BROWSER" = 1 ]; then
    echo "clean: firefox (bookmarks + logins kept)"
    if pgrep -x firefox >/dev/null 2>&1 || pgrep -f 'firefox-esr' >/dev/null 2>&1; then
        echo "  ! firefox is running — close it first, skipped"
    elif ! command -v sqlite3 >/dev/null 2>&1; then
        echo "  ! sqlite3 not installed — skipped (apt install sqlite3)"
    else
        go=1
        if [ "$YES" != 1 ] && [ -z "$DRY" ]; then
            printf '  wipe firefox + chromium history/cookies/sessions? [y/N] '
            read -r ans </dev/tty
            case "$ans" in y|Y|yes) ;; *) go=0; echo "  skipped" ;; esac
        fi
        if [ "$go" = 1 ]; then
            found=0
            for d in ~/.mozilla/firefox/*/; do
                [ -f "$d/places.sqlite" ] || continue
                found=1
                if [ -n "$DRY" ]; then echo "  = $d (history rows; keep bookmarks)"; continue; fi
                # row-delete, NOT file-delete: places.sqlite also holds the
                # bookmarks; each statement alone (profiles may miss tables)
                for q in 'DELETE FROM moz_historyvisits;' \
                          'DELETE FROM moz_places WHERE id NOT IN (SELECT COALESCE(fk,-1) FROM moz_bookmarks);' \
                          'DELETE FROM moz_inputhistory WHERE place_id NOT IN (SELECT id FROM moz_places);' \
                          'DELETE FROM moz_annos WHERE place_id NOT IN (SELECT id FROM moz_places);' \
                          'VACUUM;'; do
                    sqlite3 "$d/places.sqlite" "$q" 2>/dev/null
                done
                rm -f "$d/places.sqlite-wal" "$d/places.sqlite-shm" \
                      "$d/cookies.sqlite" "$d/cookies.sqlite-wal" \
                      "$d/formhistory.sqlite"
                rm -rf "$d/sessionstore-backups" "$d/sessionstore-backups.bak"
                rm -f "$d/sessionstore.json" "$d/sessionstore.bak"
                echo "  = $d"
            done
            [ "$found" = 1 ] || echo "  (no firefox profiles found)"
            zap_dir ~/.cache/mozilla
        fi
    fi

    echo "clean: chromium (history/downloads; logins kept)"
    if pgrep -x chromium >/dev/null 2>&1; then
        echo "  ! chromium is running — close it first, skipped"
    else
        found=0
        for d in ~/.config/chromium/*/; do
            [ -d "$d" ] || continue
            zap_file "$d/History" "$d/Download Data" "$d/Visited Links"
            [ -f "$d/History" ] && found=1
        done
        [ "$found" = 1 ] || echo "  (no chromium profiles found)"
    fi
fi

[ -n "$DRY" ] && echo "clean: dry-run, nothing touched" || echo "clean: done"
