#!/bin/sh

# ssh options (needed to connect to old/unknown units with old crypto and maybe re-used IP/host address)
SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa"

# use bash when available
if [ -e /bin/bash -a -z "${_BASH_REDIRECTED}" ]; then
  _BASH_REDIRECTED=1 exec /bin/bash $0 $@
  exit 1
fi

# host script to flash a fresh-from-factory Omega2(+) or Omega2S(+) without user intervention

# colored output
if [ -t 1 -o -n "$FORCE_COLOR" ]; then
  if [ -z "$NO_COLOR" ]; then
    _INFO='\033[90m' # info: gray (bright black)
    _NOTICE='\033[92m' # notice: bright green
    _ERR='\033[91m' # error: bright red
    _WARN='\033[93m' # warning: bright yellow
    _N='\033[m' # normal
    _UP="\033[F" # move cursor up
  fi
fi

err()
{
  echo -e "$_ERR$@$_N"
}

warn()
{
  echo -e "$_WARN$@$_N"
}

notice()
{
  echo -e "$_NOTICE$@$_N"
}

info()
{
  echo -e "$_INFO$@$_N"
}

plain()
{
  echo -e "$_N$@"
}

die() {
  err "*** Error:" $@
  exit 1
}

# check sufficient shell (we use some bashisms below, but have /bin/sh shebang so we can run on openwrt
# (having no $SHELL set is assumed to mean being called from an environment such as startup scripts which knows this shell is ok)
if [ -n "$SHELL" ]; then
  if ! echo "$SHELL" | grep -q -E -e "zsh|bash|ash"; then
    die "needs zsh, bash or ash shell."
  fi
fi

if [[ $# -lt 2 || $# -gt 5 ]]; then
  warn "Usage: $0 <ethernet-if> <auto|wait|omega2_ipv6|list|ping> [<firmware.bin> [<uboot_env_file>] [<extra_conf_files_dir]]"
  info "Notes: to find ethernet-if name:"
  info "  networksetup -listallhardwareports # for macOS"
  info "  ifconfig # Linux traditional tool"
  info "  ip link # Linux, modern tool"
  exit 1
fi

# config
PROG_LOG="/tmp/flashed_omega2_ipv6"
touch "${PROG_LOG}"

# gather args
ETH_IF=$1
OMEGA2_IPV6=$2
FWIMG_FILE=$3
# if 4th param is dir, it is extra_conf_files_dir, otherwise uboot_env_file
if [ -d "$4" ]; then
  EXTRA_CONF_FILES_DIR=$4
else
  UBOOT_ENV_FILE=$4
  EXTRA_CONF_FILES_DIR=$5
fi

# check for FW image
if [[ -n "${FWIMG_FILE}" && ! -f "${FWIMG_FILE}" ]]; then
  die "firmware file '${FWIMG_FILE}' not found"
fi
# check for uboot environment file
if [[ -n "${UBOOT_ENV_FILE}" && ! -f "${UBOOT_ENV_FILE}" ]]; then
  die "uboot environment file '${UBOOT_ENV_FILE}' not found"
fi
# check for extra conf files dir
if [[ -n "${EXTRA_CONF_FILES_DIR}" && ! -d "${EXTRA_CONF_FILES_DIR}" ]]; then
  die "extra configuration files dir '${EXTRA_CONF_FILES_DIR}' not found"
fi

# ssh/scp with automatic password
SSHCOMMAND="/tmp/o2defpw ssh ${SSH_OPTS}"
SCPCOMMAND="/tmp/o2defpw scp ${SSH_OPTS}"
# check for "expect" utility
if ! command -v expect >/dev/null; then
  # OpenWrt only, no expect command, try more specific p44-openwrt-only sshpass
  SSHCOMMAND="sshpass -p onioneer ssh -y -y"
  SCPCOMMAND="sshpass -p onioneer scp -y -y"
  if ! command -v sshpass >/dev/null; then
    err "missing 'expect' or 'sshpass' command line tool - one of these must be installed for this script to work"
    info "Note: for desktop systems, 'expect' is recommended. 'sshpass' is only tested on OpenWrt"
    exit 1
  fi
  echo "sshpass utility available: assuming OpenWrt and scp with -y-y option"
fi

# Locate target Omega

OMEGA_ETH_IPV6_PREFIX="fe80::42a3:6bff:fec" # Omega2 prefix
OMEGA_BROKEN_ETH_IPV6="fe80::24c:2ff:fe08:4d0f" # Omega2S with unprogrammed Ethernet MAC

OMEGA_MATCH="s/^[0-9]+ +bytes from (${OMEGA_ETH_IPV6_PREFIX}[0-9A-Fa-f]:[0-9A-Fa-f]{1,4}|${OMEGA_BROKEN_ETH_IPV6}).*\$/\1/p"


MISSING_MAC=0
if [[ "${OMEGA2_IPV6}" == "list" ]]; then
  notice "[$(date)] Searching for Omega2(S)(+) on ${ETH_IF} via ping6 multicast (4 seconds)..."
  ping6 -c 2 -i 4 ff02::1%${ETH_IF} | grep -E "${OMEGA_ETH_IPV6_PREFIX}|${OMEGA_BROKEN_ETH_IPV6}"
  exit 0
elif [[ "${OMEGA2_IPV6}" == "ping" ]]; then
  notice "[$(date)] Searching for all IPv6 devices on ${ETH_IF} via ping6 multicast (4 seconds)..."
  ping6 -c 2 -i 4 ff02::1%${ETH_IF}
  exit 0
elif [[ "${OMEGA2_IPV6}" == "auto" ]]; then
  notice "Searching for Omega2 or Omega2S via ping6 multicast (4 seconds)..."
  OMEGA2_IPV6=""
  # use ping6 multicast to query devices
  OMEGA2_IPV6=$(ping6 -c 2 -i 4 ff02::1%${ETH_IF} | sed -n -E -e "${OMEGA_MATCH}")
  if [ ${#OMEGA2_IPV6} -gt 30 ]; then
    err "More than one Omega2 or malprogrammed Omega2S found on Ethernet interface ${ETH_IF}:"
    err "${OMEGA2_IPV6}"
    exit 1
  elif [ -z "${OMEGA2_IPV6}" ]; then
    warn "No IPv6 enabled (factory state) Omega2 or malprogrammed Omega2S found on Ethernet interface ${ETH_IF}"
    exit 1
  fi
  notice "[$(date)] Found unprogrammed Omega2 at ${OMEGA2_IPV6} on ${ETH_IF}"
elif [[ "${OMEGA2_IPV6}" == "wait" ]]; then
  notice "[$(date)] Polling for unprogrammed Omega2 or Omega2S devices via ping6 multicast..."
  OMEGA2_IPV6=""
  PINGCOUNT=0
  while [ -z "$OMEGA2_IPV6" ]; do
    # use ping6 multicast to query devices
    OMEGA2_CONNECTED=0
    PINGCOUNT=$((${PINGCOUNT}+1))
    echo -e -n "$_INFO - ping #${PINGCOUNT} ...$_N"
    MULTI_OMEGA2_IPV6=$(ping6 -c 2 -i 2 ff02::1%${ETH_IF} | sed -n -E -e "${OMEGA_MATCH}")
    for NEXT_OMEGA in ${MULTI_OMEGA2_IPV6}; do
      if [ -z ${NEXT_OMEGA} ]; then continue; fi
      # one found
      if [ "${NEXT_OMEGA}" == "${OMEGA_BROKEN_ETH_IPV6}" ]; then
        # found one with broken IP, program it
        OMEGA2_IPV6="${NEXT_OMEGA}"
        break
      elif ! grep -q "${NEXT_OMEGA}" "${PROG_LOG}"; then
        # not yet started programming this one
        OMEGA2_IPV6="${NEXT_OMEGA}"
        break
      fi
      # skip already programmed ones
      # - count them
      OMEGA2_CONNECTED=$((${OMEGA2_CONNECTED}+1))
    done
    if [ -z "${OMEGA2_IPV6}" ]; then
      echo -e -n  "$_INFO no unprogrammed Omega2 found (${OMEGA2_CONNECTED} connected) -> continue pinging$_N\n$_UP"
      sleep 2
    else
      echo ""
    fi
  done
  plain "\n[$(date)] Found unprogrammed Omega2 at ${OMEGA2_IPV6} on ${ETH_IF} - starting to program in 5 seconds..."
  sleep 5
else
  plain "[$(date)] Assuming unprogrammed Omega2 at ${OMEGA2_IPV6} on ${ETH_IF} - trying to program it now..."
fi

if [ -z "${FWIMG_FILE}" ]; then
  warn "[$(date)] No firmware specified -> no further operation"
  exit 0
fi

if [ "${OMEGA2_IPV6}" == "${OMEGA_BROKEN_ETH_IPV6}" ]; then
  warn "[$(date)] Found Omega2S with no valid factory-programmed ethernet MAC at ${OMEGA2_IPV6} on ${ETH_IF} -> will add extra steps to provision it"
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
  info "[$(date)] Found Omega2(S) with valid ethernet MAC at ${OMEGA2_IPV6} on ${ETH_IF}"
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
if grep "${OMEGA2_IPV6}" "${PROG_LOG}"; then
  # already programmed
  warn "[$(date)] Omega2 at ${OMEGA2_IPV6} has been programmed before -> do not try it again"
  sleep 2
  exit 1
fi

notice "\n\n[$(date)] ##### Start programming ${OMEGA2_LINKLOCAL}"

# try to access the omega
echo "[$(date)] Trying to ping6 omega2 at ${OMEGA2_IPV6}"
if ! ping6 -c 2 ${OMEGA2_LINKLOCAL}; then
  die "[$(date)] could not (yet) ping Omega2(S) at ${OMEGA2_IPV6} on ethernet interface ${ETH_IF}"
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


# create environment setup
rm /tmp/o2ubootenv
if [[ -n "${UBOOT_ENV_FILE}" ]]; then
  cp "${UBOOT_ENV_FILE}" /tmp/o2ubootenv
fi

# possibly add files to config
rm -r /tmp/extracfg
if [[ -n "${EXTRA_CONF_FILES_DIR}" ]]; then
  mkdir /tmp/extracfg
  cp -r ${EXTRA_CONF_FILES_DIR}/* /tmp/extracfg
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
  echo ">>>>> install uboot environment setter"
  # environment is not writable now, we need to defer programming it to when our own FW is up
  # - prepare config backup
  mkdir -p /tmp/cfgbackup/etc/init.d
  mkdir -p /tmp/cfgbackup/etc/rc.d
  cp /tmp/o2ubootenv /tmp/cfgbackup/etc
  cp /tmp/setubootenv /tmp/cfgbackup/etc/init.d
  cd /tmp/cfgbackup/etc/rc.d
  ln -s ../init.d/setubootenv S98setubootenv
fi
if [ -d /tmp/extracfg ]; then
  echo ">>>>> copying extra config"
  mkdir -p /tmp/cfgbackup
  cp -r /tmp/extracfg/* /tmp/cfgbackup
fi
if [ -d /tmp/cfgbackup ]; then
  # create config archive for sysupgrade
  echo ">>>>> creating extra config archive for sysupgrade"
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


info "[$(date)] Trying to login to Omega2 and do a uname -a ..."
COUNT=0
while ! ${SSHCOMMAND} root@${OMEGA2_LINKLOCAL} "uname -a"; do
  info "[$(date)] - not yet ready (${COUNT}), trying again in 5 seconds..."
  COUNT=$((${COUNT}+1))
  sleep 5
  if [[ ${COUNT} == 12 ]]; then
    die "repeatedly failed logging into Omega2"
  fi
done

echo "[$(date)] Copying firmware, uboot environment and bootstrap script to device ..."
# copy fw image
if ! ${SCPCOMMAND} "${FWIMG_FILE}" root@[${OMEGA2_LINKLOCAL}]:/tmp/o2firmware.bin; then
  die "copying firmware"
fi
info "[$(date)] - firmware copied ..."
# copy MAC provisioning script
if ! ${SCPCOMMAND} /tmp/provisionmac root@[${OMEGA2_LINKLOCAL}]:/tmp; then
  die "copying MAC provisioning script"
fi
info "[$(date)] - MAC provisioning script copied ..."
# copy uboot env file if there is any
if [[ -f /tmp/o2ubootenv ]]; then
  if ! ${SCPCOMMAND} /tmp/o2ubootenv root@[${OMEGA2_LINKLOCAL}]:/tmp; then
    die "copying uboot environment data"
  fi
  info "[$(date)] - custom uboot environment data copied..."
fi
# copy extra config files if there are any
if [[ -d /tmp/extracfg ]]; then
  if ! ${SCPCOMMAND} -r /tmp/extracfg root@[${OMEGA2_LINKLOCAL}]:/tmp; then
    die "copying extra config files dir"
  fi
  info "[$(date)] - extra config files dir copied..."
fi
# copy deferred uboot env provisioning script (not always used, but needed for factory-broken Omega2S)
if ! ${SCPCOMMAND} /tmp/setubootenv root@[${OMEGA2_LINKLOCAL}]:/tmp; then
  die "copying uboot environment provisioning script"
fi
info "[$(date)] - uboot environment provisioning script copied ..."
# copy bootstrap script
if ! ${SCPCOMMAND} /tmp/o2bootstrap root@[${OMEGA2_LINKLOCAL}]:/tmp; then
  die "copying updater script"
fi
info "[$(date)] - updater script copied ..."
plain "done copying files"

# Now we are reasonably sure we will be able to program this unit, remember it for not programming twice
# but do not remember the non-unique missing MAC derived IPv6, as we might need to program more of these
if [[ ${MISSING_MAC} == 0 ]]; then
  echo "${OMEGA2_IPV6}" >>"${PROG_LOG}"
fi

# actually execute the updater script
info "[$(date)] - Executing the updater script"
# Note: is expected to not return ok, because flashing kills ssh connection
${SSHCOMMAND} root@${OMEGA2_LINKLOCAL} /tmp/o2bootstrap
info "(executing the updater script returned $?)"
info "[$(date)] - updater script is flashing device now, with ssh connection terminated..."

# just wait a bit
sleep 5

if [[ ${MISSING_MAC} != 0 ]]; then
  warn "[$(date)] ### the device initially had a broken MAC and was re-provisioned -> duplicate checking is not possible, wait >=3min before restarting"
  # special exit code to inform caller to wait >=3min before calling again
  exit 2
fi

notice "[$(date)] ${OMEGA2_LINKLOCAL} DONE SO FAR!"
warn "Make sure not to disconnect Omega2 from power until flashing is complete!"
notice "===========================================\n\n\n"
exit 0
