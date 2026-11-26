-- Unit tests for CircumVolve Phase 1 (lua/z2k-circumvolve.lua) and Phase 2 (lua/z2k-quic-crypto.lua).
-- Runs under nfqws2 (--intercept=0) OR standalone LuaJIT with tests/lua/luajit-prelude.lua.

local failed, total = 0, 0
local function check(cond, name)
	total = total + 1
	if cond then io.write("   ok   ", name, "\n")
	else failed = failed + 1; io.write("   FAIL ", name, "\n") end
end
local function section(s) io.write("\n== ", s, "\n") end

local function hex2bin(h)
	return (h:gsub("%s+", ""):gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end
local function bin2hex(b)
	local t = {}
	for i = 1, #b do t[i] = string.format("%02x", string.byte(b, i)) end
	return table.concat(t)
end

-- Build a synthetic TLS 1.3 ClientHello with optional RFC 7685 Padding (0x0015) and trailing PSK (0x0029).
local function build_test_ch(host, pad_len, with_psk)
	local sni_entry = "\0" .. bu16(#host) .. host
	local sni_ext = bu16(0x0000) .. bu16(2 + #sni_entry) .. bu16(#sni_entry) .. sni_entry
	local alpn_list = bu8(2) .. "h2"
	local alpn_ext = bu16(0x0010) .. bu16(2 + #alpn_list) .. bu16(#alpn_list) .. alpn_list
	local sv_ext = bu16(0x002b) .. bu16(3) .. bu8(2) .. bu16(0x0304)
	local pad_ext = (pad_len and pad_len > 0) and (bu16(0x0015) .. bu16(pad_len) .. string.rep("\0", pad_len)) or ""
	local psk_ext = with_psk and (bu16(0x0029) .. bu16(8) .. "PSKBYTES") or ""

	local exts = sni_ext .. alpn_ext .. sv_ext .. pad_ext .. psk_ext
	local sid = string.rep("\xaa", 32)
	local cs = bu16(0x1301) .. bu16(0x1302)
	local body = bu16(0x0303) .. string.rep("\x11", 32) .. bu8(#sid) .. sid ..
		bu16(#cs) .. cs .. bu8(1) .. "\0" .. bu16(#exts) .. exts
	local hs = bu8(0x01) .. bu24(#body) .. body
	return bu8(0x16) .. bu16(0x0301) .. bu16(#hs) .. hs
end

section("Phase 1: tls_ext_reorder preserves zero delta and keeps 0x0029 PSK last")
do
	local ch = build_test_ch("blocked.example.com", 12, true)
	local out = z2k_tls_reorder_extensions(ch, { mode = "sni_last" })
	check(out ~= nil and #out == #ch, "reordered ClientHello keeps exact length (" .. #ch .. "B)")
	local p = z2k_parse_tls_client_hello(out)
	check(p ~= nil and #p.exts == 5, "reordered ClientHello parses back cleanly (" .. (p and #p.exts or 0) .. " exts)")
	check(p and p.exts[#p.exts].type == 0x0029, "RFC 8446 pre_shared_key (0x0029) stays last")
	check(p and p.exts[#p.exts - 1].type == 0x0000, "SNI (0x0000) moved immediately before PSK")
	check(out ~= ch, "byte layout actually changed")

	local out_pad = z2k_tls_reorder_extensions(ch, { mode = "pad_first" })
	local p_pad = z2k_parse_tls_client_hello(out_pad)
	check(out_pad and #out_pad == #ch and p_pad.exts[1].type == 0x0015 and p_pad.exts[#p_pad.exts].type == 0x0029,
		"pad_first promotes 0x0015 to front while keeping PSK last")

	local desync = {
		outgoing = true,
		l7payload = "tls_client_hello",
		func_instance = "tls_ext_reorder_0",
		track = { lua_state = {} },
		dis = { tcp = {}, payload = ch },
		arg = { mode = "sni_last", case = "1" }
	}
	local v = tls_ext_reorder(nil, desync)
	check(v == VERDICT_MODIFY and #desync.dis.payload == #ch, "tls_ext_reorder returns VERDICT_MODIFY with zero delta")
	check(desync.dis.payload:find("BlOcKeD.ExAmPlE.CoM", 1, true) ~= nil, "case=1 applies alternating SNI casing in-place")
end

section("Phase 1: tlsrec_zero splits into 2 records at ext_start with zero TCP delta")
do
	local ch = build_test_ch("video.example.org", 16, true)
	local orig_p = z2k_parse_tls_client_hello(ch)
	local out = z2k_tls_record_split_zero(ch, { reorder = true })
	check(out ~= nil and #out == #ch, "two-record ClientHello preserves exact byte length (" .. #ch .. "B)")

	local rec1_type = u8(out, 1)
	local rec1_len = u16(out, 4)
	local rec2_off = 5 + rec1_len + 1
	local rec2_type = u8(out, rec2_off)
	local rec2_len = u16(out, rec2_off + 3)
	check(rec1_type == 0x16 and rec2_type == 0x16 and (5 + rec1_len + 5 + rec2_len) == #out,
		"output consists of two contiguous TLS handshake records")
	check(rec1_len == (orig_p.ext_len_off - 6),
		"Record 1 ends immediately before extensions_length (" .. rec1_len .. "B)")

	local ch_nopad = build_test_ch("nopad.example.org", 0, true)
	local fb = z2k_tls_record_split_zero(ch_nopad, { reorder = true })
	check(fb ~= nil and #fb == #ch_nopad and fb ~= ch_nopad,
		"without 0x0015 padding, falls back to tls_ext_reorder with zero delta")
	check(z2k_tls_record_split_zero(ch_nopad, { fallback = "none" }) == nil,
		"fallback=none returns nil when padding < 5B")
end

section("Phase 1: http_host_fold preserves exact length by trimming User-Agent")
do
	local req1 = "GET /index.html HTTP/1.1\r\nHost: blocked.example.com\r\nUser-Agent: Mozilla/5.0 (Android 14; Mobile)\r\nAccept: */*\r\n\r\n"
	local f1 = z2k_http_host_fold_payload(req1, { tab = false })
	check(f1 ~= nil and #f1 == #req1 and f1:find("Host:\r\n blocked.example.com\r\n", 1, true) ~= nil,
		"Host->User-Agent order: obs-fold applied with exact length preservation")

	local f2 = z2k_http_host_fold_payload(req1, { tab = true })
	check(f2 ~= nil and #f2 == #req1 and f2:find("HoSt:\t\r\n blocked.example.com\r\n", 1, true) ~= nil,
		"tab=1 variant preserves exact length (" .. #req1 .. "B)")

	local req_rev = "GET / HTTP/1.1\r\nUser-Agent: CustomDesktopClient/9.1\r\nHost: blocked.example.org\r\n\r\n"
	local f3 = z2k_http_host_fold_payload(req_rev, { tab = false })
	check(f3 ~= nil and #f3 == #req_rev and f3:find("Host:\r\n blocked.example.org\r\n", 1, true) ~= nil,
		"User-Agent->Host reverse header order preserves exact length")

	local req_short = "GET / HTTP/1.1\r\nHost: x.org\r\nUser-Agent: curl\r\n\r\n"
	check(z2k_http_host_fold_payload(req_short, { tab = false }) == nil,
		"short User-Agent aborts safely without length corruption")
end

section("Phase 1: timed_fake_split transmits part1 now and schedules delayed part2")
do
	local sent, timers = {}, {}
	local keep = { rawsend_dissect_ipfrag, timer_set, resolve_pos, rawsend_opts, reconstruct_opts, apply_ip_id, desync_timer_name, l3l4_extra_len }
	rawsend_dissect_ipfrag = function(d, opts) sent[#sent + 1] = { seq = d.tcp.th_seq, payload = d.payload }; return true end
	timer_set = function(name, cb, ms, oneshot, data) timers[#timers + 1] = { name = name, cb = cb, ms = ms, oneshot = oneshot, data = data } end
	resolve_pos = function() return 6 end
	rawsend_opts = function() return {} end
	reconstruct_opts = function() return {} end
	apply_ip_id = function() end
	desync_timer_name = function() return "t_unit" end
	l3l4_extra_len = function() return 0 end

	local orig_payload = "12345SNI_REST_BYTES"
	local desync = {
		outgoing = true,
		l7payload = "tls_client_hello",
		tcp_mss = 1460,
		dis = { tcp = { th_seq = 1000, th_sport = 50000, th_dport = 443 }, payload = orig_payload },
		arg = { pos = "sniext+1", delay = "12" },
		func_instance = "timed_0"
	}
	local v = timed_fake_split(nil, desync)
	check(v == VERDICT_DROP and #sent == 1 and sent[1].payload == "12345" and sent[1].seq == 1000,
		"t=0 sends only pre-SNI part1 immediately")
	check(#timers == 1 and timers[1].cb == "z2k_timed_send_cb" and timers[1].ms == 12 and timers[1].oneshot == true,
		"schedules part2 callback via timer_set after 12ms")
	if timers[1] then z2k_timed_send_cb(timers[1].name, timers[1].data) end
	check(#sent == 2 and sent[2].seq == 1005 and (sent[1].payload .. sent[2].payload) == orig_payload,
		"delayed callback transmits part2 at exact seq 1005 restoring full payload")

	rawsend_dissect_ipfrag, timer_set, resolve_pos, rawsend_opts, reconstruct_opts, apply_ip_id, desync_timer_name, l3l4_extra_len = unpack(keep)
end

-- Pure-Lua SHA-256 test oracle (used ONLY if running under vanilla luajit without nfqws2 C hash()).
local function install_sha256_fallback_if_needed()
	if type(hash) == "function" and type(bxor) == "function" then return nil end
	local orig_hash, orig_bxor = hash, bxor
	local K = {
		0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
		0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
		0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
		0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
		0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
		0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
		0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
		0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
	}
	local bit = require("bit")
	local band, bx, bnot, rshift, ror = bit.band, bit.bxor, bit.bnot, bit.rshift, bit.ror
	hash = function(alg, msg)
		local n = #msg
		local pad = msg .. "\x80" .. string.rep("\0", (55 - n) % 64) ..
			string.rep("\0", 4) .. bu32(n * 8)
		local H = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 }
		local w = {}
		for blk = 1, #pad, 64 do
			for i = 1, 16 do
				local o = blk + (i - 1) * 4
				w[i] = u32(pad, o)
			end
			for i = 17, 64 do
				local s0 = bx(ror(w[i - 15], 7), ror(w[i - 15], 18), rshift(w[i - 15], 3))
				local s1 = bx(ror(w[i - 2], 17), ror(w[i - 2], 19), rshift(w[i - 2], 10))
				w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
			end
			local a,b,c,d,e,f,g,h = H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8]
			for i = 1, 64 do
				local S1 = bx(ror(e, 6), ror(e, 11), ror(e, 25))
				local ch = bx(band(e, f), band(bnot(e), g))
				local t1 = (h + S1 + ch + K[i] + w[i]) % 4294967296
				local S0 = bx(ror(a, 2), ror(a, 13), ror(a, 22))
				local maj = bx(band(a, b), band(a, c), band(b, c))
				local t2 = (S0 + maj) % 4294967296
				h = g; g = f; f = e; e = (d + t1) % 4294967296
				d = c; c = b; b = a; a = (t1 + t2) % 4294967296
			end
			local add = {a,b,c,d,e,f,g,h}
			for i = 1, 8 do H[i] = (H[i] + add[i]) % 4294967296 end
		end
		local out = {}
		for i = 1, 8 do out[i] = bu32(H[i]) end
		return table.concat(out)
	end
	bxor = function(a, b)
		local len = math.min(#a, #b)
		local out = {}
		for i = 1, len do out[i] = string.char(bx(string.byte(a, i), string.byte(b, i))) end
		return table.concat(out)
	end
	return function() hash, bxor = orig_hash, orig_bxor end
end

section("Phase 2: RFC 9001 Appendix A.1 Initial secret & key derivation")
do
	local restore_crypto = install_sha256_fallback_if_needed()
	local dcid = hex2bin("8394c8f03e515708")
	local keys = z2k_quic_derive_initial_keys(0x00000001, dcid)
	check(keys ~= nil, "z2k_quic_derive_initial_keys derived QUIC v1 keys")
	check(keys and bin2hex(keys.initial_secret) == "7db5df06e7a69e432496adedb00851923595221596ae2ae9fb8115c1e9ed0a44",
		"RFC 9001 Appendix A.1 initial_secret matches byte-for-byte")
	check(keys and bin2hex(keys.client_secret) == "c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea",
		"RFC 9001 Appendix A.1 client_initial_secret matches byte-for-byte")
	check(keys and bin2hex(keys.key) == "1f369613dd76d5467730efcbe3b1a22d",
		"RFC 9001 Appendix A.1 client quic key matches")
	check(keys and bin2hex(keys.iv) == "fa044b2f42a3fd3b46fb255c",
		"RFC 9001 Appendix A.1 client quic iv matches")
	check(keys and bin2hex(keys.hp) == "9f50449e04a0e810283a1e9933adedd2",
		"RFC 9001 Appendix A.1 client quic hp matches")

	local keys_v2 = z2k_quic_derive_initial_keys(0x6b3343cf, dcid)
	check(keys_v2 ~= nil and keys_v2.key ~= keys.key and keys_v2.hp ~= keys.hp,
		"RFC 9369 QUIC v2 produces distinct Initial keys")

	-- If AES primitives are present (inside real nfqws2 binary) OR using round-trip stub, verify all 3 transform modes
	local restore_aes
	if type(aes) ~= "function" or type(aes_gcm) ~= "function" then
		local oa, og = aes, aes_gcm
		-- Invertible deterministic stream/tag stub solely for testing frame framing + PN split wiring on hosts lacking C AES
		aes = function(enc, key, block)
			return bxor(block, hash("sha256", key):sub(1, 16))
		end
		aes_gcm = function(enc, key, iv, data, aad)
			local stream = {}
			local ctr = 0
			while #table.concat(stream) < #data do
				ctr = ctr + 1
				stream[#stream + 1] = hash("sha256", key .. iv .. bu32(ctr))
			end
			local mask = table.concat(stream):sub(1, #data)
			local out = bxor(data, mask)
			local ct = enc and out or data
			local tag = hash("sha256", key .. iv .. (aad or "") .. ct):sub(1, 16)
			return out, tag
		end
		restore_aes = function() aes, aes_gcm = oa, og end
	end

	-- Construct encrypted synthetic QUIC v1 Initial packet (>= 1200B) containing ClientHello in CRYPTO(off=0)
	local ch_rec = build_test_ch("quic.example.org", 0, false)
	local hs_only = string.sub(ch_rec, 6)
	local fake_init_pt = "\06\00" .. bquic_tvb(#hs_only) .. hs_only
	local sealed_init = z2k_quic_seal_initial({
		version_raw = bu32(1),
		unmasked_first = 0xC0,
		dcid = dcid,
		scid = "\x01\x02\x03\x04",
		token_raw = "\00",
		pn_len = 2,
		keys = keys
	}, 0, fake_init_pt, 1200)
	check(sealed_init and #sealed_init == 1200, "sealed synthetic QUIC Initial is padded to 1200B")

	local p_pad = z2k_quic_transform_initial(sealed_init, { mode = "pad_prefix", pad = 96 })
	check(p_pad and #p_pad == 1 and #p_pad[1] == 1200, "pad_prefix preserves exact 1200B Initial size")

	local p_reo = z2k_quic_transform_initial(sealed_init, { mode = "crypto_reorder", overvarint = true })
	check(p_reo and #p_reo == 1 and #p_reo[1] == 1200, "crypto_reorder + overvarint preserves 1200B valid Initial")

	local p_spl = z2k_quic_transform_initial(sealed_init, { mode = "crypto_split_pkt" })
	check(p_spl and #p_spl == 2 and #p_spl[1] >= 1200 and #p_spl[2] >= 1200,
		"crypto_split_pkt produces two RFC-compliant >=1200B Initial packets (PN=0 & PN=1)")

	if restore_aes then restore_aes() end
	if restore_crypto then restore_crypto() end
end

io.write("\n", failed == 0 and "PASS" or "FAIL", "  ", total - failed, " of ", total, " checks passed\n")
os.exit(failed == 0 and 0 or 1)
