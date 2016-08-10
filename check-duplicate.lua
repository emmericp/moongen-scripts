--- Duplicate packet detection, requires two directly connected ports
local mg		= require "dpdk"
local memory	= require "memory"
local device	= require "device"
local stats		= require "stats"
local log		= require "log"

--local PKT_SIZE	= 60
local PKT_SIZE	= 750
--local PKT_SIZE	= 1500

function master(txPort, rxPort)
	if not txPort or not rxPort then
		return log:info("usage: txPort rxPort")
	end
	local txDev = device.config{port = txPort}--, rxQueues = 10, txQueues = 30}
	local rxDev = device.config{port = rxPort}--, rxQueues = 10, txQueues = 30}
	mg.launchLua("txSlave", txDev:getTxQueue(0))
	mg.launchLua("rxSlave", rxDev:getRxQueue(0))
	mg.waitForSlaves()
end

function txSlave(queue)
	mg.sleepMillis(500) -- wait a few milliseconds to ensure that the rx thread is running
	local mem = memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{
			pktLength = PKT_SIZE,
			ethSrc = queue,
			ethDst = "11:22:33:44:55:66",
		}
	end)
	local bufs = mem:bufArray()
	local seq = 0ULL
	local txCtr = stats:newDevTxCounter(queue, "plain")
	while mg.running() do
		bufs:alloc(PKT_SIZE)
		for _, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			pkt.payload.uint64[0] = seq
			seq = seq + 1
		end
		txCtr:update()
		queue:send(bufs)
	end
	txCtr:finalize()
end

function rxSlave(queue)
	local bufs = memory.bufArray()
	local seq = 0ULL
	local rxCtr = stats:newDevRxCounter(queue, "plain")
	while mg.running() do
		local rx = queue:recv(bufs)
		for i = 1, rx do
			local buf = bufs[i]
			local pkt = buf:getUdpPacket()
			local receivedSeq = pkt.payload.uint64[0]
			-- seq too high: lost packets (or reordered)
			if receivedSeq > seq then
				log:warn("Lost %d packets at seq %s", tonumber(receivedSeq - seq), receivedSeq)
			elseif receivedSeq < seq then -- seq too low: duplicate (or reordering)
				log:warn("Duplicate packet or out of order rx, received seq %d, expected seq %s", receivedSeq, seq)
			end -- else: exactly as expected
			-- next expected seq is current + 1
			seq = receivedSeq + 1
		end
		rxCtr:update()
		bufs:freeAll()
	end
	rxCtr:finalize()
end


