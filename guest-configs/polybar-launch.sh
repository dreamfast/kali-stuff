#!/bin/sh
# polybar launcher: run via i3 exec_always (restarts the bar on every i3 reload)
pkill -x polybar 2>/dev/null
sleep 0.2
exec polybar -q top
