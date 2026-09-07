#!/bin/sh
trap 'exit 0' TERM
printf '%s\n' "$$"
/bin/sh -c 'trap "" TERM; printf "%s\n" "$$"; exec /bin/sleep 600' &
wait
