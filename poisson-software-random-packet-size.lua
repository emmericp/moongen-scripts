local mg      = require "moongen"
local memory  = require "memory"
local device  = require "device"
local ts      = require "timestamping"
local stats   = require "stats"
local hist    = require "histogram"
local log     = require "log"
local limiter = require "software-ratecontrol"

local PKT_SIZE	= 60

function configure(parser)
	parser:argument("txDev", "Device to transmit from."):convert(tonumber)
	parser:option("-r --rate", "Transmit rate in Mpps."):default(1):convert(tonumber)
	parser:option("-t --threads", "Number of threads."):default(1):convert(tonumber)
end

function master(cfg)
	local txDev = device.config{
		port = cfg.txDev,
		txQueues = cfg.threads
	}
	device.waitForLinks()
	stats.startStatsTask{txDevices = {txDev}}
	for i = 1, cfg.threads do
		local rateLimiter = limiter:new(txDev:getTxQueue(i - 1), "poisson", 1000 / cfg.rate / cfg.threads)
		mg.startTask("loadSlave", rateLimiter, txDev, i)
	end
	mg.waitForTasks()
end

function loadSlave(rateLimiter, txDev, threadId)
	local mem = memory.createMemPool(function(buf)
		-- set packet template here
		buf:getUdp4Packet():fill{
			ethSrc = txDev,
			ethDst = "12:34:56:78:9a:bc",
			ip4Src = "10.0.1.1",
			ip4Dst = "10.0.2.1",
			udpSrc = 1234,
			udpDst = 5678,
			pktLength = 60
		}
	end)
	local bufs = mem:bufArray(128) -- batch size, something >= 128 is helpful for software rate limiters
	local seq = 1ULL
	local baseIP = parseIPAddress("10.0.1.1")
	while mg.running() do
		bufs:alloc(60) -- default packet size, just some random value as we change it later
		for i, buf in ipairs(bufs) do
			local pkt = buf:getUdp4Packet()
			-- sequence number in payload
			pkt.payload.uint64[0] = seq
			seq = seq + 1
			-- other random stuff, e.g., randomize the src IP
			pkt.ip4.src:set(baseIP + math.random(0, 100))
			-- change packet size
			local newSize = math.random(60, 252) -- size is always without CRC
			buf:setSize(newSize) -- sets the buffer size
			pkt:setLength(newSize) -- sets all length headers in the protocol stack
			-- buf:dump() -- uncomment to see the packets you are sending
		end
		bufs:offloadIPChecksums()
		rateLimiter:send(bufs)
	end
end

