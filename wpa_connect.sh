#!/bin/sh
#
# wpa_connect.sh - manage wireless network connections
#
# usage:
#   - edit file to specify correct interface and wpa profile directory
#   - create wpa_supplicant profile files, e.g. using wpa_passphrase, save as
#       profile_name.conf in wpa profile directory
#   - run ``wpa_connect.sh profile_name'' (without .conf) or simply
#     ``wpa_connect.sh profile_name'' to scan for available access points
#
# requirements: wpa_supplicant, dhcpcd, dialog
#

IFACE=wlp2s0
PROFILE_DIR=/home/user/wpa/

function usage()
{
  echo "$0 [profile [interface]]"
}

function disconnect()
{
  dhcpcd -k "$IFACE"
  [ -n "$WPA_PID" ] && kill -s TERM $WPA_PID
  ifconfig "$IFACE" down
}

function clean()
{
  disconnect

  exit 0
}

if [ ! -z "$2"] ; then
  IFACE="$2"
fi

if [ ! -z "$1" ] ; then
  PROFILE_NAME="$1"
  PROFILE="${PROFILE_NAME}.conf"
else
  # scan for available networks

  # start interface
  ifconfig $IFACE down
  ifconfig $IFACE up

  echo "scanning..."

  APS=$(iwlist $IFACE scan | egrep 'ESSID:"[^"]*"' | sed 's/\s*ESSID:"\([^"]*\)"\s*/\1/')

  AP_COUNT=$(echo "$APS" | wc -l)

  if [ $AP_COUNT -eq 0 ]; then
    echo "no network found."
    exit -1
  else
    echo "found ${AP_COUNT} networks, essids:"

    # check for essids in existing profiles
    FOUND_ESSIDS=""
    FOUND_PROFILES=""
    FOUND_COUNT=0

    list="$APS"

    while [ ! -z "$list" ]; do
      cur="${list%% *}"
      list="${list#$cur}"
      list="${list# }"

      echo "  $cur"

      for f in ${PROFILE_DIR}/* ; do
        profile=$(basename $f)
        profile=${profile%.conf}
        ssid=$(egrep 'ssid="[^"]*"' $f | sed 's/\s*ssid="\([^"]*\)"\s*/\1/')

        if [ "$cur" != "$ssid" ]; then
          continue
        fi

        # profile found, add to list

        if [ -z "${FOUND_PROFILES}" ]; then
          FOUND_PROFILES="$profile"
        else
          FOUND_PROFILES="${FOUND_PROFILES} $profile"
        fi

        if [ -z "${FOUND_ESSIDS}" ]; then
          FOUND_ESSIDS="$ssid"
        else
          FOUND_ESSIDS="${FOUND_ESSIDS} $ssid"
        fi

        FOUND_COUNT=$(expr $FOUND_COUNT + 1)
      done

    done

    if [ $FOUND_COUNT -eq 1 ]; then
      echo "found 1 network with existing profile"
      PROFILE_NAME="$FOUND_PROFILES"
    else
      echo "found ${PROFILE_COUNT} networks with existing profile"

      list="${FOUND_PROFILES}"

      EXEC_STR="dialog --menu \"select network:\" 0 0 0 "

      while [ ! -z "$list" ]; do
        cur="${list%% *}"
        list="${list#$cur}"
        list="${list# }"

        EXEC_STR="${EXEC_STR} \"$cur\" \"\""
      done

      EXEC_STR="${EXEC_STR} 3>&1 1>&2 2>&3"

      opt=$(eval ${EXEC_STR})
      [ -z "$opt" ] && exit -1  # aborted

      PROFILE_NAME="$opt"
    fi
  fi
fi


# connect to selected profile

PROFILE="${PROFILE_NAME}.conf"
PROFILE_FILE="$PROFILE_DIR/$PROFILE"

if [ ! -f "${PROFILE_FILE}" ] ; then
  echo "$0: could not find profile $PROFILE in $PROFILE_DIR."
  exit -1
fi

echo "using interface $IFACE"
echo "using profile ${PROFILE_NAME}"


# check priviledges
if [ "$(id -u)" != "0" ]; then
  echo "$0: error: must be run as root." 1>&2
  exit 1
fi


# copy profile
echo "copy profile"
WPA_FILE="/etc/wpa_supplicant/wpa_supplicant-$IFACE.conf"
cp -v ${PROFILE_FILE} ${WPA_FILE}


# catch CTRL-C etc.
trap "clean" SIGHUP SIGINT SIGTERM


# loop to grab disconnects
while true ; do

  # start interface
  ifconfig $IFACE down
  ifconfig $IFACE up
  
  # authenticate
  wpa_supplicant -i $IFACE -c ${WPA_FILE} -qq &
  WPA_PID=$!

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

