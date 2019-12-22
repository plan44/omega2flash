#!/bin/bash

# host script to flash a fresh-from-factory Omega2(+) or Omega2S(+) without user intervention

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 <ethernet-if> <auto|wait|omega2_ipv6|list|ping> [<firmware.bin> [<uboot_env_file>]]"
  echo "Notes: to find ethernet-if name,"
  echo "- on mac OS, yuse 'networksetup -listallhardwareports'"
  echo "- on Linux, use 'ifconfig' or 'ip link'"
  exit 1
fi

# config
PROG_LOG="/tmp/flashed_ipv6"

# gather args
ETH_IF=$1
OMEGA2_IPV6=$2
FWIMG_FILE=$3
UBOOT_ENV_FILE=$4
# check for FW image
if [[ -n "${FWIMG_FILE}" && ! -f "${FWIMG_FILE}" ]]; then
  echo "firmware file '${FWIMG_FILE}' not found"
  exit 1
fi
# check for uboot environment file
if [[ -n "${UBOOT_ENV_FILE}" && ! -f "${UBOOT_ENV_FILE}" ]]; then
  echo "uboot environment file '${UBOOT_ENV_FILE}' not found"
  exit 1
fi
# check for "expect" utility
if ! command -v expect; then
  echo "missing 'expect' command line tool - must be installed for this script to work"
  exit 1
fi



# Locate target Omega

OMEGA_ETH_IPV6_PREFIX="fe80::42a3:6bff:fec" # Omega2 prefix
OMEGA_BROKEN_ETH_IPV6="fe80::24c:2ff:fe08:4d0f" # Omega2S with unprogrammed Ethernet MAC

OMEGA_MATCH="s/^[0-9]+ +bytes from (${OMEGA_ETH_IPV6_PREFIX}[0-9A-Fa-f]:[0-9A-Fa-f]{4}|${OMEGA_BROKEN_ETH_IPV6}).*\$/\1/p"

MISSING_MAC=0
if [[ "${OMEGA2_IPV6}" == "list" ]]; then
  echo "[$(date)] Searching for Omega2(S)(+) on ${ETH_IF} via ping6 multicast (4 seconds)..."
  ping6 -c 2 -i 4 ff02::1%${ETH_IF} | grep -E "${OMEGA_ETH_IPV6_PREFIX}|${OMEGA_BROKEN_ETH_IPV6}"
  exit 0
elif [[ "${OMEGA2_IPV6}" == "ping" ]]; then
  echo "[$(date)] Searching for all IPv6 devices on ${ETH_IF} via ping6 multicast (4 seconds)..."
  ping6 -c 2 -i 4 ff02::1%${ETH_IF}
  exit 0
elif [[ "${OMEGA2_IPV6}" == "auto" ]]; then
  echo "Searching for Omega2 or Omega2S via ping6 multicast (4 seconds)..."
  OMEGA2_IPV6=""
  # use ping6 multicast to query devices
  OMEGA2_IPV6=$(ping6 -c 2 -i 4 ff02::1%${ETH_IF} | sed -n -E -e "${OMEGA_MATCH}")
  if [ ${#OMEGA2_IPV6} -gt 30 ]; then
    echo "More than one Omega2 or malprogrammed Omega2S found on Ethernet interface ${ETH_IF}:"
    echo "${OMEGA2_IPV6}"
    exit 1
  elif [ -z "${OMEGA2_IPV6}" ]; then
    echo "No IPv6 enabled (factory state) Omega2 or malprogrammed Omega2S found on Ethernet interface ${ETH_IF}"
    exit 1
  fi
  echo "[$(date)] Found unprogrammed Omega2 at ${OMEGA2_IPV6} on ${ETH_IF}"
elif [[ "${OMEGA2_IPV6}" == "wait" ]]; then
  echo "[$(date)] Polling for unprogrammed Omega2 or Omega2S via ping6 multicast..."
  OMEGA2_IPV6=""
  while [ -z "$OMEGA2_IPV6" ]; do
    # use ping6 multicast to query devices
    sleep 2
    echo "- ping..."
    OMEGA2_IPV6=$(ping6 -c 2 -i 2 ff02::1%${ETH_IF} | sed -n -E -e "${OMEGA_MATCH}")
    if [ ${#OMEGA2_IPV6} -gt 30 ]; then
      echo "[$(date)] More than one Omega2 or malprogrammed Omega2S found on Ethernet interface ${ETH_IF}, waiting until only one found"
      OMEGA2_IPV6=""
    fi
    # check for same IPv6 than just programmed one
    if [ "${OMEGA2_IPV6}" != "${OMEGA_BROKEN_ETH_IPV6}" ]; then
      if [ -n "${OMEGA2_IPV6}" ]; then
        grep -q "${OMEGA2_IPV6}" "${PROG_LOG}"
        if [[ $? == 0 ]]; then
          # still same, no verbose output
          echo "  [$(date)] still same device ${OMEGA2_IPV6} -> wait"
          OMEGA2_IPV6=""
        fi
      fi
    fi
  done
  echo ""
  echo  "[$(date)] Found unprogrammed Omega2 at ${OMEGA2_IPV6} on ${ETH_IF} - starting to program in 5 seconds..."
  sleep 5
else
  echo "[$(date)] Assuming unprogrammed Omega2 at ${OMEGA2_IPV6} on ${ETH_IF} - trying to program it now..."
fi

if [ -z "${FWIMG_FILE}" ]; then
  echo "[$(date)] No firmware specified -> no further operation"
  exit 0
fi

if [ "${OMEGA2_IPV6}" == "${OMEGA_BROKEN_ETH_IPV6}" ]; then
  echo "[$(date)] Found Omega2S with no valid factory-programmed ethernet MAC at ${OMEGA2_IPV6} on ${ETH_IF} -> will add extra steps to provision it"
  MISSING_MAC=1
  # need to provision MAC address
  cat >/tmp/provisionmac <<'ENDOFFILE4'
# provision invalid ethernet MAC from valid wifi MAC
# - get Omega2 ID from wifi
IDHEX=$(iwpriv ra0 e2p | sed -n -E -e "s/\[0x0008\]:([0-9A-F]{2})([0-9A-F]{2}).*\$/\2\1/p")
NEWID=$(printf "%04x" $((0x$IDHEX+2)))
IDWORD="${NEWID:2:2}${NEWID:0:2}"
# - set ethernet address
iwpriv ra0 e2p 28=A340 | iwpriv ra0 e2p 2A=C16B | iwpriv ra0 e2p 2C=${IDWORD}
ENDOFFILE4
else
  echo "[$(date)] Found Omega2(S) with valid ethernet MAC at ${OMEGA2_IPV6} on ${ETH_IF}"
  echo "# MAC is ok -> NOP" >/tmp/provisionmac
fi
chmod a+x /tmp/provisionmac

# anyway, prepare a deferred uboot environment setter script
cat >/tmp/setubootenv <<ENDOFFILE5
#!/bin/sh /etc/rc.common
# Copyright (c) 2017-2019 plan44.ch/luz
START=98
boot() {
  echo "[omega2flash] provisioning uboot environment"
  fw_setenv -s /etc/o2ubootenv
  rm /etc/rc.d/S98setubootenv
  rm /etc/o2ubootenv
  rm /etc/init.d/setubootenv
}
ENDOFFILE5
chmod a+x /tmp/setubootenv

# link-local address to access target from here on
OMEGA2_LINKLOCAL="${OMEGA2_IPV6}%${ETH_IF}"

# check if this unit was already programmed
grep "${OMEGA2_IPV6}" "${PROG_LOG}"
if [[ $? == 0 ]]; then
  # already programmed
  echo "[$(date)] Omega2 at ${OMEGA2_IPV6} has been programmed before -> do not try it again"
  cat /var/dhcp.leases
  sleep 10
  exit 1
fi

# try to access the omega
echo "[$(date)] Trying to ping6 omega2 at ${OMEGA2_IPV6}"
ping6 -c 1 ${OMEGA2_LINKLOCAL}
if [[ $? != 0 ]]; then
  echo "[$(date)] could not ping Omega2(S) at ${OMEGA2_IPV6} on ethernet interface ${ETH_IF}"
  exit 1
fi

# create temp script to use ssh and scp w/o entering password
cat >/tmp/o2defpw <<'ENDOFFILE1'
#!/usr/bin/expect
set password onioneer
set timeout 20
set cmd [lrange $argv 0 end]
eval spawn $cmd
expect "assword:"
send "$password\r";
interact
ENDOFFILE1
chmod a+x /tmp/o2defpw


# Now we are reasonably sure we will be able to program this unit, remember it for not programming twice
# but do not remember the non-unique missing MAC derived IPv6, as we might need to program more of these
if [[ ${MISSING_MAC} == 0 ]]; then
  echo "${OMEGA2_IPV6}" >>"${PROG_LOG}"
fi


# create environment setup
if [[ -n "${UBOOT_ENV_FILE}" ]]; then
  cp "${UBOOT_ENV_FILE}" /tmp/o2ubootenv
fi


# create temp script to flash environment and firmware image
cat >/tmp/o2bootstrap <<'ENDOFFILE3'
# make sure we have the fw_env.conf file
if [ ! -e /etc/fw_env.config ]; then
  echo "/dev/mtd1 0x0 0x1000 0x10000" >/etc/fw_env.config
fi
# now upgrade
echo ">>>>> provisioning MAC address (if needed)"
/tmp/provisionmac
if [ -f /tmp/o2ubootenv ]; then
  echo ">>>>> setting environment"
  # environment is not writable now, we need to defer programming it to when our own FW is up
  # - prepare config backup
  mkdir -p /tmp/cfgbackup/etc/init.d
  mkdir -p /tmp/cfgbackup/etc/rc.d
  cp /tmp/o2ubootenv /tmp/cfgbackup/etc
  cp /tmp/setubootenv /tmp/cfgbackup/etc/init.d
  cd /tmp/cfgbackup/etc/rc.d
  ln -s ../init.d/setubootenv S98setubootenv
  # create config archive for sysupgrade
  cd /tmp/cfgbackup
  tar -czf /tmp/deferredcfg.tgz *
fi
echo ">>>>> installing firmware"
cd /tmp
if [ -e /tmp/deferredcfg.tgz ]; then
  # needs deferred config stuff, pass it to updater
  sysupgrade -f /tmp/deferredcfg.tgz o2firmware.bin >/tmp/sysupgrade.out 2>&1 &
else
  # clean install, just image
  sysupgrade -n o2firmware.bin >/tmp/sysupgrade.out 2>&1 &
fi
# two minutes is enough for flashing
sleep 120
# we don't expect to get here!
echo "**** Error: should have restarted with new firmware, but apparently has not"
ENDOFFILE3
chmod a+x /tmp/o2bootstrap


echo "[$(date)] Trying to login to Omega2 and do a ls -la /tmp ..."
/tmp/o2defpw ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -y -y root@${OMEGA2_LINKLOCAL} "ls -la /tmp"

echo "[$(date)] Copying firmware, uboot environment and bootstrap script to device ..."
# copy fw image
/tmp/o2defpw scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "${FWIMG_FILE}" root@[${OMEGA2_LINKLOCAL}]:/tmp/o2firmware.bin
# copy MAC provisioning script
/tmp/o2defpw scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  /tmp/provisionmac root@[${OMEGA2_LINKLOCAL}]:/tmp
# copy uboot env file if there is any
if [[ -f /tmp/o2ubootenv ]]; then
  /tmp/o2defpw scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  /tmp/o2ubootenv root@[${OMEGA2_LINKLOCAL}]:/tmp
fi
# copy deferred uboot env provisioning script (not always used, but needed for factory-broken Omega2S)
/tmp/o2defpw scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  /tmp/setubootenv root@[${OMEGA2_LINKLOCAL}]:/tmp
# copy bootstrap script
/tmp/o2defpw scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  /tmp/o2bootstrap root@[${OMEGA2_LINKLOCAL}]:/tmp
echo "done copying files"

echo "Executing the flashing script"
# execute the script
/tmp/o2defpw ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no  root@${OMEGA2_LINKLOCAL} /tmp/o2bootstrap

echo "[$(date)] DONE SO FAR! Make sure not to disconnect Omega2 from power until flashing is complete!"
exit 0