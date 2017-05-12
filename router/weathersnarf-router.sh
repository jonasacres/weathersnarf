#!/bin/sh

# uses netcat and tcpdump to sniff AcuRite smarthub weather data off the wire, then relay it somewhere else
# put this in permanent storage somewhere (e.g. somewhere under /jffs on DD-WRT)

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 smarthub_ip weatherdb_ip weatherdb_port" >&2
  echo "e.g.: $0 10.0.1.115 10.0.1.116 10100" >&2
  exit 1
fi

command -v tcpdump >/dev/null 2>&1 || { echo >&2 "Unable to find tcpdump. Is it installed and in PATH?"; exit 1; }
command -v nc >/dev/null 2>&1 || { echo >&2 "Unable to find nc. Is it installed and in PATH?"; exit 1; }

PIDFILE=/tmp/weathersnarf-router.pid
[ -f $PIDFILE ] && (echo `date -Iseconds` "Killing existing process " `cat $PIDFILE` ; kill -9 `cat $PIDFILE`)

echo $$ > $PIDFILE

while true
do
  echo `date -Iseconds` "Monitoring weather data from $1, relaying to $2:$3"

  tcpdump -X host $1 and port 80 2>/dev/null | (nc $2 10100 || exit 1)
  sleep 1
  echo `date -Iseconds` "Monitor exited"
done

rm -f $PIDFILE
