-- vim:ts=4:sw=4:noexpandtab
local dpdk		= require "dpdk"
local memory	= require "memory"
local device	= require "device"
local stats		= require "stats"
local lacp		= require "proto.lacp"


function master(...)
	if select("#", ...) < 1 then
		return print("usage: port [ports...]")
	end
	local ports = { ... }
	for i = 1, select("#", ...) do
		local port = device.config{port = ports[i], rxQueues = 3, txQueues = 3} 
		ports[i] = port
	end
	device.waitForLinks()
	for i, port in ipairs(ports) do 
		local queue = port:getTxQueue(0)
		dpdk.launchLua("loadSlave", queue)
	end
	dpdk.waitForSlaves()
end

function loadSlave(queue)
	local mem = memory.createMemPool(function(buf)
		buf:getLacpPacket():fill{
		}
	end)
	local bufs = mem:bufArray()
	local txCtr = stats:newDevTxCounter(queue.dev, "plain")
	while dpdk.running() do
		bufs:alloc(lacp.PKT_SIZE)
		queue:send(bufs)
		txCtr:update()
	end
	txCtr:finalize()
end
