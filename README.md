# netspeedcontrol

这是一个用于 ImmortalWrt/OpenWrt 的 LuCI 插件，用来按设备控制上网时间、断网和轻量限速。

插件源码在 `luci-app-netspeedcontrol/` 目录里。

## 最新安装包

最新打包好的 IPK 文件是：

```sh
dist/luci-app-netspeedcontrol_0.1.0-28_all.ipk
```

把这个文件上传到路由器的 `/tmp` 目录后安装：

```sh
opkg install /tmp/luci-app-netspeedcontrol_0.1.0-28_all.ipk
```

如果 LuCI 菜单没有马上刷新，可以重启 LuCI Web 服务：

```sh
/etc/init.d/uhttpd restart
```

## 主要功能

- 中文 LuCI 管理界面。
- 支持从在线设备列表里选择设备。
- 默认按 MAC 地址控制设备。
- 支持黑名单模式：限制黑名单列表里的设备。
- 支持白名单模式：只允许白名单列表里的设备上网，黑名单列表不会被复用。
- 支持按时间段断网。
- 支持轻量级上传/下载限速。
- 基于 firewall4/nftables 下发规则。
- 增加 prerouting/input/forward 多链拦截，尽量减少代理、OpenClash、长连接绕过。
- 支持可选中文拦截日志，并可直接在 LuCI 页面里查看。

## 本地打包

在本仓库目录下执行：

```sh
./build-ipk.sh
```

## SDK 编译

如果要放进 ImmortalWrt/OpenWrt SDK 编译，把 `luci-app-netspeedcontrol/` 目录放进 SDK 的 `package/` 目录，或者放进自定义 feed，然后在 SDK 里编译该包即可。

## 说明

- 当前限速是 nftables `limit ... drop` 轻量限流，不是完整 QoS 整形。
- MAC 规则需要路由器能从 DHCP、ARP 或 IPv6 邻居表解析出设备当前地址。
- 白名单模式会更严格，建议先把当前管理设备加入白名单，避免把自己临时断开。
- 如果设备仍然能绕过限制，请检查路由器是否开启了流量分载、硬件分载或代理旁路规则。
