#!/bin/sh
#
# wpa_connect.sh - manage network connections
#
# usage:
#   - edit file: specify correct interface and wpa profile directory
#   - create wpa_supplicant profile files, e.g. using wpa_passphrase, save as
#       profile_name.conf in wpa profile directory
#   - run ``wpa_connect.sh profile_name'' (without .conf)
#

IFACE=wlp2s0
PROFILE_DIR=/home/user/wpa/

function usage()
{
  echo "$0 profile [interface]"
}

function disconnect()
{
  dhcpcd -k "$IFACE"
  [ -n "$wpa_pid" ] && kill -s TERM $wpa_pid
  ifconfig "$IFACE" down
}

function clean()
{
  disconnect

  exit 0
}

if [ -z "$1" ] ; then
  usage
  exit -1
fi

if [ ! -z "$2"] ; then
  IFACE="$2"
fi

profile="$1.conf"
file="$PROFILE_DIR/$profile"

if [ ! -f "$file" ] ; then
  echo "$0: could not find profile $profile in $PROFILE_DIR."
  exit -1
fi

echo "using interface $IFACE"
echo "using profile $1"


# check priviledges
if [ "$(id -u)" != "0" ]; then
  echo "$0: error: must be run as root." 1>&2
  exit 1
fi


# copy profile
echo "copy profile"
wpa_file="/etc/wpa_supplicant/wpa_supplicant-$IFACE.conf"
cp -v $file $wpa_file


# catch CTRL-C etc.
trap "clean" SIGHUP SIGINT SIGTERM


# loop to grab disconnects
while true ; do

  # start interface
  ifconfig $IFACE down
  ifconfig $IFACE up
  
  # authenticate
  wpa_supplicant -i $IFACE -c $wpa_file -qq &
  wpa_pid=$!

  # wait for authentication to complete
  sleep 2

  # start dhcpcd
  dhcpcd $IFACE

  echo "connected, continuously check connectivity"

  while true ; do

    # send keep-alive
    ping -qc 1 8.8.4.4 >/dev/null 2>&1 &

    # check connectivity
    route -n | egrep '^0.0.0.0 ' | awk '{print $4}' | grep -q 'U'
    [ $? -eq 0 ] || break

    sleep 2
  done

  echo "connection down, restarting"

  # release ip and kill wpa_supplicant
  disconnect
done
