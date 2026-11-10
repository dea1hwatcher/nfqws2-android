-- nfqws2-android-ext: smart mode — self-learning orchestrator (MIT License)
--
-- Similar to circular in zapret-auto.lua: a single smart call precedes strategy
-- variants labeled with strategy=N, determining which bypass variant to apply.
--
-- Key features:
--   * Per-host and per-network scoring: successes and errors tracked with exponential
--     decay (halving every hour) so past performance does not mask current degradation.
--   * Mid-stream inspection: monitors /proc/net/tcp every 3s to detect stalls,
--     freezes, and ~16 KB cutoffs, terminating dead connections early via smart_kill.
--   * Flexible success criteria: verified responses, clean teardowns (FIN/RST),
--     and sustained keep-alive sessions (>30s) accrue weighted credit.
--   * Sliding window: decisions evaluated over the last 8 connections; switches
--     occur when errors dominate.
--   * Parameter tuning: failing variants auto-tune single parameters (fake repeats,
--     split positions, SNI, seqovl pattern) before switching to unrelated strategies.
--   * Fast learning: networks, subnets, and domains maintain state in smart/<net>.tsv.
--
-- Orchestrator options:
--   slot=NAME    profile identifier (tls, quic, google, etc.)
--   home=DIR     working directory (/data/adb/nfqws2)
--   first=N      initial strategy for unlearned domains (default 1)
--   base=LIST    primary strategy set (e.g. 1-6,10,22)
--   pass=N       pass-through variant (tried last, never set as network default)
--   cutoff=N     inbound byte threshold to end tracking (default 18 KB)

SMART = SMART or {
	home = nil, net = nil, db = {}, ns = {}, nstrat = {}, conns = {},
	dirty = false, saved = 0, netcheck = 0, offline = false,
	lastok = 0, lastconn = 0, failhosts = {}, suspect_since = nil, watching = false,
	layout = {}, mut = {}, mutnext = {}, mutt = {}, allow = {}, nallow = {}, basesets = {},
	proc = { "/proc/net/tcp", "/proc/net/tcp6" }
}
local SM = SMART

local SAVE_EVERY = 20       -- sec: save learned state to disk interval
local NET_EVERY = 5         -- sec: network change check interval
local MAX_HOSTS = 3000      -- max host records per network
local HALF = 3600           -- sec: half-life for score decay
local COOL_BASE = 300       -- sec: initial cooldown for failed variant
local COOL_MAX = 7200
local SWITCH_GAP = 15       -- sec: min delay between variant switches per host
local WIN = 8               -- window: recent connections for host on current variant
local WATCH_MS = 3000       -- connection watcher tick
local STUCK_RETRANS = 4     -- consecutive unacknowledged retransmits before stall verdict
local FROZEN_RTX = 3        -- retransmits of identical segment after server response = frozen connection
local FROZEN_IN = 12        -- max incoming packets before queue cutoff
local NET_STUCK_IPS = 3     -- stalls across N distinct server IPs = network-wide issue, not DPI
local APP_UID = 10000       -- watcher tracks user apps only
local NODPI_VARIANTS = 4    -- failure across N variants without success = non-DPI failure
local NODPI_TIME = 6 * 3600
local ANSWER = 300          -- bytes: server response size indicating DPI bypass success
local ALIVE_OK = 30         -- sec: connection alive after response = confirmed success
local CREDIT_STEP = 60      -- sec: connection duration credit step
local CREDIT_W = 0.5        --   credit weight per step
local CREDIT_MAX = 3        --   max accumulated credit bonus
local MUT_BASE = 100        -- tuned variant IDs start at 101
local MUT_MAX = 32          -- max tuned variants per network variant set
local MUT_DEPTH = 3         -- max modified parameters per tuning
local MUT_EVERY = 30        -- sec: min delay between new tunings
local TUNE_GAP = 600        -- sec: min delay between tuning the same host
-- Subnet neighbours: CDN services host multiple domains on shared addresses
-- (e.g. SoundCloud on CloudFront: soundcloud.com for API, sndcdn.com for media).
-- A variant recently working for one domain is prioritized for adjacent domains
-- sharing the same /24 or /48 subnet.
local NEAR_TIME = 3600      -- sec: address subnet affinity duration
local NEAR_MAX = 4096       -- max subnet entries per variant set

-- Multi-part ccTLDs: domain key is one label deeper (e.g. co.uk, com.tr)
local SLD2 = { co = 1, com = 1, net = 1, org = 1, gov = 1, edu = 1, ac = 1, ["or"] = 1, ne = 1, go = 1,
	ltd = 1, plc = 1, gen = 1, nic = 1, mil = 1, biz = 1, info = 1, me = 1, ["in"] = 1 }
local SHARED = { ["msk.ru"] = 1, ["spb.ru"] = 1, ["workers.dev"] = 1, ["pages.dev"] = 1, ["github.io"] = 1,
	["herokuapp.com"] = 1, ["appspot.com"] = 1, ["vercel.app"] = 1, ["netlify.app"] = 1, ["web.app"] = 1,
	["firebaseapp.com"] = 1, ["blogspot.com"] = 1, ["cloudfront.net"] = 1, ["azurewebsites.net"] = 1 }
local function shared_zone(two)
	if SHARED[two] then return true end
	local sld, tld = two:match("^([^.]+)%.([^.]+)$")
	return sld ~= nil and SLD2[sld] ~= nil and #tld == 2
end
-- Host key: domain name, or IP if protocol does not carry SNI (MTProto, etc.)
local function site_key(desync)
	local h = desync.track and desync.track.hostname
	if not h then
		local p = desync.track and desync.track.l7proto
		if p == "tls" or p == "http" or p == "quic" then return nil end
		return host_ip(desync)
	end
	if desync.track.hostname_is_ip then return h end
	-- Zephyron domain grouping: CDN shards share learned strategy
	if h == "redirector.googlevideo.com" then return h end
	if h:match("%.googlevideo%.com$") then return "googlevideo.com" end
	if h:match("%.youtube%.com$") or h == "youtube.com" then return "youtube.com" end
	if h:match("%.ytimg%.com$") or h == "ytimg.com" then return "ytimg.com" end
	if h:match("%.ggpht%.com$") or h == "ggpht.com" then return "ggpht.com" end
	if h:match("%.googleapis%.com$") or h == "googleapis.com" then return "googleapis.com" end
	if h:match("%.google%.com$") or h == "google.com" then return "google.com" end
	if h:match("%.rapidgator%.net$") or h == "rapidgator.net" then return "rapidgator.net" end

	local two = dissect_nld(h, 2)
	if not two then return h end
	if shared_zone(two) then return dissect_nld(h, 3) or h end
	return two
end

local function now() return os.time() end

local function readline(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local s = f:read("*l")
	f:close()
	return s
end

local function netfile(net) return SM.home .. "/smart/" .. net .. ".tsv" end

-- ── Smart Mode Log (logs/smart.log) ──────────────────────────────────
-- Records decisions: variant switches, tuning, non-DPI verdicts, kills, network changes
-- Output: logs/smart.log (rotated to smart.log.1 at 256 KB)
local JOURNAL_MAX = 262144
local function variant_names()
	if SM.names then return SM.names end
	SM.names = {}
-- Service seeds strategy labels on boot: "slot N name"
	local f = SM.home and io.open(SM.home .. "/state/smart_names", "r")
	if f then
		for line in f:lines() do
			local sl, n, name = line:match("^([%w_]+) (%d+) (.+)$")
			if sl then SM.names[sl .. "|" .. n] = name end
		end
		f:close()
	end
	return SM.names
end
local function vname(slot, v)
	local names, m = variant_names(), nil
	local function one(x)
		return names[slot .. "|" .. x] or names[(slot:match("^([^_]+)") or slot) .. "|" .. x] or ("#" .. x)
	end
	local m = v and v > MUT_BASE and SM.mut[slot] and SM.mut[slot][v]
	if m then
		local a = {}
		for _, c in ipairs(m.ch) do a[#a + 1] = c.k .. "=" .. c.val end
		return one(m.base) .. " · tuning " .. v .. ": " .. table.concat(a, ", ")
	end
	return one(v)
end
function smart_journal(msg)
	if not SM.home then return end
	local path = SM.home .. "/logs/smart.log"
	local f = io.open(path, "a")
	if not f then return end
	f:write(os.date("%Y-%m-%d %H:%M:%S", os.time()), " ", msg, "\n")
	local size = f:seek("end")
	f:close()
	if size and size > JOURNAL_MAX then os.rename(path, path .. ".1") end
end
local SJ = smart_journal

local function csv_parse(s)
	local t = {}
	if s and s ~= "" then
		for k, v in string.gmatch(s, "(%d+):([%d.]+)") do t[tonumber(k)] = tonumber(v) end
	end
	return t
end
local function csv_dump(t, prec)
	local a = {}
	for k, v in pairs(t) do
		if v >= 0.05 then a[#a + 1] = k .. ":" .. (prec and string.format("%.1f", v) or string.format("%d", v)) end
	end
	table.sort(a)
	return table.concat(a, ",")
end

-- Score decay: exponential halving over HALF seconds
local function age(o, t)
	if not o.dt then o.dt = t; return end
	local dt = t - o.dt
	if dt < 60 then return end
	local k = 0.5 ^ (dt / HALF)
	for v, x in pairs(o.ok) do o.ok[v] = x * k end
	for v, x in pairs(o.err) do o.err[v] = x * k end
	o.dt = t
end
local function share(ok, err) return ((ok or 0) + 1) / ((ok or 0) + (err or 0) + 2) end

local function netstat(slot)
	local s = SM.ns[slot]
	if not s then s = { ok = {}, err = {} }; SM.ns[slot] = s end
	return s
end
local function restat()
	SM.ns = {}
	for key, r in pairs(SM.db) do
		local slot = key:match("^([^|]+)|")
		if slot then
			local s = netstat(slot)
			for v, x in pairs(r.ok) do s.ok[v] = (s.ok[v] or 0) + x end
			for v, x in pairs(r.err) do s.err[v] = (s.err[v] or 0) + x end
		end
	end
end

-- ── Strategy parameter tuning ─────────────────────────────────────────
-- Explores variations of working strategies that began failing by mutating
-- a single parameter (repeats, split pos, fake SNI, seqovl pattern).
local TLS_BLOBS = { "fake_default_tls", "tls_clienthello", "tls_google", "tls_sferum", "tls_sochi", "tls_4pda" }
local QUIC_BLOBS = { "quic_initial", "quic_google", "quic_5ka" }
local STUN_BLOBS = { "stun", "stun2" }
local GENES = {
	fake = {
		blob = true,
		repeats = { "1", "2", "4", "6", "8", "11" },
		sni = { "www.google.com", "fonts.google.com", "hcaptcha.com", "ad.adriver.ru", "rzd.ru", "vk.com" },
		tcp_ts = { "-1000", "-1500", "-600000" },
	},
	multisplit = {
		pos = { "1", "2", "1,midsld", "1,sniext+1", "sniext+1", "midsld", "1,sniext-2", "2,midsld" },
		seqovl = { "1", "568", "582", "664", "681" },
		seqovl_pattern = { "tls_clienthello", "tls_google", "tls_sferum", "tls_sochi", "stun" },
	},
	multidisorder = {
		pos = { "1,midsld", "1,midsld,sniext+1,endhost-2,-10", "1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1", "2,midsld" },
	},
	hostfakesplit = {
		host = { "www.google.com", "ozon.ru", "mail.ru", "ya.ru", "vk.com" },
		midhost = { "host-2", "midsld-2", "midsld" },
	},
}
local function in_list(l, x)
	for _, y in ipairs(l) do if y == x then return true end end
	return false
end
-- Parameter value in instance; fake host lives inside tls_mod
local function gene_get(arg, k)
	if k == "sni" then return arg.tls_mod and arg.tls_mod:match("sni=([^,]+)") end
	return arg[k]
end
local function gene_set(arg, k, val)
	if k == "sni" then arg.tls_mod = arg.tls_mod:gsub("sni=[^,]+", "sni=" .. val) else arg[k] = val end
end
-- Mutation candidate pool: alters existing parameters within protocol limits
local function gene_pool(func, arg, k)
	local g = GENES[func] and GENES[func][k]
	local cur = gene_get(arg, k)
	if not g or cur == nil then return nil end
	if k == "blob" then
		for _, l in ipairs({ TLS_BLOBS, QUIC_BLOBS, STUN_BLOBS }) do if in_list(l, cur) then return l end end
		return nil
	end
	return g
end
local function mutant(slot, v) return v and v > MUT_BASE and SM.mut[slot] and SM.mut[slot][v] or nil end
local function base_of(slot, v) local m = mutant(slot, v); return m and m.base or v end
local function ch_str(ch)
	local a = {}
	for _, c in ipairs(ch) do a[#a + 1] = c.i .. "." .. c.k .. "=" .. c.val end
	table.sort(a)
	return table.concat(a, ";")
end
local function ch_parse(s)
	local ch = {}
	for item in (s or ""):gmatch("[^;]+") do
		local i, k, val = item:match("^(%d+)%.([%w_]+)=(.+)$")
		if i then ch[#ch + 1] = { i = tonumber(i), k = k, val = val } end
	end
	return ch
end
local function mut_used(slot, id)
	for key, r in pairs(SM.db) do
		if r.cur == id and key:sub(1, #slot + 1) == slot .. "|" then return true end
	end
	return false
end
local function mut_drop(slot, id)
	local base = SM.mut[slot][id].base
	SM.mut[slot][id] = nil
	for key, r in pairs(SM.db) do
		if key:sub(1, #slot + 1) == slot .. "|" then
			r.ok[id], r.err[id], r.cool[id], r.cooln[id] = nil, nil, nil, nil
			if r.cur == id then r.cur = base end
			if r.first == id then r.first = base end
		end
	end
	local s = SM.ns[slot]
	if s then s.ok[id], s.err[id] = nil, nil end
	SM.dirty = true
end
-- Prune stale mutations unused across the network for >1 hour
local function mut_gc(slot, t, need_room)
	local ms = SM.mut[slot]
	if not ms then return end
	local s = netstat(slot)
	local worst, ws, n = nil, nil, 0
	for id, m in pairs(ms) do
		n = n + 1
		if not mut_used(slot, id) then
			if t - m.t > 3600 and (s.ok[id] or 0) < 1 then mut_drop(slot, id); n = n - 1
			else
				local sc = share(s.ok[id], s.err[id])
				if not worst or sc < ws then worst, ws = id, sc end
			end
		end
	end
	if need_room and n >= MUT_MAX and worst then mut_drop(slot, worst) end
end
-- Spawn new mutation derived from base variant
local function make_mutant(slot, from, t)
	local pm = mutant(slot, from)
	local base = pm and pm.base or from
	local insts = SM.layout[slot] and SM.layout[slot][base]
	if not insts then return nil end
	SM.mut[slot] = SM.mut[slot] or {}
	mut_gc(slot, t, true)
	local cnt = 0
	for _ in pairs(SM.mut[slot]) do cnt = cnt + 1 end
	if cnt >= MUT_MAX then return nil end
	local genes = {}
	for i, ins in ipairs(insts) do
		local keys = {}
		for k in pairs(GENES[ins.func] or {}) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local pool = gene_pool(ins.func, ins.arg, k)
			if pool then genes[#genes + 1] = { i = i, k = k, pool = pool, orig = gene_get(ins.arg, k) } end
		end
	end
	if #genes == 0 then return nil end
	local known = {}
	for _, m in pairs(SM.mut[slot]) do if m.base == base then known[ch_str(m.ch)] = true end end
	local keep = (pm and #pm.ch < MUT_DEPTH) and pm.ch or {}
	for _ = 1, 16 do
		local g = genes[math.random(#genes)]
		local val = g.pool[math.random(#g.pool)]
		local ch, cur = {}, g.orig
		for _, c in ipairs(keep) do
			if c.i == g.i and c.k == g.k then cur = c.val else ch[#ch + 1] = { i = c.i, k = c.k, val = c.val } end
		end
		if val ~= cur then
			if val ~= g.orig then ch[#ch + 1] = { i = g.i, k = g.k, val = val } end
			if #ch > 0 and not known[ch_str(ch)] then
				local id = math.max(SM.mutnext[slot] or 0, MUT_BASE + 1)
				SM.mutnext[slot] = id + 1
				SM.mut[slot][id] = { base = base, ch = ch, t = t }
				SM.dirty = true
				return id
			end
		end
	end
	return nil
end
-- Check if variant belongs to currently active candidate set
local function allowed(slot, v)
	local a = SM.allow[slot]
	return not a or a[v] ~= nil
end
-- Parse base=1-6,10,22 into lookup table
local function base_set(str, nall)
	local c = SM.basesets[str]
	if c then return c.set, c.count end
	local set, count = {}, 0
	local spec = tonumber(str) and ("1-" .. str) or str
	for part in spec:gmatch("[^,]+") do
		local a, b = part:match("^(%d+)%-(%d+)$")
		a, b = tonumber(a or part), tonumber(b or a or part)
		if a and b then
			for v = a, math.min(b, nall) do if not set[v] then set[v] = true; count = count + 1 end end
		end
	end
	SM.basesets[str] = { set = set, count = count }
	return set, count
end

-- Return all active variants in set (builtin + mutations)
local function variants(slot, n)
	local l = {}
	for v = 1, n do if allowed(slot, v) then l[#l + 1] = v end end
	local ids = {}
	for id, m in pairs(SM.mut[slot] or {}) do if m.base <= n and allowed(slot, m.base) then ids[#ids + 1] = id end end
	table.sort(ids)
	for _, id in ipairs(ids) do l[#l + 1] = id end
	return l
end

local function newrec(cur)
	return { cur = cur, first = cur, ok = {}, err = {}, early = {}, cool = {}, cooln = {}, win = {}, sw = 0, seen = 0 }
end

local function load_net(net)
	local f = io.open(netfile(net), "r")
	if not f then return false end
	local head = f:read("*l")
	-- Migrate older layout formats, discarding unreliable non-DPI flags
	if not head or not head:find("^#v[234]") then f:close(); return false end
	local v2 = head:find("^#v2") ~= nil
	local old = not head:find("^#v4")
	local db, mut, mutnext = {}, {}, {}
	for line in f:lines() do
-- Mutation record: #m slot id base changes created
		local ms, mid, mb, mch, mt = line:match("^#m\t([^\t]+)\t(%d+)\t(%d+)\t([^\t]+)\t(%d+)")
		if ms then
			mid = tonumber(mid)
			mut[ms] = mut[ms] or {}
			mut[ms][mid] = { base = tonumber(mb), ch = ch_parse(mch), t = tonumber(mt) }
			mutnext[ms] = math.max(mutnext[ms] or 0, mid + 1)
		end
		local slot, host, cur, ok, err, cool, seen, flags =
			line:match("^([^\t#]+)\t([^\t]+)\t(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(%d+)\t?(%w*)")
-- Ignore deprecated multi-part TLD entries (e.g. co.uk)
		if slot and not shared_zone(host) then
			local r = newrec(tonumber(cur))
			r.ok, r.err, r.seen = csv_parse(ok), csv_parse(err), tonumber(seen)
			r.dt = r.seen
			for v, until_t in pairs(csv_parse(cool)) do
				if v == 0 then r.nodpi = (not old) and until_t or nil else r.cool[v] = until_t end
			end
			r.everok = flags == "e" or (v2 and next(r.ok) ~= nil)
			db[slot .. "|" .. host] = r
		end
	end
	f:close()
	-- Keep mutation ID monotonic across sessions
	for key, r in pairs(db) do
		local slot = key:match("^([^|]+)|")
		for v in pairs(r.ok) do if v > MUT_BASE then mutnext[slot] = math.max(mutnext[slot] or 0, v + 1) end end
		for v in pairs(r.err) do if v > MUT_BASE then mutnext[slot] = math.max(mutnext[slot] or 0, v + 1) end end
	end
	SM.db, SM.mut, SM.mutnext = db, mut, mutnext
	return true
end

local function save()
	if not SM.home or not SM.net or SM.net == "offline" then return end
	SM.saved = now()
	if not SM.dirty then return end
	local keys = {}
	for k in pairs(SM.db) do keys[#keys + 1] = k end
	if #keys > MAX_HOSTS then
		table.sort(keys, function(a, b) return SM.db[a].seen > SM.db[b].seen end)
		for i = MAX_HOSTS + 1, #keys do SM.db[keys[i]] = nil end
		restat()
	end
	local path = netfile(SM.net)
	local f = io.open(path .. ".tmp", "w")
	if not f then DLOG_ERR("smart: cannot write " .. path); return end
	f:write("#v4 slot\thost\tcur\tok\terr\tcool\tseen\tflags\n")
	local t = now()
	for slot in pairs(SM.mut) do mut_gc(slot, t) end
	for slot, ms in pairs(SM.mut) do
		for id, m in pairs(ms) do
			f:write("#m\t", slot, "\t", id, "\t", m.base, "\t", ch_str(m.ch), "\t", m.t, "\n")
		end
	end
	for k, r in pairs(SM.db) do
		local slot, host = k:match("^([^|]+)|(.*)$")
		local cool = {}
		for v, u in pairs(r.cool) do if u > t then cool[v] = u end end
-- Non-DPI exclusion marker under index 0
		if r.nodpi and r.nodpi > t then cool[0] = r.nodpi end
		f:write(slot, "\t", host, "\t", r.cur, "\t", csv_dump(r.ok, true), "\t", csv_dump(r.err, true), "\t",
			csv_dump(cool), "\t", r.seen or 0, "\t", r.everok and "e" or "", "\n")
	end
	f:close()
	os.rename(path .. ".tmp", path)
	SM.dirty = false
end

-- Active network ID from state/smart_net (or offline)
local function check_bench(t)
	if t - (SM.benchcheck or 0) < 1 then return end
	SM.benchcheck = t
	local l = readline(SM.home .. "/state/smart_bench")
	SM.bench = l and tonumber(l:match("^(%d+)")) or nil
end

local function check_net()
	local t = now()
	if t - SM.netcheck < NET_EVERY then return end
	SM.netcheck = t
	SM.pool_ext = readline(SM.home .. "/state/smart_pool") == "ext"
	check_bench(t)
	local net = readline(SM.home .. "/state/smart_net") or "default"
	net = net:gsub("[^%w%-_.]", "_")
	if net == "" then net = "default" end
	SM.offline = (net == "offline")
	if SM.offline or net == SM.net then return end
	if SM.net then save() end
	local prev = SM.net
	SM.net = net
	SM.near = {}                 -- server subnet affinity map
	if load_net(net) then
		DLOG("smart: network '" .. net .. "': loaded")
		SJ("network " .. net .. ": learned data loaded")
	else
-- Initialize new network from copy of prior network state
		DLOG("smart: network '" .. net .. "' is new, starting from a copy of '" .. tostring(prev) .. "'")
		SJ("network " .. net .. ": new" .. (prev and (", starts from copy of " .. prev) or ""))
		for _, r in pairs(SM.db) do r.cool = {}; r.cooln = {}; r.win = {} end
		SM.dirty = true
	end
	restat()
	SM.conns = {}
end

-- Return network's highest-scoring strategy with >=3 successes
local function leader(slot, n, first, pass)
	local s = SM.ns[slot]
	local best, bs
	if s then
		for _, v in ipairs(variants(slot, n)) do
			if v ~= pass and (s.ok[v] or 0) >= 3 then
				local sc = share(s.ok[v], s.err[v])
				if not best or sc > bs then best, bs = v, sc end
			end
		end
	end
	if best and bs >= 0.6 then return best end
	return first
end

-- Pick next candidate variant for host based on host history or network leader
local function next_strategy(slot, r, n, t, pass)
	local s = netstat(slot)
	local best, bs
	local cb = base_of(slot, r.cur)
	for _, v in ipairs(variants(slot, n)) do
		local seen = (r.ok[v] or 0) + (r.err[v] or 0)
-- Foreign mutations require at least 1 local success before adoption
		local m = mutant(slot, v)
		if v ~= r.cur and (not m or seen >= 0.5 or (s.ok[v] or 0) >= 0.5) then
			local net = share(s.ok[v], s.err[v])
			local sc = seen >= 0.5 and (0.7 * share(r.ok[v], r.err[v]) + 0.3 * net) or (net - 0.05)
			if v == pass and (r.ok[v] or 0) < 0.5 then sc = sc - 1 end
			if (r.cool[v] or 0) > t then sc = sc - 0.3 end
-- Break ties by choosing next sequential builtin variant
			if m then sc = sc - 0.02 - (v - MUT_BASE) * 0.00001
			else sc = sc - (((v - cb) % n) * 0.0001) end
			if not best or sc > bs then best, bs = v, sc end
		end
	end
	return best
end

-- Network outage detection: multiple simultaneous failures without successes are ignored
local function network_suspect(key, t)
	if SM.offline then return true end
	SM.failhosts[key] = t
	local n = 0
	for h, ft in pairs(SM.failhosts) do
		if t - ft > 30 then SM.failhosts[h] = nil else n = n + 1 end
	end
	if n >= 3 and t - SM.lastok > 30 then
		SM.suspect_since = SM.suspect_since or t
		return t - SM.suspect_since < 120
	end
	SM.suspect_since = nil
	return false
end

local function count(r, slot, field, v, d, t)
	age(r, t)
	local s = netstat(slot)
	age(s, t)
	r[field][v] = math.max(0, (r[field][v] or 0) + d)
	s[field][v] = math.max(0, (s[field][v] or 0) + d)
	SM.dirty = true
end

-- Sliding window of recent connection outcomes (1 = ok, 0 = fail)
local function win_push(r, c, val)
	r.win = r.win or {}
	r.win[#r.win + 1] = { c = c, v = val }
	if #r.win > WIN then table.remove(r.win, 1) end
end
-- Long-lived connections accrue additional success weight
local function win_count(r)
	local e, o = 0, 0
	for _, x in ipairs(r.win or {}) do if x.v == 1 then o = o + (x.w or 1) else e = e + 1 end end
	return e, o
end

-- Subnet mask: IPv4 /24, IPv6 /48
local function ip_block(ip)
	if not ip then return nil end
	local b4 = ip:match("^(%d+%.%d+%.%d+)%.%d+$")
	if b4 then return b4 end
	local g1, g2, g3 = ip:match("^(%x+):(%x+):(%x+):")
	return g1 and (g1 .. ":" .. g2 .. ":" .. g3) or nil
end
local function near_put(slot, ip, v, t)
	local b = ip_block(ip)
	if not b then return end
	SM.near = SM.near or {}
	local ns = SM.near[slot]
	if not ns then ns = { n = 0, m = {} }; SM.near[slot] = ns end
	if not ns.m[b] then
		ns.n = ns.n + 1
		if ns.n > NEAR_MAX then
			ns.n = 0
			for k, x in pairs(ns.m) do if t - x.t > NEAR_TIME then ns.m[k] = nil else ns.n = ns.n + 1 end end
			if ns.n >= NEAR_MAX then ns.m, ns.n = {}, 0 end
			ns.n = ns.n + 1
		end
	end
	ns.m[b] = { v = v, t = t }
end
-- Most recent working variant on this subnet
local function near_get(slot, ip, n, t)
	local b = ip_block(ip)
	local ns = b and SM.near and SM.near[slot]
	local x = ns and ns.m[b]
	if not x or t - x.t > NEAR_TIME then return nil end
	local base = base_of(slot, x.v)
	if base > n or not allowed(slot, base) then return nil end
	if x.v > MUT_BASE and not mutant(slot, x.v) then return nil end
	return x.v
end

local function on_ok(slot, r, v, t, c)
	count(r, slot, "ok", v, 1, t)
	-- Record only non-default variants for subnet sharing
	if c and c.ip and v ~= c.pass and c.n and v ~= leader(slot, c.n, c.first or 1, c.pass) then near_put(slot, c.ip, v, t) end
	r.everok = true
	if c then c.okt = c.okt or t end
	if v == r.cur then win_push(r, c, 1); r.cooln[v] = 0 end
	SM.lastok = t
	SM.suspect_since = nil
end
-- Credit bonus for connections that remain active and healthy for >30s
local function credit(slot, r, v, w, t, c)
	count(r, slot, "ok", v, w, t)
	for _, x in ipairs(r.win or {}) do
		if x.c == c and x.v == 1 then x.w = (x.w or 1) + w end
	end
end

-- Connection failure on variant v (mid-stream stall or handshake drop)
local function on_err(slot, key, r, v, n, t, pass, mid, c)
-- Known non-DPI host: skip rotation
	if r.nodpi and r.nodpi > t then return end
	if network_suspect(key, t) then
		DLOG("smart: " .. key .. ": error ignored — network looks down")
		return
	end
	count(r, slot, "err", v, 1, t)
	if not mid then r.early[v] = true end
	if v ~= r.cur then return end   -- host already switched away from this variant
	-- Convert in-flight success to failure on mid-stream stall
	local found = false
	if mid and c then
		for _, x in ipairs(r.win or {}) do if x.c == c then x.v = 0; x.w = nil; found = true end end
	end
	if not found then win_push(r, c, 0) end
	-- Switch variant if error threshold met in sliding window (>=3 errors)
	local e, o = win_count(r)
	local need = r.everok and 3 or 2
	if share(r.ok[v], r.err[v]) >= 0.8 and (r.ok[v] or 0) >= 5 then need = 4 end
	local bad = e >= need and e > o
	if not bad or t - (r.sw or 0) < SWITCH_GAP then return end
	-- Server unreachable across multiple variants: classify as non-DPI
	local bad_v = 0
	for x = 1, n do if r.early[x] then bad_v = bad_v + 1 end end
	local nset = SM.nallow[slot] or n
	-- Host fails across nearly all variants with <10% success: pause rotation
	local tried, tok, terr = 0, 0, 0
	for x = 1, n do if (r.err[x] or 0) > 0 then tried = tried + 1 end end
	for _, w in pairs(r.ok) do tok = tok + w end
	for _, w in pairs(r.err) do terr = terr + w end
	if r.everok and tried >= math.max(8, math.ceil(nset * 0.75)) and tok < (tok + terr) * 0.1 then
		local best, bw = r.first or 1, 0
		for x, w in pairs(r.ok) do if w > bw then best, bw = x, w end end
		r.nodpi = t + NODPI_TIME
		r.cur = best
		r.win = {}
		DLOG("smart: " .. key .. ": tried " .. tried .. " variants, worked on " .. string.format("%.1f", tok) .. " of " .. string.format("%.0f", tok + terr) .. " — pausing the search for " .. NODPI_TIME .. "s")
		SJ(key .. ": tried almost all variants (" .. tried .. "), opened very few times — search paused for 6h")
		return
	end
	-- Pass-through variant evaluated last; skip waiting
	if not r.everok and bad_v >= math.min(nset - 1, math.max(NODPI_VARIANTS, math.ceil(nset / 2))) then
		r.nodpi = t + NODPI_TIME
		r.cur = r.first or 1
		r.win = {}
		DLOG("smart: " .. key .. ": fails on " .. bad_v .. " variants, never worked — not DPI, leaving it alone for " .. NODPI_TIME .. "s")
		SJ(key .. ": did not open on any of " .. bad_v .. " variants — does not look like DPI blocking, paused for 6h")
		return
	end
-- Exponential cooldown for frequently failing variants
	r.cooln[v] = (r.cooln[v] or 0) + 1
	r.cool[v] = t + math.min(COOL_MAX, COOL_BASE * 2 ^ (r.cooln[v] - 1))
	-- Mutate existing working variant before switching to different family
	local nxt, tuned
	local base = base_of(slot, v)
	local worked = (r.ok[v] or 0) >= 2 or (r.ok[base] or 0) >= 2
	if worked and v ~= pass and t - (r.tune or 0) >= TUNE_GAP then
	-- Try proven mutation that helped other hosts first
		local s, bs = netstat(slot), nil
		for id, m in pairs(SM.mut[slot] or {}) do
			if m.base == base and id ~= v and (r.ok[id] or 0) + (r.err[id] or 0) < 0.5 and (s.ok[id] or 0) >= 0.5 then
				local sc = share(s.ok[id], s.err[id])
				if sc >= 0.6 and (not bs or sc > bs) then nxt, bs = id, sc end
			end
		end
	-- Avoid chaining mutations on unproven variants
		if not nxt and t - (SM.mutt[slot] or 0) >= MUT_EVERY then
			nxt = make_mutant(slot, ((r.ok[v] or 0) >= 1) and v or base, t)
		end
		if nxt then
			r.tune, tuned = t, true
			if not bs then SM.mutt[slot] = t end
			DLOG("smart: " .. key .. ": tuning variant " .. base .. " as " .. nxt .. " (" .. ch_str(SM.mut[slot][nxt].ch) .. ")")
			SJ(key .. ": " .. vname(slot, v) .. " failing — " .. (bs and "using successful tuning: " or "trying tuning: ") .. vname(slot, nxt))
		end
	end
	-- Try variant recently proven on same subnet for brand new host
	if not nxt and not r.everok then
		local nv = near_get(slot, c and c.ip, n, t)
		if nv and nv ~= v and nv ~= pass and (r.err[nv] or 0) < 1 and not ((r.cool[nv] or 0) > t) then
			nxt = nv
			SJ(key .. ": " .. vname(slot, v) .. " → " .. vname(slot, nv) .. " — just opened neighbour site on same IP block")
			tuned = true
		end
	end
	nxt = nxt or next_strategy(slot, r, n, t, pass)
	if nxt then
		DLOG("smart: " .. key .. ": " .. v .. " -> " .. nxt .. " (ok " .. string.format("%.1f", r.ok[v] or 0) ..
			", err " .. string.format("%.1f", r.err[v] or 0) .. ")")
		if not tuned then
			local e, o = win_count(r)
			SJ(key .. ": " .. vname(slot, v) .. " → " .. vname(slot, nxt) .. string.format(" (recent conns: errors %d, ok %.1f; total ok %.1f, errors %.1f)", e, o, r.ok[v] or 0, r.err[v] or 0))
		end
		r.cur = nxt
	end
	r.win = {}
	r.sw = t
end

-- Active benchmark candidate under test
local function bench_variant(host, full_host)
	for i = 0, SM.bench - 1 do
		local l = readline(SM.home .. "/state/smart_bench." .. i)
		if l then
			local h, v, ts = l:match("^(%S+)%s+([%d-]+)%s+(%d+)$")
			if (h == host or (full_host and h == full_host)) and math.abs(now() - tonumber(ts)) <= 60 then return v end
		end
	end
end

local function count_strategies(desync)
	local n = SM.nstrat[desync.func_instance]
	if n then return n end
	n = 0
	-- Plan layout: sequential instances of each variant
	local lay = {}
	for _, instance in ipairs(desync.plan) do
		local s = tonumber(instance.arg.strategy)
		if s then
			if s > n then n = s end
			lay[s] = lay[s] or {}
			lay[s][#lay[s] + 1] = { func = instance.func, arg = instance.arg }
		end
	end
	SM.nstrat[desync.func_instance] = n
	local slot = desync.arg.slot or "default"
	if not SM.layout[slot] then SM.layout[slot] = lay end
	return n
end

local function detector_args(desync)
	local a = {}
	for k, v in pairs(desync.arg) do a[k] = v end
	return setmetatable({ arg = a }, { __index = desync }), a
end

-- ── TCP Connection Monitor (/proc/net/tcp) ───────────────────────────
local function proc_ip(h)
	local function v4(x)
		return string.format("%d.%d.%d.%d", tonumber(x:sub(7, 8), 16), tonumber(x:sub(5, 6), 16),
			tonumber(x:sub(3, 4), 16), tonumber(x:sub(1, 2), 16))
	end
	if #h == 8 then return v4(h) end
	h = h:lower()
	if h:sub(1, 24) == "0000000000000000ffff0000" then return v4(h:sub(25, 32)) end
	local g = {}
	for i = 0, 3 do
		local w = h:sub(i * 8 + 1, i * 8 + 8)
		local b = w:sub(7, 8) .. w:sub(5, 6) .. w:sub(3, 4) .. w:sub(1, 2)
		g[#g + 1] = b:sub(1, 4); g[#g + 1] = b:sub(5, 8)
	end
	return table.concat(g, ":")
end
-- Hex address normalization for IPv4 and IPv6
local function norm_ip(s)
	if not s then return nil end
	s = s:lower()
	local m4 = s:match("^::ffff:(%d+%.%d+%.%d+%.%d+)$")
	if m4 then return m4 end
	if not s:find(":") then return s end
	local function split(x) local t = {}; for p in x:gmatch("[^:]+") do t[#t + 1] = p end; return t end
	local head, tail = s:match("^(.-)::(.*)$")
	local parts
	if head then
		local a, b = split(head), split(tail)
		parts = a
		for _ = 1, 8 - #a - #b do parts[#parts + 1] = "0" end
		for _, p in ipairs(b) do parts[#parts + 1] = p end
	else parts = split(s) end
	for i, p in ipairs(parts) do parts[i] = string.rep("0", 4 - #p) .. p end
	return table.concat(parts, ":")
end

-- Check for stalled connections with active retransmit timers
local function scan_sockets()
	local stuck, alive = {}, {}
	for _, path in ipairs(SM.proc) do
		local f = io.open(path, "r")
		if f then
			f:read("*l")
			for line in f:lines() do
				local lp, rip, rp, st, tr, retr, uid = line:match("^%s*%d+:%s+%x+:(%x+)%s+(%x+):(%x+)%s+(%x%x)%s+%x+:%x+%s+(%x%x):%x+%s+(%x+)%s+(%d+)")
				if lp and st == "01" and tonumber(uid) >= APP_UID then
					if tr == "01" and tonumber(retr, 16) >= STUCK_RETRANS then
						stuck[tonumber(lp, 16)] = proc_ip(rip)
					elseif tonumber(retr, 16) == 0 then
						alive[tonumber(lp, 16)] = proc_ip(rip)
					end
				end
			end
			f:close()
		end
	end
	return stuck, alive
end

-- Emit smart_kill signal for service.sh to send TCP RST
local function kill_conns(lines)
	if #lines == 0 or not SM.home then return end
	local f = io.open(SM.home .. "/state/smart_kill", "a")
	if f then f:write(table.concat(lines, "\n"), "\n"); f:close() end
end
local function kill_line(ip, lp) return (ip:find(":") and "6 " or "4 ") .. ip .. " " .. lp end

function smart_watch()
	local ok, err = pcall(function()
		local t = now()
		-- Idle monitor when no connections are active
		local busy = t - SM.lastconn <= 120
		if not busy then
			for _, c in pairs(SM.conns) do
				if not c.done and not c.stuck and (c.ok or c.maxin >= ANSWER) and (c.cr or 0) < CREDIT_MAX and t - c.t <= 1800 then busy = true; break end
			end
		end
		if not busy then return end
		local stuck, alive = scan_sockets()
		local hits, keys, nkeys, ips, nips = {}, {}, 0, {}, 0
		for lp, ip in pairs(stuck) do
			if not ips[ip] then ips[ip] = true; nips = nips + 1 end
			local c = SM.conns[lp]
-- Port reuse check: verify remote address matches
			if c and c.ip ~= ip then c = nil end
-- Skip duplicate processing for already resolved connections
			if c and c.done and not c.failed then c = nil end
			local cr = c and SM.db[c.key]
			if c and not c.stuck and t - c.t >= 3 and not (cr and cr.nodpi and cr.nodpi > t) then
-- Require stall detection across two consecutive checks
				if c.suspect then
					hits[#hits + 1] = { c = c, ip = ip, lp = lp }
					if not keys[c.key] then keys[c.key] = true; nkeys = nkeys + 1 end
				end
				c.suspect = true
			end
		end
		for lp, c in pairs(SM.conns) do
			if c.suspect and not stuck[lp] then c.suspect = nil end
-- Expire tracking for closed connections (>30m old)
			if (not stuck[lp] and not alive[lp] and t - c.t > 15) or t - c.t > 1800 then SM.conns[lp] = nil end
		end
		-- Credit sustained keep-alive / HTTP/2 sessions
		for lp, c in pairs(SM.conns) do
			local r = alive[lp] == c.ip and not c.done and not c.stuck and SM.db[c.key]
			if r then
				if not c.ok and c.maxin >= ANSWER and t - c.t >= ALIVE_OK then
					c.ok = true
					on_ok(c.slot, r, c.v, t, c)
				elseif c.ok then
					local due = math.min(CREDIT_MAX, math.floor((t - (c.okt or c.t)) / CREDIT_STEP) * CREDIT_W)
					if due > (c.cr or 0) then
						credit(c.slot, r, c.v, due - (c.cr or 0), t, c)
						c.cr = due
					end
				end
			end
		end
		if #hits == 0 then return end
		-- Correlate multi-host stall as network degradation rather than DPI
		local network = nips >= NET_STUCK_IPS or (nkeys >= 3 and t - SM.lastok > 10)
		local kill = {}
		for _, h in ipairs(hits) do
			local c = h.c
			c.stuck = true
			if not network then
				local r = SM.db[c.key]
				if r and not c.done then
				-- Distinguish mid-stream stall from initial handshake failure
					DLOG("smart: " .. c.key .. ": connection :" .. h.lp .. " stuck " .. (c.ok and "mid-stream" or "before any answer") .. " on variant " .. c.v)
					SJ(c.key .. ": connection stuck " .. (c.ok and "mid-stream" or "before server response") .. " — error " .. vname(c.slot, c.v) .. ", cutting")
					c.done, c.failed = true, true
					on_err(c.slot, c.key, r, c.v, c.n, t, c.pass, c.ok, c)
				end
-- Terminate stalled connection immediately
				kill[#kill + 1] = kill_line(h.ip, h.lp)
			end
		end
		-- Kill stalled connection so application reconnects on new variant
		kill_conns(kill)
	end)
	if not ok then DLOG_ERR("smart_watch: " .. tostring(err)) end
end

local function watch_start()
	if SM.watching or not timer_set then return end
	SM.watching = true
	timer_set("smart_watch", smart_watch, WATCH_MS, false)
end

function smart(ctx, desync)
	orchestrate(ctx, desync)
	if not desync.track then
		DLOG_ERR("smart: conntrack is missing but required")
		return replay_execution_plan(desync)
	end
	if not SM.home then SM.home = desync.arg.home or "/data/adb/nfqws2" end
	local t = now()
	check_net()
	check_bench(t)
	if SM.dirty and t - SM.saved >= SAVE_EVERY then save() end

	local slot = desync.arg.slot or "default"
	local host = site_key(desync)
	local nall = count_strategies(desync)
	local n = nall
-- Extended pool disabled: restrict search to base set
	if desync.arg.base and not SM.pool_ext then
		SM.allow[slot], SM.nallow[slot] = base_set(desync.arg.base, nall)
	else
		SM.allow[slot], SM.nallow[slot] = nil, nil
	end
	if not host or n == 0 then
		local verdict = VERDICT_PASS
		while true do
			local instance = plan_instance_pop(desync)
			if not instance then break end
			if not instance.arg.strategy or tonumber(instance.arg.strategy) == 1 then
				verdict = plan_instance_execute(desync, verdict, instance)
			end
		end
		return verdict
	end

	local key = slot .. "|" .. host
	local pass = tonumber(desync.arg.pass)
	local r = SM.db[key]
	if not r then
		r = newrec(leader(slot, n, tonumber(desync.arg.first) or 1, pass))
		SM.db[key] = r
	end
-- Fallback to starting variant if current variant is outside active pool
	local cb = base_of(slot, r.cur)
	if cb > n or not allowed(slot, cb) then
		r.cur = leader(slot, n, tonumber(desync.arg.first) or 1, pass)
	end
	r.seen = t

	local crec = automate_conn_record(desync)
-- Benchmark override: variant forced by test runner
	if crec and not crec.smart and SM.bench then
		local bv = bench_variant(host, desync.track and desync.track.hostname)
		if bv then
			-- Name probe ('-'): test variant without resetting learned state
			bv = bv == "-" and r.cur or tonumber(bv)
-- Resolve mutation base variant
			if base_of(slot, bv) > nall then bv = 0 end
			crec.smart = { bench = true, done = true, v = bv, maxin = 0, tin = t, t = t }
			local f = io.open(SM.home .. "/state/smart_bench.seen", "a")
			if f then f:write(host, "\t", slot, "\t", nall, "\t", bv, "\n"); f:close() end
		end
	end
	if crec and not crec.smart then
		-- Track connection under active host variant
		crec.smart = { maxin = 0, tin = t, v = r.cur, key = key, slot = slot, n = n, pass = pass, t = t, first = tonumber(desync.arg.first) or 1 }
		-- Detect ~16 KB stream cutoff based on prior connection byte count
		local prev = r.lastc
		if prev and not prev.done and prev.maxin >= 14000 and prev.maxin < 17000 and t - prev.tin <= 30 then
			prev.done = true
			DLOG("smart: " .. key .. ": previous connection stalled at " .. prev.maxin .. " bytes")
			SJ(key .. ": connection stalled at " .. prev.maxin .. " bytes (16KB cut) — error " .. vname(slot, prev.v))
-- Mark as mid-stream cutoff if initial payload succeeded (>4 KB)
			on_err(slot, key, r, prev.v, n, t, pass, prev.ok, prev)
		end
		r.lastc = crec.smart
-- Map local port to host and strategy for watcher
		if desync.dis.tcp and desync.outgoing then
			crec.smart.ip = desync.target and norm_ip(host_ip(desync))
			SM.conns[desync.dis.tcp.th_sport] = crec.smart
			SM.lastconn = t
			watch_start()
		end
	end
	local cs = crec and crec.smart
	if cs and not cs.done then
		local okin = tonumber(desync.arg.okin) or 4096
		local tcp = desync.dis.tcp
		if tcp and not desync.outgoing and #desync.dis.payload > 0 then
			local p = pos_get(desync, 'p')
			if p > cs.maxin then cs.maxin = p end
			cs.tin = t
		end
		local fin = tcp and bitand(tcp.th_flags, TH_FIN) ~= 0
		local rst = tcp and bitand(tcp.th_flags, TH_RST) ~= 0
		-- Detect post-handshake freeze (repeated resends of same segment without server reply)
		if tcp and not fin and not rst then
			if desync.outgoing then
				local len = #desync.dis.payload
				if len > 0 then
					local s = pos_get(desync, 's')
					if (cs.ok or cs.maxin >= ANSWER) and cs.outmax and s < cs.outmax
						and cs.maxin < 18000 and (cs.nin or 0) < FROZEN_IN then
						if s == cs.rtxs then cs.rtx = (cs.rtx or 0) + 1 else cs.rtxs, cs.rtx = s, 1 end
					else
						cs.rtxs, cs.rtx = nil, 0
					end
					if not cs.outmax or s + len > cs.outmax then cs.outmax = s + len end
				end
			else
				cs.rtxs, cs.rtx = nil, 0
				cs.nin = (cs.nin or 0) + 1
			end
		end
		if (cs.rtx or 0) >= FROZEN_RTX then
			cs.done, cs.failed, cs.stuck = true, true, true
			local lp = tcp.th_sport
			DLOG("smart: " .. key .. ": connection :" .. lp .. " frozen after the answer on variant " .. cs.v)
			if r.nodpi and r.nodpi > t then
				SJ(key .. ": connection frozen after first response — cutting, app will reopen")
			else
				SJ(key .. ": connection frozen after first response — error " .. vname(slot, cs.v) .. ", cutting")
				on_err(slot, key, r, cs.v, n, t, pass, true, cs)
			end
			if cs.ip then kill_conns({ kill_line(cs.ip, lp) }) end
		elseif fin or (rst and desync.outgoing) then
			-- Clean teardown (FIN/app RST) counts as success
			cs.done = true
			if not cs.ok and cs.maxin >= ANSWER then
				cs.ok = true
				on_ok(slot, r, cs.v, t, cs)
			end
		elseif rst and (cs.ok or cs.maxin >= ANSWER) then
			-- Server RST after data response is not considered a DPI block
			cs.done = true
			DLOG("smart: " .. key .. ": server reset after " .. cs.maxin .. " bytes — not counted")
		elseif not cs.ok then
			local dd, a = detector_args(desync)
			a.inseq = tostring(okin)
			if standard_success_detector(dd, crec) then
-- Mark success and continue watching for 16 KB cutoff
				cs.ok = true
				on_ok(slot, r, cs.v, t, cs)
			else
-- Server RST during handshake considered DPI block
				a.inseq = tostring(ANSWER)
				local fail = standard_failure_detector(dd, crec)
				if fail then
					cs.done, cs.failed = true, true
					on_err(slot, key, r, cs.v, n, t, pass, false, cs)
				end
			end
		end
	end

	-- Complete connection under its originating variant
	local v = cs and cs.v or r.cur
	if not (cs and cs.bench) then
		local bv = base_of(slot, v)
		if bv > n or not allowed(slot, bv) then v = r.cur end
		if base_of(slot, v) > n then v = 1 end
	end
-- Execute mutation instances with modified parameters
	local m = mutant(slot, v)
	local base, ov = m and m.base or v, nil
	if m then
		ov = {}
		for _, c in ipairs(m.ch) do ov[c.i] = ov[c.i] or {}; ov[c.i][c.k] = c.val end
	end
	local verdict, idx = VERDICT_PASS, 0
	while true do
		local instance = plan_instance_pop(desync)
		if not instance then break end
		local s = tonumber(instance.arg.strategy)
		if s == base then
			idx = idx + 1
			local o = ov and ov[idx]
			if o then
				local copy = {}
				for k, x in pairs(instance) do copy[k] = x end
				copy.arg = {}
				for k, x in pairs(instance.arg) do copy.arg[k] = x end
				for k, x in pairs(o) do gene_set(copy.arg, k, x) end
-- Custom instance cutoff threshold
				copy.func_instance = instance.func_instance .. "~" .. v
				instance = copy
			end
		end
		if not s or s == base then
			verdict = plan_instance_execute(desync, verdict, instance)
		end
	end
	return verdict
end

-- ── Strategy Statistics Collector (smartstat) ─────────────────────────
SMART_STAT = SMART_STAT or { ok = 0, err = 0, since = 0, name = nil, dirty = false, saved = 0, netcheck = 0, offline = false }
local function stat_file(home) return home .. "/state/strat_stat" end
local function stat_load(st, home, name)
	st.name, st.ok, st.err, st.since = name, 0, 0, now()
	local f = io.open(stat_file(home), "r")
	if not f then return end
	for line in f:lines() do
		local n, ok, err, since = line:match("^(%S+)\t(%d+)\t(%d+)\t(%d+)")
		if n == name then st.ok, st.err, st.since = tonumber(ok), tonumber(err), tonumber(since) end
	end
	f:close()
end
local function stat_save(st, home)
	st.saved = now()
	if not st.dirty then return end
	local lines, f = {}, io.open(stat_file(home), "r")
	if f then
		for line in f:lines() do
			local n = line:match("^(%S+)\t")
			if n and n ~= st.name then lines[#lines + 1] = line end
		end
		f:close()
	end
	lines[#lines + 1] = st.name .. "\t" .. st.ok .. "\t" .. st.err .. "\t" .. st.since
	f = io.open(stat_file(home) .. ".tmp", "w")
	if not f then return end
	f:write(table.concat(lines, "\n"), "\n")
	f:close()
	os.rename(stat_file(home) .. ".tmp", stat_file(home))
	st.dirty = false
end
function smartstat(ctx, desync)
	local st = SMART_STAT
	if not desync.track or not desync.dis.tcp then return end
	local home = desync.arg.home or "/data/adb/nfqws2"
	local name = (desync.arg.name or "default"):gsub("[^%w%._%-]", "_")
	if st.name ~= name then stat_load(st, home, name) end
	local t = now()
	if t - st.netcheck >= NET_EVERY then
		st.netcheck = t
		st.offline = readline(home .. "/state/smart_net") == "offline"
	end
	local crec = automate_conn_record(desync)
	local cs = crec.sstat
	if not cs then cs = { maxin = 0 }; crec.sstat = cs end
	if cs.done then return end
	local tcp = desync.dis.tcp
	if not desync.outgoing and #desync.dis.payload > 0 then
		local p = pos_get(desync, 'p')
		if p > cs.maxin then cs.maxin = p end
	end
	local fin = bitand(tcp.th_flags, TH_FIN) ~= 0
	local rst = bitand(tcp.th_flags, TH_RST) ~= 0
	local res
	if fin or (rst and desync.outgoing) then
		cs.done = true
		if cs.maxin >= ANSWER then res = "ok" end
	elseif rst then
		cs.done = true
		if cs.maxin < ANSWER then res = "err" end
	else
		local dd, a = detector_args(desync)
		a.inseq = "4096"
		if standard_success_detector(dd, crec) then res = "ok"
		else
			a.inseq = tostring(ANSWER)
			local fail = standard_failure_detector(dd, crec)
			if fail then res = "err" end
		end
		if res then cs.done = true end
	end
	if res and not st.offline then
		if res == "ok" then st.ok = st.ok + 1 else st.err = st.err + 1 end
		st.dirty = true
	end
	if st.dirty and t - st.saved >= SAVE_EVERY then stat_save(st, home) end
-- Connection outcome recorded, bypass further inspection
	if cs.done and ctx then instance_cutoff_shim(ctx, desync) end
end

-- ---------------------------------------------------------------- hostfakesplit_alt
-- hostfakesplit variant preserving zapret 1 altorder=1 sequencing
function hostfakesplit_alt(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
		DLOG("hostfakesplit_alt: blob '" .. desync.arg.blob .. "' not found. skipped")
		return
	end
	local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
	if #data > 0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
			if pos then
				DLOG("hostfakesplit_alt: host range " .. (pos[1] - 1) .. "-" .. (pos[2] - 1))
				local orig = { rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {},
					ipid = desync.arg, fooling = { tcp_ts_up = desync.arg.tcp_ts_up } }
				local fake = { rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {},
					ipid = desync.arg, fooling = desync.arg }
				if not rawsend_payload_segmented(desync, string.sub(data, 1, pos[1] - 1), 0, orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, genhost(pos[2] - pos[1] + 1, desync.arg.host), pos[1] - 1, fake) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, string.sub(data, pos[2] + 1), pos[2], orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, string.sub(data, pos[1], pos[2]), pos[1] - 1, orig) then return VERDICT_PASS end
				replay_drop_set(desync)
				return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
			end
		end
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end
