# luci-app-netspeedcontrol

ImmortalWrt/OpenWrt LuCI plugin for scheduled device network control.

This package was built and tested for ImmortalWrt 24.10.2 with firewall4/nftables.

## Features

- Chinese LuCI page under Network -> Device Internet Control.
- Select an online client from the router's DHCP/ARP list.
- Control clients by MAC address, resolving current IPv4/IPv6 addresses automatically.
- Scheduled block mode for internet access.
- Lightweight upload/download limit mode using nftables policing.
- Extra input-chain and prerouting-chain blocking to reduce proxy/OpenClash and long-connection bypasses.
- Optional Chinese summary logs in the LuCI page.

## Install

The latest locally packaged IPK is included at:

```sh
dist/luci-app-netspeedcontrol_0.1.0-27_all.ipk
```

Copy it to the router and install:

```sh
opkg install /tmp/luci-app-netspeedcontrol_0.1.0-27_all.ipk
```

Then restart LuCI if the menu does not refresh:

```sh
/etc/init.d/uhttpd restart
```

## Build

For local test packaging from this repository:

```sh
./build-ipk.sh
```

For normal ImmortalWrt/OpenWrt SDK packaging, put `luci-app-netspeedcontrol/` into the SDK `package/` directory or a custom feed, then compile the package from the SDK.

## Notes

- Bandwidth limiting uses nftables `limit ... drop`, which is lightweight policing, not full QoS shaping.
- MAC rules depend on the router being able to resolve the client's current addresses from DHCP, ARP, or IPv6 neighbor information.
- If a client can still bypass rules, check flow offloading/hardware offloading and proxy bypass behavior on the router.
