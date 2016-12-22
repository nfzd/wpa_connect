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

echo "using interface $IFACE"

if [ ! -z "$1" ] ; then
  PROFILE_NAME="$1"
  PROFILE="${PROFILE_NAME}.conf"
else
  # scan for available networks

  # start interface
  ifconfig $IFACE down
  ifconfig $IFACE up

  echo "scanning..."

  scan=$(iwlist $IFACE scan)
  APS=$(echo "$scan" | egrep 'ESSID:"[^"]*"' | sed 's/\s*ESSID:"\([^"]*\)"\s*/\1/')
  QUALITIES=$(echo "$scan" | egrep '^\s*Quality=' | sed 's/\s*Quality=\([0-9/]*\)\s*.*/\1/')

  AP_COUNT=$(echo "$APS" | wc -l)

  if [ $AP_COUNT -eq 0 ]; then
    echo "no network found."
    exit -1
  else
    echo "found ${AP_COUNT} networks, essids:"

    # check for essids in existing profiles
    FOUND_ESSIDS=""
    FOUND_PROFILES=""
    FOUND_QUALITIES=""
    FOUND_COUNT=0

    ap_list=$(echo "$APS" | tr '\n' ' ')
    quality_list=$(echo "$QUALITIES" | tr '\n' ' ')

    while [ ! -z "$ap_list" ]; do
      ap_cur="${ap_list%% *}"
      ap_list="${ap_list#$ap_cur}"
      ap_list="${ap_list# }"

      quality_cur="${quality_list%% *}"
      quality_list="${quality_list#$quality_cur}"
      quality_list="${quality_list# }"

      echo "  $ap_cur ($quality_cur)"

      for f in ${PROFILE_DIR}/* ; do
        profile=$(basename $f)
        profile=${profile%.conf}
        ssid=$(egrep 'ssid="[^"]*"' $f | sed 's/\s*ssid="\([^"]*\)"\s*/\1/')

        if [ "$ap_cur" != "$ssid" ]; then
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

        if [ -z "${FOUND_QUALITIES}" ]; then
          FOUND_QUALITIES="$quality_cur"
        else
          FOUND_QUALITIES="${FOUND_QUALITIES} $quality_cur"
        fi

        FOUND_COUNT=$(expr $FOUND_COUNT + 1)
      done

    done

    if [ $FOUND_COUNT -eq 1 ]; then
      echo "found 1 network with existing profile"
      PROFILE_NAME="$FOUND_PROFILES"
    else
      echo "found ${FOUND_COUNT} networks with existing profiles"

      profile_list="${FOUND_PROFILES}"
      quality_list="${FOUND_QUALITIES}"

      EXEC_STR="dialog --menu \"select network:\" 0 0 0 "

      while [ ! -z "$profile_list" ]; do
        profile_cur="${profile_list%% *}"
        profile_list="${profile_list#$profile_cur}"
        profile_list="${profile_list# }"

        quality_cur="${quality_list%% *}"
        quality_list="${quality_list#$quality_cur}"
        quality_list="${quality_list# }"

        EXEC_STR="${EXEC_STR} \"$profile_cur\" \"$quality_cur\""
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

