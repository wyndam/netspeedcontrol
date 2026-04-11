# netspeedcontrol

ImmortalWrt/OpenWrt LuCI plugin for scheduled device internet control.

The package source is in `luci-app-netspeedcontrol/`.

## Latest IPK

The latest packaged build is:

```sh
dist/luci-app-netspeedcontrol_0.1.0-27_all.ipk
```

Install it on the router with:

```sh
opkg install /tmp/luci-app-netspeedcontrol_0.1.0-27_all.ipk
```

## Main Features

- Chinese LuCI interface.
- Select online devices and control by MAC address.
- Scheduled block or lightweight bandwidth limit rules.
- nftables/firewall4 based enforcement.
- Extra prerouting/input/forward blocking for stricter disconnect behavior.
- Optional Chinese summary logs in the LuCI page.

## Build

For local test packaging:

```sh
./build-ipk.sh
```

For SDK packaging, put `luci-app-netspeedcontrol/` into the ImmortalWrt/OpenWrt SDK `package/` directory or a custom feed.
