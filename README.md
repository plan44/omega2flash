# omega2flash - flash custom firmware to Omega2/2S(+)

## About

This bash script can be used to flash Onion Omega2(+) or Omega2S(+) factory state devices with custom firmware with no manual intervention except for connecting power and Ethernet.

The key is that the factory firmware of the Omega2(S) has IPv6 running on the ethernet by default, with a link local address derived from the Omega2's MAC. And as IPv6 easily allows to discover device's IPv6 on the local link (e.g. ping6 ff02::1%en7), the script can find the devices, send firmware via scp, and launch sysupgrade via ssh.

The script detects Omega2S from an early production batch which don't have a valid ethernet MAC programmed and automatically provisions the correct MAC address.

The script also allows to provision the uboot environment. This only works if the flashed custom firmware includes the fw_setenv utility and have a writable uboot environment partition.

As it is now, the script only programs one device at a time. It can be run in a loop, as it remembers programmed device's IPv6 to avoid programming the same device twice.

The script can also program Omega2 found on wireless network segments, however it *can not* automatically connect to Omega2 hotspots.

## Usage

    omega2flash <ethernet-if> <auto|wait|omega2_ipv6|list|ping> [<firmware.bin> [<uboot-env-file>] [<extra-conf-files-dir]]"

Where:

- **ethernet-if** is the name of the ethernet interface that directly connects to the network segment where the Omega2 devices are connected. On Linux systems, this is usually "eth0" (use `ifconfig` or `ip link` for a list), on macos it's something like "en2" (use `networksetup -listallhardwareports` for a list)
- **auto** as second parameter will automatically look for and flash a single Omega2. It will exit when more than one or no Omega2 is found.
- **wait** similar to *auto*, but script will wait and poll the ethernet interface until at least one unprogrammed Omega2 is found. There can be multiple unprogrammed Omega2s already connected, the "wait" mode just processes the first unprogrammed one it finds. Note that a temp file (`/tmp/flashed_omega2_ipv6`) is used to record all IPv6 addresses of already programmed devices. In wait mode, the *omega2flash* script can be used in a loop to program batches of devices.
- **IPv6 address** can be specified to flash a specific Omega2 via its IPv6 link local address
- **list** will list the link local IPv6 addresses of all Omega2 devices found on the network segment as specified with *ethernet-if*.
- **ping** will list the link local IPv6 addresses of all devices found on the network segment as specified with *ethernet-if*.
- **\<firmware.bin\>** must be a OpenWrt firmware image for Omega2(S)(+) as produced by the OpenWrt build system. If none is specified, the script will exit after looking for programmable Omega2 on the network and do nothing.
- **\<uboot-env-file\>** can be optionally specified to also set a specific uboot environment while flashing the Omega2. The custom firmware must include the fw_setenv utility and have a writable uboot environment partition for this to work. As factory state Omega2 don't have a writable uboot environment, this is done via a temporary startup script overlayed to the custom firmware and running when the custom firmware runs the first time.
The *\<uboot-env-file\>* must contain lines starting with a uboot environment variable name, followed by some whitespace, followed by the value to assign.
- **\<extra-conf-files-dir\>** can be optionally specified to add extra configuration files. The contents of this directory reflects the root file system of the device. Ususally, it will contain some `etc/uci-defaults/...` and/or `etc/config/...` files.

Note: The script generates ANSI colored output when run from a terminal. Set `NO_COLOR` environment variable to prevent colors, or set `FORCE_COLOR` to output color even if stdout is not a terminal (e.g. to create logfiles with color included).

## Contributions

...are welcome! There's a lot that could be improved. Pull requests and comments can be posted on [github](https://github.com/plan44/omega2flash.git)

## License

The omega2flash script is MIT licensed.

## Copyright

(c) 2017-2022 by [plan44.ch/luz](https://plan44.ch)
