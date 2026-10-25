#!/bin/sh
# Quits NotchMan and opens build/NotchMan.app (run from the repo root, as `make run` does).
#
# Works from any terminal, including a shell inside NotchMan's own Agents terminal: there, pkill skips its own
# ancestors (NotchMan is one), and quitting NotchMan also ends that terminal. So the work happens in a helper
# detached into its own session, which outlives the terminal and NotchMan.
set -e
APP="$(pwd)/build/NotchMan.app"
[ -d "$APP" ] || { echo "No $APP; build it first (make app)." >&2; exit 1; }

/usr/bin/nohup /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/sh -c '
  /usr/bin/pkill -a -x NotchMan || true
  i=0
  while /usr/bin/pgrep -a -x NotchMan >/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  /usr/bin/open "$1"
' relaunch "$APP" >/dev/null 2>&1 &

echo "Restarting NotchMan with $APP"
