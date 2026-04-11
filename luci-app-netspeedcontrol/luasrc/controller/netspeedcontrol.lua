module("luci.controller.netspeedcontrol", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/netspeedcontrol") then
		return
	end

	entry({"admin", "network", "netspeedcontrol"}, cbi("netspeedcontrol"), _("设备上网控制"), 91).dependent = true
end
