--- A very simplistic VXLAN example...
local mg     = require "moongen"
local device = require "device"
local stats  = require "stats"
local log    = require "log"
local memory = require "memory"

-- set addresses here
local VNI            = 12345
local DST_MAC        = "01:23:45:67:89:ab" -- see l3-load-latency.lua for an example on using ARP instead
local INNER_DST_MAC  = "ff:ff:ff:ff:ff:ff"
local INNER_SRC_MAC  = "cd:ef:01:23:45:67"
local PKT_LEN        = 124
local OUTER_SRC_IP   = "10.0.0.10"
local OUTER_DST_IP   = "10.1.0.10"
local INNER_SRC_IP   = "192.168.0.1"
local INNER_DST_IP   = "172.16.0.1"
local INNER_SRC_PORT = 1234
-- inner destination port is randomized

-- the configure function is called on startup with a pre-initialized command line parser
function configure(parser)
	parser:description("Edit the source to modify constants like IPs and ports.")
	parser:argument("dev", "Devices to use."):args("+"):convert(tonumber)
	parser:option("-r --rate", "Transmit rate in Mbit/s per device."):args(1)
	parser:option("-t --threads", "Number of threads per device."):args(1):default(1)
	return parser:parse()
end

function master(args)
	-- configure devices and queues
	for i, dev in ipairs(args.dev) do
		args.dev[i] = device.config{
			port = dev,
			txQueues = args.threads,
			rxQueues = 1
		}
	end
	device.waitForLinks()

	-- print statistics
	stats.startStatsTask{devices = args.dev}

	-- configure tx rates and start transmit slaves
	for i, dev in ipairs(args.dev) do
		for i = 1, args.threads do
			local queue = dev:getTxQueue(i - 1)
			if args.rate then
				queue:setRate(args.rate / args.threads)
			end
			mg.startTask("txSlave", queue)
		end
	end
	mg.waitForTasks()
end

local vxlanStack = packetCreate("eth", "ip4", "udp", "vxlan", { "eth", "innerEth" }, {"ip4", "innerIp4"}, {"udp", "innerUdp"})

function txSlave(queue, dstMac)
	local mempool = memory.createMemPool(function(buf)
		local pkt = vxlanStack(buf)
		pkt:fill{
			-- fields not explicitly set here are initialized to reasonable defaults
			ethSrc = queue, -- MAC of the tx device
			ethDst = DST_MAC,
			ip4Src = OUTER_SRC_IP,
			ip4Dst = OUTER_DST_IP,
			vxlanVNI = VNI,
			-- outer UDP ports are set automatically
			innerEthSrc = INNER_SRC_MAC,
			innerEthDst = INNER_DST_MAC,
			innerIp4Src = INNER_SRC_IP,
			innerIp4Dst = INNER_DST_IP,
			innerUdpSrc = INNER_SRC_PORT,
			innerUdpDst = INNER_DST_PORT,
			pktLength = PKT_LEN
		}
		pkt.innerIp4:calculateChecksum()
	end)
	local bufs = mempool:bufArray()
	local srcIp = parseIPAddress(INNER_SRC_IP) -- if you want to randomize inner IPs
	while mg.running() do
		bufs:alloc(PKT_LEN)
		for i, buf in ipairs(bufs) do
			local pkt = vxlanStack(buf)
			pkt.innerUdp:setDstPort(1000 + math.random(0, 1000))
			--pkt.innerIp4:setSrc(srcIp + math.random(0, 253))
			-- software checksum calculation is slow at the moment, see issue https://github.com/libmoon/libmoon/issues/11
			--pkt.innerIp4:calculateChecksum() -- inner checksum is already correct if innerIp4 is not modified
		end
		bufs:offloadUdpChecksums() -- outer IP/UDP checksums
		-- note for inner UDP/TCP checksums: we use UDP here where the checksum is optional ;)
		-- inner checksum are slightly more annoying as offloading isn't supported on most NICs
		-- see libmoon/lua/proto/tcp.lua tcpHeader:calculateChecksum(data, len) for details on calculating it in software
		-- https://github.com/libmoon/libmoon/issues/9 discusses how this can be improved
		queue:send(bufs)
	end
end

