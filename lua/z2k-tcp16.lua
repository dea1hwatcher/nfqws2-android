-- z2k-tcp16.lua — 16 KB cutoff bypass: whitelisted SNI substitution by network.
--
-- Blocking pattern: ISP passes handshake and first 15-16 KB of payload, then flow stalls.
-- Strategy rotation does not help; flow is unblocked by a fake ClientHello carrying
-- a whitelisted domain recognized by the ISP DPI.
--
-- Runtime only. Does not detect or rotate: probe discovers line block and matching names,
-- passing ready AS -> domain map here. Map destination IP -> AS -> SNI -> blob z2k_ch
-- sent via standard fake:optional.
--
-- File paths (overrideable via environment variables for testing):
--   state/tcp16_asn.txt   — confirmed blocked ASNs (Z2K_TCP16_ASN)
--   lists/tcp16_nets.txt  — "ASN<TAB>prefix", coarsened to /16 and /32 (Z2K_TCP16_NETS)
--   state/tcp16_sni.txt   — "ASN<TAB>domain" (Z2K_TCP16_SNI)
--   lists/sni_wl_pin.txt  — manual single domain pin for entire link (Z2K_SNI_PIN)
--
-- Loaded AFTER zapret-lib.lua and zapret-antidpi.lua: requires blob, tls_mod.

-- Assign SNI only to subnets where 16 KB blocking is confirmed.
-- Coarsening to /16 (v4) and /32 (v6) reduces 52k prefixes to 6k.
local function z2k_nets_load()
	if z2k_nets_loaded then return z2k_nets end
	z2k_nets_loaded = true
	local asnpath = os.getenv("Z2K_TCP16_ASN") or "/opt/zapret2/state/tcp16_asn.txt"
	local f = io.open(asnpath, "r")
	if not f then return nil end
	local want, n = {}, 0
	for line in f:lines() do
		local a = line:match("^(%d+)")
		if a then want[a] = true; n = n + 1 end
	end
	f:close()
	if n == 0 then return nil end

	local netpath = os.getenv("Z2K_TCP16_NETS") or "/opt/zapret2/lists/tcp16_nets.txt"
	local nf = io.open(netpath, "r")
	if not nf then return nil end
	local set, cnt = {}, 0
	for line in nf:lines() do
		local a, p = line:match("^(%d+)\t([^%s]+)")
		if a and p and want[a] then
  -- v4 "a.b.0.0/16" keyed by a*256+b, v6 "xxxx:yyyy::/32" by first two words.
			local o1, o2 = p:match("^(%d+)%.(%d+)%.")
			if o1 then
				set[tonumber(o1) * 256 + tonumber(o2)] = a
				cnt = cnt + 1
			else
				local g1, g2 = p:match("^(%x+):(%x*):")
				if g1 then
					set[(g1 or "") .. ":" .. (g2 or "")] = a
					cnt = cnt + 1
				end
			end
		end
	end
	nf:close()
	if cnt == 0 then return nil end
	DLOG("z2k_tcp16: network map loaded, " .. cnt .. " entries")
	z2k_nets = set
	return set
end

-- Lookup ASN for destination address.
local function z2k_asn_of(desync)
	local set = z2k_nets_load()
	if not set then return nil end
	local d = desync and desync.dis
	if not d then return nil end
	if d.ip and d.ip.ip_dst then
		local b = d.ip.ip_dst
		if #b >= 2 then return set[b:byte(1) * 256 + b:byte(2)] end
	elseif d.ip6 and d.ip6.ip6_dst then
		local b = d.ip6.ip6_dst
		if #b >= 4 then
			local g1 = string.format("%x", b:byte(1) * 256 + b:byte(2))
			local g2 = string.format("%x", b:byte(3) * 256 + b:byte(4))
			return set[g1 .. ":" .. g2] or set[g1 .. ":"]
		end
	end
	return nil
end

-- Per-network domain mapping (different ASNs require different whitelisted domains).
local z2k_asn_sni, z2k_asn_sni_loaded = nil, false
local function z2k_asn_sni_load()
	if z2k_asn_sni_loaded then return z2k_asn_sni end
	z2k_asn_sni_loaded = true
	local path = os.getenv("Z2K_TCP16_SNI") or "/opt/zapret2/state/tcp16_sni.txt"
	local f = io.open(path, "r")
	if not f then return nil end
	local m, n = {}, 0
	for line in f:lines() do
		local a, nm = line:match("^(%d+)\t([%w%.%-]+)")
		if a and nm then m[a] = nm; n = n + 1 end
	end
	f:close()
	if n == 0 then return nil end
	DLOG("z2k_tcp16: network names map loaded, " .. n .. " networks")
	z2k_asn_sni = m
	return m
end

-- Pinned domain override: manual single-domain fallback when no map is available.
-- Throttled to max 1 read per second.
local z2k_pin_name, z2k_pin_at = nil, 0
local Z2K_PIN_RECHECK = tonumber(os.getenv("Z2K_PIN_RECHECK")) or 1
function z2k_sni_pinned()
	local now = os.time()
	if now < (z2k_pin_at + Z2K_PIN_RECHECK) then return z2k_pin_name end
	z2k_pin_at = now
	z2k_pin_name = nil
	local path = os.getenv("Z2K_SNI_PIN") or "/opt/zapret2/lists/sni_wl_pin.txt"
	local f = io.open(path, "r")
	if not f then return nil end
	local raw = f:read("*l")
	f:close()
	if not raw then return nil end
	local nm = raw:gsub("#.*", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if nm == "" or #nm > 253 or nm:find("[^%w%.%-]") then return nil end
	z2k_pin_name = nm
	return nm
end

-- Resolve domain for address: specific for ASN, pinned fallback, or nil if unmapped.
function z2k_sni_for(desync, pin)
	local m = z2k_asn_sni_load()
	if not m then return pin end
	local asn = z2k_asn_of(desync)
	if asn and m[asn] then return m[asn] end
	return nil
end

-- Inject domain into fake ClientHello blob for desync: prepares blob and stores in desync,
-- sent via standard fake:optional. Positioned before circular without strategy=N.
function z2k_sni_pick(ctx, desync)
	direction_cutoff_opposite(ctx, desync)
	if not desync.dis or not desync.dis.tcp then return end
	if not (direction_check(desync) and payload_check(desync)) then return end
	if not replay_first(desync) then return end

	local name = z2k_sni_for(desync, z2k_sni_pinned())
	if not name then return end

  -- Clone real ClientHello: preserve user TLS fingerprint, swapping only the SNI.
  -- Fallback to builtin blob + tls_mod if dissection fails.
	local ch
	local okc, cloned = pcall(tls_client_hello_mod, desync.reasm_data or desync.dis.payload,
		{ sni_del = true, sni_first = name, sni_snt_new = 0 })
	if okc and cloned then
  -- Standard decoration: randomized client random, real session ID.
		local okm, mod = pcall(tls_mod, cloned, "rnd,dupsid", desync.reasm_data or desync.dis.payload)
		ch = (okm and mod) or cloned
	else
		local base = blob(desync, desync.arg.src or "fake_default_tls")
		if not base then return end
		local mods = (desync.arg.mods or "rnd,dupsid") .. ",sni=" .. name
		local okm, mod = pcall(tls_mod, base, mods, desync.reasm_data)
		if not okm or not mod then return end
		ch = mod
	end
	desync[desync.arg.blob or "z2k_ch"] = ch
	if b_debug then
		DLOG("z2k_sni_pick: substituted name " .. name)
	end
end
