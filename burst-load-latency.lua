local dpdk		= require "dpdk"
local memory	= require "memory"
local ts		= require "timestamping"
local device	= require "device"
local filter	= require "filter"
local stats		= require "stats"
local timer		= require "timer"
local histogram	= require "histogram"
local log		= require "log"


local PKT_SIZE = 60

function master(...)
	local txPort, rxPort, rate, burstSize = tonumberall(...)
	if not txPort or not rxPort then
		return log:info("usage: txPort rxPort [rate (Mpps)] [burstSize]")
	end
	rate = rate or 2
	burstSize = burstSize or 1
	local txDev = device.config(txPort, 2, 2)
	local rxDev = device.config(rxPort, 2, 2)
	device.waitForLinks()
	dpdk.launchLuaOnCore(5, "loadSlave", txDev, rxDev, txDev:getTxQueue(0), rate, PKT_SIZE, burstSize)
	dpdk.launchLuaOnCore(4, "timerSlave", txDev:getTxQueue(1), rxDev:getRxQueue(1), PKT_SIZE)
	dpdk.waitForSlaves()
end

function loadSlave(dev, rxDev, queue, rate, size, burstSize)
	local mem = memory.createMemPool(8192, function(buf)
		buf:getEthernetPacket():fill{
			ethType = 0x1234,
			ethDst = "90:e2:ba:92:db:fc"
		}
	end)
	rxDev:l2Filter(0x1234, filter.DROP)
	-- bufArray size needs to be a multiple of burstSize for the algorithm below
	-- (minimum size for performance)
	local bufs = mem:bufArray(burstSize * math.max(1, math.floor(128 / burstSize)))
	local rxStats = stats:newDevRxCounter(rxDev, "plain")
	local txStats = stats:newManualTxCounter(dev, "plain")
	local runTime = timer:new(150)
	while dpdk.running() and runTime:running() do
		bufs:alloc(size)
		local burstCtr = 1
		for _, buf in ipairs(bufs) do
			if burstCtr == burstSize then
				buf:setDelay((10^10 / 8 / (rate * 10^6) - size - 24) * burstSize)
				burstCtr = 1
			else
				buf:setDelay(0) -- burst
				burstCtr = burstCtr + 1
			end
		end
		txStats:updateWithSize(queue:sendWithDelay(bufs), size)
		rxStats:update()
	end
	dpdk.stop()
	rxStats:finalize()
	txStats:finalize()
end

function timerSlave(txQueue, rxQueue, size)
	local timestamper = ts:newTimestamper(txQueue, rxQueue)
	local hist = histogram:new()
	-- wait for a second to give the other task a chance to start
	dpdk.sleepMillis(1000)
	local rateLimiter = timer:new(0.001)
	while dpdk.running() do
		rateLimiter:reset()
		hist:update(timestamper:measureLatency(size))
		rateLimiter:busyWait()
	end
	hist:print()
	hist:save("histogram.csv")
end

