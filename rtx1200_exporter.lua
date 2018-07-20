#!./upload.sh
--[[
Prometheus exporter for RTX1200

lua /rtx1200_exporter.lua
show status lua

schedule at 1 startup * lua /rtx1200_exporter.lua 
]]
-- vim:fenc=cp932

-- snmp

tinysnmp = {
	encodeobj = function (tag, value)
		return string.char(tag, #value) .. value
	end,

	encodeber = function (n)
		local ret = ""
		local v = n
		repeat
			b = bit.band(v, 127)
			if v == n then
				ret = string.char(b)
			else
				ret = string.char(bit.bor(b, 128)) .. ret
			end
			v = bit.bshift(v, -7)
		until v == 0
		return ret
	end,

	encodeoid = function (oid)
		local encoded = ""

		local nums = { string.split(oid, /\./) }
		encoded = encoded .. string.char(tonumber(nums[1] * 40 + tonumber(nums[2])))
		for i = 3, #nums do
			local ber = tinysnmp.encodeber(tonumber(nums[i]))
			encoded = encoded .. ber
		end
		return encoded
	end,

	getrequest = function (oid, requestid)
		if requestid > 255 then
			error("requestid must be <= 255")
		end

		local encodeobj = tinysnmp.encodeobj
		local encodedoid = tinysnmp.encodeoid(oid)
		local message =
			encodeobj(0x30, -- sequence
				"\002\001\001".. -- integer version 1 (=2c)
				"\004\006public".. -- octet string 6 bytes "public"
				encodeobj(0xa0, -- context pdu tag 1 19bytes
					encodeobj(0x02, string.char(requestid)).. -- integer request id 1
					"\002\001\000".. -- integer error-status 0
					"\002\001\000".. -- integer error-index 0
					encodeobj(0x30, -- sequence verbindlist
						encodeobj(0x30, -- sequence varbind
							encodeobj(0x06, encodedoid).. -- oid
							"\005\000" -- null
						)
					)
				)
			)
		return message
	end,

	parseresponse = function (message)
		local pos = 1
		local tag = string.byte(message, pos)
		if not tag == 0x30 then return nil, "unexpected tag" end

		pos = pos + 2
		local tag, len, ver = string.byte(message, pos, pos+3)
		if not (tag == 0x02 and len == 0x01 and ver == 0x01) then
			return nil, string.format("unexpected version tag:%x len:%x, ver:%x", tag, len, version)
		end

		pos = pos + len + 2
		local tag, len = string.byte(message, pos, pos+1)
		pos = pos + 2
		-- ununsed
		--  community = string.sub(message, pos, pos+len-1)

		pos = pos + len
		local tag, len = string.byte(message, pos, pos+1)
		if not tag == 0xa2 then
			return nil, string.format("unexpected tag %x (expected 0xa2/get-response)", tag)
		end

		pos = pos + 2
		local tag, len, requestid = string.byte(message, pos, pos+2)
		if not (tag == 0x02 and len == 0x01) then
			return nil, string.format("unexpected request id tag:%x len:%x, val:%x", tag, len, requestid)
		end

		pos = pos + 2 + len
		local tag, len, errorstatus = string.byte(message, pos, pos+2)
		if not (tag == 0x02 and len == 0x01) then
			return nil, string.format("unexpected error status tag:%x len:%x, val:%x", tag, len, requestid)
		end

		pos = pos + 2 + len
		local tag, len, errorindex = string.byte(message, pos, pos+2)
		if not (tag == 0x02 and len == 0x01) then
			return nil, string.format("unexpected error index tag:%x len:%x, val:%x", tag, len, requestid)
		end

		pos = pos + 2 + len
		local tag = string.byte(message, pos)
		if not tag == 0x30 then
			return nil, string.format("unexpected tag for varbindlist %x", tag)
		end

		pos = pos + 2
		local tag = string.byte(message, pos)
		if not tag == 0x30 then
			return nil, string.format("unexpected tag for varbind %x", tag)
		end

		pos = pos + 2
		local tag, len = string.byte(message, pos, pos+1)
		pos = pos + 2
		local encodedoid = string.sub(message, pos, pos+len-1)

		pos = pos + len
		local tag, len = string.byte(message, pos, pos+1)
		pos = pos + 2

		local tags = {}
		tags[0x41] = function () -- counter
			ret = 0
			for n = 0, len-1 do
				ret = bit.bor(bit.bshift(ret, 8), string.byte(message, pos + n))
			end
			return ret
		end
		tags[0x42] = tags[0x41] -- gauge
		tags[0x43] = tags[0x41] -- timeticks

		if not tags[tag] then
			return nil, string.format("unsupported value tag:%x", tag)
		end
		return tags[tag](), nil, requestid
	end
}

snmpmetrics = {
	sysUpTimeInstance = {
		"counter",
		{ oid = "1.3.6.1.2.1.1.3.0", label = '', },
	},
	ifOutDiscards = {
		"counter",
		{ oid = "1.3.6.1.2.1.2.2.1.19.1", label = '{if="1"}', },
		{ oid = "1.3.6.1.2.1.2.2.1.19.2", label = '{if="2"}', },
	},
	ifInDiscards = {
		"counter",
		{ oid = "1.3.6.1.2.1.2.2.1.13.1", label = '{if="1"}', },
		{ oid = "1.3.6.1.2.1.2.2.1.13.2", label = '{if="2"}', },
	},
	ifOutErrors = {
		"counter",
		{ oid = "1.3.6.1.2.1.2.2.1.20.1", label = '{if="1"}', },
		{ oid = "1.3.6.1.2.1.2.2.1.20.2", label = '{if="2"}', },
	},
	ifInErrors = {
		"counter",
		{ oid = "1.3.6.1.2.1.2.2.1.14.1", label = '{if="1"}', },
		{ oid = "1.3.6.1.2.1.2.2.1.14.2", label = '{if="2"}', },
	},
	ifInUnknownProtos = {
		"counter",
		{ oid = "1.3.6.1.2.1.2.2.1.15.1", label = '{if="1"}', },
		{ oid = "1.3.6.1.2.1.2.2.1.15.2", label = '{if="2"}', },
	},
	ifOutUcastPkts = {
		"counter",
		{ oid = "1.3.6.1.2.1.2.2.1.17.1", label = '{if="1"}', },
		{ oid = "1.3.6.1.2.1.2.2.1.17.2", label = '{if="2"}', },
	},
	ifInUcastPkts = {
		"counter",
		{ oid = "1.3.6.1.2.1.2.2.1.11.1", label = '{if="1"}', },
		{ oid = "1.3.6.1.2.1.2.2.1.11.2", label = '{if="2"}', },
	},
	ifInNUcastPkts = {
		"counter",
		{ oid = "1.3.6.1.2.1.2.2.1.12.1", label = '{if="1"}', },
		{ oid = "1.3.6.1.2.1.2.2.1.12.2", label = '{if="2"}', },
	},
	ifOutNUcastPkts = {
		"counter",
		{ oid = "1.3.6.1.2.1.2.2.1.18.1", label = '{if="1"}', },
		{ oid = "1.3.6.1.2.1.2.2.1.18.2", label = '{if="2"}', },
	},
}

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

			-- get metrics from snmp
			local udp = rt.socket.udp()
			local res, err = udp:setpeername("127.0.0.1",  161)
			udp:settimeout(1)
			local ok, err = pcall(function ()
				-- send snmp get request
				local requestids = {}
				for name, v in pairs(snmpmetrics) do
					local type = v[1]
					for n = 2, #v do
						local requestid = #requestids + 1
						requestids[requestid] = 0
						local oid = v[n].oid
						local req = tinysnmp.getrequest(oid, requestid)
						-- print(string.format("send %s", rt.mime.qp(req)))
						res, err = udp:send(req)
						if err then
							error(err)
						end
						v[n].requestid = requestid
					end
				end

				-- receive response
				for name, v in pairs(snmpmetrics) do
					for n = 2, #v do
						dgram, err = udp:receive()
						if err then
							error(err)
						end

						value, err, requestid = tinysnmp.parseresponse(dgram)
						if err then
							error(err)
						end
						requestids[requestid] = value
					end
				end

				-- print snmp metrics
				for name, v in pairs(snmpmetrics) do
					local type = v[1]
					sent, err = control:send($"# TYPE ${name} ${type}\n")
					if err then error(err) end
					for n = 2, #v do
						local value = requestids[v[n].requestid]
						sent, err = control:send($"${name}${v[n].label} ${value}\n")
						if err then error(err) end
					end
				end
			end)
			udp:close()
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
end
