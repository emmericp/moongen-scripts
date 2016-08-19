-- demo for multiple rate-limited queues in a single thread
local phobos   = require "phobos"
local device   = require "device"
local stats    = require "stats"
local memory   = require "memory"

function master(dev)
	local dev = device.config{
		port = dev,
		txQueues = 2,
		rxQueues = 1
	}
	device.waitForLinks()
	
	local queue1 = dev:getTxQueue(0)
	local queue2 = dev:getTxQueue(1)
	queue1:setRate(100)
	queue2:setRate(1000)
	phobos.startTask("txSlave", queue1, queue2)
	phobos.waitForTasks()
end

local function createMemPool()
	return memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{}
	end)
end

function txSlave(queue0, queue1)
	local mempools = {createMemPool(), createMemPool()}
	local bufs = {mempools[1]:bufArray(), mempools[2]:bufArray()}
	local queues = {queue0, queue1}
	local ctrs = {stats:newManualTxCounter("Queue 0"), stats:newManualTxCounter("Queue 1")}
	local txOffsets = {0, 0}
	while phobos.running() do 
		for i = 1, 2 do
			bufs[i]:alloc(60)
			bufs[i]:offloadUdpChecksums()
			local tx = queues[i]:trySend(bufs[i], txOffsets[i])
			txOffsets[i] = txOffsets[i] + tx
			if txOffsets[i] >= bufs[i].size then
				txOffsets[i] = 0
			end
			ctrs[i]:updateWithSize(tx, 60)
		end
	end
	for i = 1, 2 do
		ctrs[i]:finalize()
	end
end

