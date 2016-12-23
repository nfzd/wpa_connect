#!/bin/sh
#
# wpa_connect.sh - manage wireless network connections
#
# usage:
#   - create wpa_supplicant profile files, e.g. using wpa_passphrase, save as
#       profile_name.conf in wpa profile directory
#   - pass interface and profile directory as arguments or via config files
#   - run ``wpa_connect.sh profile_name'' (without .conf) or simply
#     ``wpa_connect.sh profile_name'' to scan for available access points
#
# requirements: wpa_supplicant, dhcpcd, dialog
#

GLOBAL_CFG="/etc/.wpa_connect"
USER_CFG="/home/$(logname)/.wpa_connect"

# ----------------------------------------------------------------------
# functions

function usage()
{
  UND="\033[4m"
  CLR="\033[0m"

  echo -e "$0 [profile [interface [config_dir]]]"
  echo -e "$0 -h"
  echo -e "$0 make_skel"
  echo -e ""
  echo -e "args:"
  echo -e "  profile:      wpa_supplicant config file name to use for connection"
  echo -e "  interface:    network interface to use"
  echo -e "  config_dir:   directory containing wpa_supplicant config files"
  echo -e ""
  echo -e "If ${UND}profile${CLR} is not passed, use suitable profiles from"\
          "${UND}config_dir${CLR}."
  echo -e ""
  echo -e "If ${UND}interface${CLR} and ${UND}config_dir${CLR} are not both"\
          "passed as arguments, attempt to use"
  echo -e "the following configuration files (in the given order):"
  echo -e "  ${GLOBAL_CFG}"
  echo -e "  ${USER_CFG}"
  echo -e ""
  echo -e "If the first argument is ${UND}make_skel${CLR}, create a skeleton"\
          "config file in the latter"
  echo -e "of these config directories (if it doesn't exist)."

}

function disconnect()
{
  dhcpcd -k "${IFACE}"
  [ -n "${WPA_PID}" ] && kill -s TERM ${WPA_PID} 2>/dev/null
  ifconfig "${IFACE}" down
}

function clean()
{
  disconnect

  exit 0
}

# ----------------------------------------------------------------------
# check priviledges

if [ "$(id -u)" != "0" ]; then
  echo "$0: error: must be run as root." 1>&2
  exit 1
fi

# ----------------------------------------------------------------------
# setup parameters from commandline or config files

if [ $# -gt 3 ] ; then
  usage
  exit -1
fi

if [ "$1" = '-h' ] ; then
  usage
  exit 0
fi

if [ "$1" = 'make_skel' ] ; then
  if [ -f "${USER_CFG}" ] ; then
    echo "$0: cannot make skeleton config file, ${USER_CFG} already exists."
    exit -1
  fi

  USER=$(logname)

  echo "# .wpa_connect" > ${USER_CFG}
  echo "" >> ${USER_CFG}
  echo "# interface" >> ${USER_CFG}
  echo "IFACE=wlp2s0" >> ${USER_CFG}
  echo "" >> ${USER_CFG}
  echo "# directory containing wpa_supplicant config files" >> ${USER_CFG}
  echo "PROFILE_DIR=/home/${USER}/wpa/" >> ${USER_CFG}

  chown "${USER}:users" "${USER_CFG}"

  echo "created skeleton config file in ${USER_CFG}"
  exit 0
fi

if [ -f "${USER_CFG}" ] ; then
  echo "found config file ${USER_CFG}"
  . ${USER_CFG}
fi

if [ -f "${GLOBAL_CFG}" ] ; then
  echo "found config file ${GLOBAL_CFG}"
  # sourcing last to overwrite other values
  . ${GLOBAL_CFG}
fi

if [ ! -z "$3" ] ; then
  PROFILE_DIR="$2"
fi

if [ ! -z "$2" ] ; then
  IFACE="$2"
fi

if [ -z "${IFACE}" ] || [ -z "${PROFILE_DIR}" ] ; then
  usage
  exit -1
fi

# ----------------------------------------------------------------------
# check parameter values

IFACES=$(ifconfig -a | egrep -o '^\S{1,}:' | tr -d ':')
IFACE_FOUND=0
while read if ; do
  if [ "$if" = "$IFACE" ] ; then
    IFACE_FOUND=1
    break
  fi
done <<< "${IFACES}"

if [ ${IFACE_FOUND} -ne 1 ] ; then
  echo "$0: requested interface ${IFACE} does not exist."
  exit -1
fi

if [ ! -d "${PROFILE_DIR}" ] ; then
  echo "$0: requested config_dir ${PROFILE_DIR} does not exist."
  exit -1
fi

echo "using interface $IFACE"
echo "using config directory $PROFILE_DIR"

# ----------------------------------------------------------------------
# determine actual profile to use

if [ ! -z "$1" ] ; then
  PROFILE_NAME="$1"
  PROFILE="${PROFILE_NAME}.conf"
else
  # scan for available networks

  # start interface
  ifconfig ${IFACE} down
  ifconfig ${IFACE} up

  echo "scanning..."

  SCAN=$(iwlist ${IFACE} scan)
  APS=$(echo "${SCAN}" | egrep 'ESSID:"[^"]*"' | sed 's/\s*ESSID:"\([^"]*\)"\s*/\1/')
  QUALITIES=$(echo "${SCAN}" | egrep '^\s*Quality=' | sed 's/\s*Quality=\([0-9/]*\)\s*.*/\1/')

  AP_COUNT=$(echo "${APS}" | wc -l)

  if [ ${AP_COUNT} -eq 0 ]; then
    echo "no network found."
    exit -1
  else
    echo "found ${AP_COUNT} networks, essids:"

    # check for essids in existing profiles
    FOUND_ESSIDS=""
    FOUND_PROFILES=""
    FOUND_QUALITIES=""
    FOUND_COUNT=0

    AP_LIST=$(echo "${APS}" | tr '\n' ' ')
    QUALITY_LIST=$(echo "${QUALITIES}" | tr '\n' ' ')

    while [ ! -z "$AP_LIST" ]; do
      AP_CUR="${AP_LIST%% *}"
      AP_LIST="${AP_LIST#$AP_CUR}"
      AP_LIST="${AP_LIST# }"

      QUALITY_CUR="${QUALITY_LIST%% *}"
      QUALITY_LIST="${QUALITY_LIST#$QUALITY_CUR}"
      QUALITY_LIST="${QUALITY_LIST# }"

      echo "  ${AP_CUR} (${QUALITY_CUR})"

      for f in ${PROFILE_DIR}/* ; do
        PROFILE=$(basename $f)
        PROFILE=${PROFILE%.conf}
        SSID=$(egrep 'ssid="[^"]*"' $f | sed 's/\s*ssid="\([^"]*\)"\s*/\1/')

        if [ "${AP_CUR}" != "${SSID}" ]; then
          continue
        fi

        # profile found, add to list

        if [ -z "${FOUND_PROFILES}" ]; then
          FOUND_PROFILES="${PROFILE}"
        else
          FOUND_PROFILES="${FOUND_PROFILES} ${PROFILE}"
        fi

        if [ -z "${FOUND_ESSIDS}" ]; then
          FOUND_ESSIDS="${SSID}"
        else
          FOUND_ESSIDS="${FOUND_ESSIDS} ${SSID}"
        fi

        if [ -z "${FOUND_QUALITIES}" ]; then
          FOUND_QUALITIES="${QUALITY_CUR}"
        else
          FOUND_QUALITIES="${FOUND_QUALITIES} ${QUALITY_CUR}"
        fi

        FOUND_COUNT=$(expr ${FOUND_COUNT} + 1)
      done

    done

    if [ ${FOUND_COUNT} -eq 1 ]; then
      echo "found 1 network with existing profile"
      PROFILE_NAME="${FOUND_PROFILES}"
    else
      echo "found ${FOUND_COUNT} networks with existing profiles"

      PROFILE_LIST="${FOUND_PROFILES}"
      QUALITY_LIST="${FOUND_QUALITIES}"

      EXEC_STR="dialog --menu \"select network:\" 0 0 0 "

      while [ ! -z "${PROFILE_LIST}" ]; do
        PROFILE_CUR="${PROFILE_LIST%% *}"
        PROFILE_LIST="${PROFILE_LIST#${PROFILE_CUR}}"
        PROFILE_LIST="${PROFILE_LIST# }"

        QUALITY_CUR="${QUALITY_LIST%% *}"
        QUALITY_LIST="${QUALITY_LIST#${QUALITY_CUR}}"
        QUALITY_LIST="${QUALITY_LIST# }"

        EXEC_STR="${EXEC_STR} \"${PROFILE_CUR}\" \"${QUALITY_CUR}\""
      done

      EXEC_STR="${EXEC_STR} 3>&1 1>&2 2>&3"

      OPT=$(eval ${EXEC_STR})
      [ -z "${OPT}" ] && exit -1  # aborted

      PROFILE_NAME="${OPT}"
    fi
  fi
fi

PROFILE="${PROFILE_NAME}.conf"
PROFILE_FILE="$PROFILE_DIR/$PROFILE"

if [ ! -f "${PROFILE_FILE}" ] ; then
  echo "$0: could not find profile $PROFILE in $PROFILE_DIR."
  exit -1
fi

echo "using profile ${PROFILE_NAME}"

# ----------------------------------------------------------------------
# connect to selected profile


# copy profile
echo "copy profile"
WPA_FILE="/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf"
cp -v ${PROFILE_FILE} ${WPA_FILE}


# catch CTRL-C etc.
trap "clean" SIGHUP SIGINT SIGTERM


# loop to grab disconnects
while true ; do

  # start interface
  ifconfig ${IFACE} down
  ifconfig ${IFACE} up

  # authenticate
  wpa_supplicant -i ${IFACE} -c ${WPA_FILE} -qq &
  WPA_PID=$!

  # wait for authentication to complete
  sleep 2

  # start dhcpcd
  dhcpcd ${IFACE}

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

