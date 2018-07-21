#!./upload.sh
--[[
Prometheus exporter for RTX1200

lua /rtx1200_exporter.lua
show status lua

schedule at 1 startup * lua /rtx1200_exporter.lua 
]]
-- vim:fenc=cp932


-- start prometheus exporter

tcp = rt.socket.tcp()
tcp:setoption("reuseaddr", true)
res, err = tcp:bind("*", 9100)
if not res and err then
	rt.syslog("NOTICE", err)
	os.exit(1)
end
res, err = tcp:listen()
if not res and err then
	rt.syslog("NOTICE", err)
	os.exit(1)
end

while 1 do
	local control = assert(tcp:accept())

	local raddr, rport = control:getpeername()

	control:settimeout(30)
	local ok, err = pcall(function ()
		-- get request line
		local request, err, partial = control:receive()
		if err then error(err) end
		-- get request headers
		while 1 do
			local header, err, partial = control:receive()
			if err then error(err) end
			if header == "" then
				-- end of headers
				break
			else
				-- just ignore headers
			end
		end

		if string.find(request, "GET /metrics ") == 1 then
			local sent, err = control:send(
				"HTTP/1.0 200 OK\r\n"..
				"Connection: close\r\n"..
				"Content-Type: text/plain\r\n"..
				"\r\n"..
				"# Collecting metrics...\n"
			)
			if err then error(err) end

			local ok, result = rt.command("show environment")
			if not ok then error("command failed") end
			local cpu5sec, cpu1min, cpu5min, memused = string.match(result, /CPU:\s*(\d+)%\(5sec\)\s*(\d+)%\(1min\)\s*(\d+)%\(5min\)\s*メモリ:\s*(\d+)% used/)
			local temperature = string.match(result, /筐体内温度\(.*\): (\d+)/)
			local luacount = collectgarbage("count")

			local sent, err = control:send(
				"# TYPE yrhCpuUtil5sec gauge\n"..
				$"yrhCpuUtil5sec ${cpu5sec}\n"..
				"# TYPE yrhCpuUtil1min gauge\n"..
				$"yrhCpuUtil1min ${cpu1min}\n"..
				"# TYPE yrhCpuUtil5min gauge\n"..
				$"yrhCpuUtil5min ${cpu5min}\n"..
				"# TYPE yrhInboxTemperature gauge\n"..
				$"yrhInboxTemperature ${temperature}\n"..
				"# TYPE yrhMemoryUtil gauge\n"..
				$"yrhMemoryUtil ${memused}\n"..
				"# TYPE yrhLuaCount gauge\n"..
				$"yrhLuaCount ${luacount}\n"
			)
			if err then error(err) end

			local sent, err = control:send(
				"# TYPE ifOutOctets counter\n"..
				"# TYPE ifInOctets counter\n"
			)
			if err then error(err) end

			for n = 1, 3 do
				local ok, result = rt.command($"show status lan${n}")
				if not ok then error("command failed") end
				local txpackets, txoctets = string.match(result, /送信パケット:\s*(\d+)\s*パケット\((\d+)\s*オクテット\)/)
				local rxpackets, rxoctets = string.match(result, /受信パケット:\s*(\d+)\s*パケット\((\d+)\s*オクテット\)/)
				local sent, err = control:send(
					$"ifOutOctets{if=\"${n}\"} ${txoctets}\n"..
					$"ifInOctets{if=\"${n}\"} ${rxoctets}\n"..
					$"ifOutPkts{if=\"${n}\"} ${txpackets}\n"..
					$"ifInPkts{if=\"${n}\"} ${rxpackets}\n"
				)
				if err then error(err) end
			end

			local ok, result = rt.command("show ip connection summary")
			local v4session, v4channel = string.match(result, /Total Session: (\d+)\s+Total Channel:\s*(\d+)/)

			local ok, result = rt.command("show ipv6 connection summary")
			local v6session, v6channel = string.match(result, /Total Session: (\d+)\s+Total Channel:\s*(\d+)/)

			local sent, err = control:send(
				"# TYPE ipSession counter\n"..
				$"ipSession{proto=\"v4\"} ${v4session}\n"..
				$"ipSession{proto=\"v6\"} ${v6session}\n"..
				"# TYPE ipChannel counter\n"..
				$"ipChannel{proto=\"v4\"} ${v4channel}\n"..
				$"ipChannel{proto=\"v6\"} ${v6channel}\n"
			)
			if err then error(err) end

			local ok, result = rt.command("show status dhcp")
			local dhcptotal = string.match(result, /全アドレス数:\s*(\d+)/)
			local dhcpexcluded = string.match(result, /除外アドレス数:\s*(\d+)/)
			local dhcpassigned = string.match(result, /割り当て中アドレス数:\s*(\d+)/)
			local dhcpavailable = string.match(result, /利用[^:]+?アドレス数:\s*(\d+)/)
			local sent, err = control:send(
				"# TYPE ipDhcp gauge\n"..
				$"ipDhcp{} ${dhcptotal}\n"..
				$"ipDhcp{type=\"excluded\"} ${dhcpexcluded}\n"..
				$"ipDhcp{type=\"assigned\"} ${dhcpassigned}\n"..
				$"ipDhcp{type=\"available\"} ${dhcpavailable}\n"
			)
			if err then error(err) end

		elseif string.find(request, "GET / ") == 1 then
			local sent, err = control:send(
				"HTTP/1.0 200 OK\r\n"..
				"Connection: close\r\n"..
				"Content-Type: text/html\r\n"..
				"\r\n"..
				"<!DOCTYPE html><title>RTX1200 Prometheus exporter</title><p><a href='/metrics'>/metrics</a>"
			)
		else
			local sent, err = control:send(
				"HTTP/1.0 404 Not Found\r\n"..
				"Connection: close\r\n"..
				"Content-Type: text/plain\r\n"..
				"\r\n"..
				"Not Found"
			)
			if err then error(err) end
		end
	end)
	if not ok then
		rt.syslog("INFO", "failed to response " .. err)
	end
	control:close()
	collectgarbage("collect")
end
