#!/bin/sh

# uses netcat and ngrep to sniff AcuRite smarthub weather data off the wire, then relay it somewhere else
# put this in permanent storage somewhere (e.g. somewhere under /jffs on DD-WRT)

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 smarthub_ip weatherdb_ip weatherdb_port" >&2
  echo "e.g.: $0 10.0.1.115 10.0.1.116 10100" >&2
  exit 1
fi

PIDFILE=/tmp/weathersnarf-router.pid
[ -f $PIDFILE ] && (echo `date -Iseconds` "Killing existing process " `cat $PIDFILE` ; kill -9 `cat $PIDFILE`)

echo $$ > $PIDFILE

while true
do
  echo `date -Iseconds` "Monitoring weather data from $1, relaying to $2:$3"
  ngrep -q -d br0 -W byline host $1 and port 80 | nc $2 $3
  sleep 1
  echo `date -Iseconds` "Monitor exited"
done

rm -f $PIDFILE
