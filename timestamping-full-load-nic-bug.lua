--- Script to investigate https://github.com/libmoon/libmoon/issues/8
local lm     = require "libmoon"
local device = require "device"
local memory = require "memory"
local ts     = require "timestamping"
local hist   = require "histogram"
local timer  = require "timer"
local log    = require "log"
local stats  = require "stats"

local RUN_TIME = 10

function configure(parser)
	parser:argument("txDev", "Transmit device."):convert(tonumber)
	parser:argument("rxDev", "Receive device."):convert(tonumber)
	parser:option("--size", "Packet size."):default(60):convert(tonumber)
	parser:option("--threads", "Number of TX threads for background traffic."):default(1):convert(tonumber)
end

function master(args)
	local txDev = device.config{port = args.txDev, txQueues = args.threads + 1}
	local rxDev = device.config{port = args.rxDev, rxQueues = 2}
	--rxDev:setPromisc(false)
	device.waitForLinks()
	stats.startStatsTask{rxDev, txDev}
	for i = 1, args.threads do
		lm.startTask("backgroundTask", txDev:getTxQueue(i - 1), args.size)
	end
	timestamper(txDev:getTxQueue(args.threads), rxDev:getRxQueue(1), args.size)
	lm.waitForTasks()
end


function timestamper(txQueue, rxQueue, size)
	lm.sleepMillisIdle(300)
	local runtime = timer:new(RUN_TIME)
	local hist = hist:new()
	local timestamper = ts:newUdpTimestamper(txQueue, rxQueue)
	local sent = 0
	local received = nil
	local timestamps = 0
	while lm.running() and runtime:running() do
		sent = sent + 1
		local lat, num = timestamper:measureLatency(function(buf)
			buf:getEthPacket().eth:setDstString(rxQueue.dev:getMacString())
		end)
		if lat then
			timestamps = timestamps + 1
		end
		if num then
			received = (received or 0) + num
		end
		hist:update(lat)
	end
	if received then -- old version doesn't support this
		log:info("Sent %d packets, received %d packets, got %d timestamps", sent, received, timestamps)
	else
		log:info("Sent %d packets, got %d timestamps", sent, timestamps)
	end
	hist:print()
	lm.stop()
end


function backgroundTask(queue, size)
	local mempool = memory.createMemPool(function(buf)
		local pkt = buf:getUdpPacket()
		pkt:fill{
			ethSrc = queue,
			pktLength = size
		}
		pkt.ip4:calculateChecksum()
	end)
	local bufs = mempool:bufArray()
	while lm.running() do
		bufs:alloc(size)
		queue:send(bufs)
	end
end

