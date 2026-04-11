local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"
local m, s, o
local APP_VERSION = "0.1.0-28"
local online_devices

local function normalize_mac(mac)
	if not mac then
		return ""
	end

	return tostring(mac):upper()
end

local function normalize_name(name)
	if not name or name == "*" or name == "?" then
		return ""
	end

	return tostring(name)
end

local function add_device(devices, seen, mac, ip, name)
	local item

	mac = normalize_mac(mac)
	ip = ip or ""
	name = normalize_name(name)

	if mac == "" then
		return
	end

	item = seen[mac]
	if item then
		if item.ip == "" and ip ~= "" then
			item.ip = ip
		end

		if item.name == "" and name ~= "" then
			item.name = name
		end

		return
	end

	item = {
		mac = mac,
		ip = ip,
		name = name
	}

	seen[mac] = item
	table.insert(devices, item)
end

local function load_online_devices()
	local devices = {}
	local seen = {}
	local fp

	fp = io.open("/tmp/dhcp.leases", "r")
	if fp then
		for line in fp:lines() do
			local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
			add_device(devices, seen, mac, ip, name)
		end

		fp:close()
	end

	fp = io.open("/proc/net/arp", "r")
	if fp then
		local is_first = true

		for line in fp:lines() do
			local ip, mac

			if is_first then
				is_first = false
			else
				ip, _, _, mac = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
				if mac and mac ~= "00:00:00:00:00:00" then
					add_device(devices, seen, mac, ip, "")
				end
			end
		end

		fp:close()
	end

	table.sort(devices, function(a, b)
		local av = a.name ~= "" and a.name or (a.ip ~= "" and a.ip or a.mac)
		local bv = b.name ~= "" and b.name or (b.ip ~= "" and b.ip or b.mac)
		return av < bv
	end)

	return devices
end

local function device_label(device)
	local parts = {}

	if device.name ~= "" then
		parts[#parts + 1] = device.name
	end

	if device.ip ~= "" then
		parts[#parts + 1] = device.ip
	end

	if device.mac ~= "" then
		parts[#parts + 1] = device.mac
	end

	return table.concat(parts, " / ")
end

local function saved_device_label(mac)
	return translate("当前已保存设备") .. " / " .. normalize_mac(mac)
end

local function has_online_device(mac)
	local item

	mac = normalize_mac(mac)
	if mac == "" then
		return false
	end

	for _, item in ipairs(online_devices or {}) do
		if item.mac == mac then
			return true
		end
	end

	return false
end

local function ensure_option_value(option, value, label)
	local key

	if not value or value == "" then
		return
	end

	for _, key in ipairs(option.keylist or {}) do
		if key == value then
			return
		end
	end

	option:value(value, label)
end

local function load_recent_logs()
	local data

	data = sys.exec([[tail -n 80 /tmp/netspeedcontrol-events.log 2>/dev/null]])
	data = data or ""
	data = data:gsub("\r\n", "\n")

	return data
end

local function apply_now()
	sys.call("uci commit netspeedcontrol >/dev/null 2>&1")
	sys.call("/etc/init.d/netspeedcontrol reload >/tmp/netspeedcontrol.log 2>&1 || /usr/bin/netspeedcontrol.sh apply >/tmp/netspeedcontrol.log 2>&1")
end

local function persist_rule_mac(map, section)
	local current_mac
	local selected_mac
	local custom_mac
	local final_mac

	current_mac = normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")
	selected_mac = normalize_mac(map:formvalue("cbid.netspeedcontrol." .. section .. ".mac"))
	custom_mac = normalize_mac(map:formvalue("cbid.netspeedcontrol." .. section .. "._custom_mac"))

	if custom_mac ~= "" then
		final_mac = custom_mac
	elseif selected_mac ~= "" then
		final_mac = selected_mac
	else
		final_mac = current_mac
	end

	if final_mac ~= "" then
		uci:set("netspeedcontrol", section, "mac", final_mac)
		uci:set("netspeedcontrol", section, "target_type", "mac")
		uci:delete("netspeedcontrol", section, "ip")
	end
end

online_devices = load_online_devices()

m = Map("netspeedcontrol", translate("设备上网控制"))
m.description = translate("现在默认只按 MAC 地址控制设备，不再需要选择匹配方式，也不需要手动填写 IP。黑名单模式只读取“黑名单规则列表”；白名单模式只读取“白名单设备列表”，两张列表互不共用。断网模式现在会更前置地拦截设备流量，尽量覆盖普通上网、路由器本机代理流量，以及像微信这类更顽固的长连接。拦截日志默认关闭；开启后，插件会按分钟生成中文汇总日志，记录设备尝试联网但被拦截的情况。") ..
	"<br /><strong>" .. translate("当前插件版本：") .. APP_VERSION .. "</strong>"

function m.on_after_commit(self)
	apply_now()
end

s = m:section(TypedSection, "globals", translate("全局设置"))
s.anonymous = true

o = s:option(DummyValue, "_version", translate("插件版本"))
o.rawhtml = true
o.cfgvalue = function()
	return "<strong>" .. APP_VERSION .. "</strong>"
end

o = s:option(Flag, "enabled", translate("启用服务"))
o.rmempty = false

o = s:option(ListValue, "policy_mode", translate("工作模式"))
o:value("blacklist", translate("黑名单模式：限制列表里的设备"))
o:value("whitelist", translate("白名单模式：只允许列表里的设备上网"))
o.default = "blacklist"
o.rmempty = false
o.description = translate("黑名单模式：只限制黑名单列表里的设备。白名单模式：只允许白名单列表里的设备上网，其他设备都会被拦截。")

o = s:option(Flag, "log_enabled", translate("记录拦截日志"))
o.rmempty = false
o.default = "0"
o.description = translate("默认关闭。开启后会按分钟生成少量中文汇总日志，性能影响较小。开启后可以直接在当前页面底部查看最近日志。")

s = m:section(TypedSection, "rule", translate("黑名单规则列表"))
s.addremove = true
s.anonymous = true
s.template = "cbi/tblsection"
s.description = translate("这里只用于黑名单模式。启用的设备会按下面的控制方式和时间段被限制；白名单模式不会读取这里的设备。")

o = s:option(Flag, "enabled", translate("启用"))
o.rmempty = false

o = s:option(Value, "name", translate("规则名称"))
o.placeholder = "KidPhone"
o.rmempty = false

o = s:option(ListValue, "mac", translate("受控设备"))
o:value("", translate("请选择在线设备"))
o.description = translate("这里保存的就是实际生效的 MAC 地址。优先从在线设备里直接选择，更稳。")
o.rmempty = false

for _, device in ipairs(online_devices) do
	o:value(device.mac, device_label(device))
end

function o.cfgvalue(self, section)
	local current_mac = normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")

	if current_mac ~= "" then
		if not has_online_device(current_mac) then
			ensure_option_value(self, current_mac, saved_device_label(current_mac))
		end
		return current_mac
	end

	return ""
end

function o.write(self, section, value)
	value = normalize_mac(value)

	if value ~= "" then
		uci:set("netspeedcontrol", section, "mac", value)
		uci:set("netspeedcontrol", section, "target_type", "mac")
		uci:delete("netspeedcontrol", section, "ip")
	else
		uci:delete("netspeedcontrol", section, "mac")
		uci:delete("netspeedcontrol", section, "ip")
	end
end

o = s:option(Value, "_custom_mac", translate("手动填写 MAC"))
o.datatype = "macaddr"
o.placeholder = "AA:BB:CC:DD:EE:FF"
o.description = translate("如果目标设备当前不在在线列表里，可以在这里手动填。手动填写会覆盖上面选择的设备。")

function o.cfgvalue(self, section)
	local current_mac = normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")

	if current_mac ~= "" and not has_online_device(current_mac) then
		return current_mac
	end

	return ""
end

function o.write(self, section, value)
	value = normalize_mac(value)

	if value ~= "" then
		uci:set("netspeedcontrol", section, "mac", value)
		uci:set("netspeedcontrol", section, "target_type", "mac")
		uci:delete("netspeedcontrol", section, "ip")
	end
end

function o.remove(self, section)
end

o = s:option(ListValue, "mode", translate("控制方式"))
o:value("block", translate("在设定时间内断网"))
o:value("limit", translate("在设定时间内限速"))
o.default = "block"
o.rmempty = false

o = s:option(Value, "weekdays", translate("生效星期"))
o.placeholder = "1 2 3 4 5"
o.description = translate("使用 1-7 表示周一到周日，留空表示每天都生效。")

o = s:option(Value, "start_time", translate("开始时间"))
o.placeholder = "21:00"
o.datatype = "string"
o.rmempty = false
o.description = translate("使用 24 小时制，例如 21:00。")

o = s:option(Value, "stop_time", translate("结束时间"))
o.placeholder = "07:00"
o.datatype = "string"
o.rmempty = false
o.description = translate("如果结束时间早于开始时间，则表示跨天生效。")

o = s:option(Value, "up_kbit", translate("上传限速（kbit/s）"))
o.placeholder = "256"
o.datatype = "uinteger"
o:depends("mode", "limit")

o = s:option(Value, "down_kbit", translate("下载限速（kbit/s）"))
o.placeholder = "1024"
o.datatype = "uinteger"
o:depends("mode", "limit")

function s.parse(self, ...)
	TypedSection.parse(self, ...)
	uci:foreach("netspeedcontrol", "rule", function(rule)
		persist_rule_mac(self.map, rule[".name"])
	end)
end

s = m:section(TypedSection, "allow", translate("白名单设备列表"))
s.addremove = true
s.anonymous = true
s.template = "cbi/tblsection"
s.description = translate("这里只用于白名单模式。启用的设备允许上网，其他设备都会被拦截。建议先把当前管理设备加入白名单，再切换到白名单模式。")

o = s:option(Flag, "enabled", translate("启用"))
o.rmempty = false

o = s:option(Value, "name", translate("设备名称"))
o.placeholder = "MyPhone"
o.rmempty = false

o = s:option(ListValue, "mac", translate("允许上网的设备"))
o:value("", translate("请选择在线设备"))
o.description = translate("这里保存的是白名单设备的 MAC 地址。")
o.rmempty = false

for _, device in ipairs(online_devices) do
	o:value(device.mac, device_label(device))
end

function o.cfgvalue(self, section)
	local current_mac = normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")

	if current_mac ~= "" then
		if not has_online_device(current_mac) then
			ensure_option_value(self, current_mac, saved_device_label(current_mac))
		end
		return current_mac
	end

	return ""
end

function o.write(self, section, value)
	value = normalize_mac(value)

	if value ~= "" then
		uci:set("netspeedcontrol", section, "mac", value)
		uci:set("netspeedcontrol", section, "target_type", "mac")
		uci:delete("netspeedcontrol", section, "ip")
	else
		uci:delete("netspeedcontrol", section, "mac")
		uci:delete("netspeedcontrol", section, "ip")
	end
end

o = s:option(Value, "_custom_mac", translate("手动填写 MAC"))
o.datatype = "macaddr"
o.placeholder = "AA:BB:CC:DD:EE:FF"
o.description = translate("如果允许上网的设备当前不在在线列表里，可以在这里手动填。手动填写会覆盖上面选择的设备。")

function o.cfgvalue(self, section)
	local current_mac = normalize_mac(uci:get("netspeedcontrol", section, "mac") or "")

	if current_mac ~= "" and not has_online_device(current_mac) then
		return current_mac
	end

	return ""
end

function o.write(self, section, value)
	value = normalize_mac(value)

	if value ~= "" then
		uci:set("netspeedcontrol", section, "mac", value)
		uci:set("netspeedcontrol", section, "target_type", "mac")
		uci:delete("netspeedcontrol", section, "ip")
	end
end

function o.remove(self, section)
end

function s.parse(self, ...)
	TypedSection.parse(self, ...)
	uci:foreach("netspeedcontrol", "allow", function(rule)
		persist_rule_mac(self.map, rule[".name"])
	end)
end

s = m:section(SimpleSection, translate("最近拦截日志"))
s.anonymous = true

o = s:option(DummyValue, "_log_view", "")
o.rawhtml = true

function o.cfgvalue()
	local enabled
	local logs

	enabled = uci:get("netspeedcontrol", "globals", "log_enabled") or "0"
	if enabled ~= "1" then
		return "<em>" .. util.pcdata(translate("当前未开启“记录拦截日志”。开启后保存并应用，再回到这里就能看到中文的最近拦截记录。")) .. "</em>"
	end

	logs = load_recent_logs()
	if logs == "" then
		return "<em>" .. util.pcdata(translate("暂时还没有可显示的日志。日志按分钟汇总一次，你可以先让受控设备尝试访问网络，等一小会儿再刷新本页面。")) .. "</em>"
	end

	return "<div style=\"width:100%; overflow-x:auto;\">"
		.. "<textarea class=\"cbi-input-textarea\" style=\"display:block; width:100%; min-width:980px; min-height:320px; box-sizing:border-box; font-family:monospace;\" readonly=\"readonly\">"
		.. util.pcdata(logs)
		.. "</textarea></div>"
end

return m
