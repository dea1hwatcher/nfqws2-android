-- CircumVolve Phase 2: Cryptographically valid QUIC Initial frame desync.
-- Implements RFC 9001 (QUIC v1) and RFC 9369 (QUIC v2) Initial key derivation,
-- AEAD + Header Protection round-trip, and CRYPTO/PADDING frame manipulation.
-- Designed for LuaJIT (nfqws2) and syntactically compatible with Lua 5.4 (CI luac -p).

local QUIC_V1 = 0x00000001
local QUIC_V2 = 0x6b3343cf

-- RFC 9001 Section 5.2 and RFC 9369 Section 3.3.1 initial salts (binary decoded from hex).
local function parse_salt(hex)
	if type(parse_hex) == "function" then return parse_hex(hex) end
	return (hex:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end))
end

local QUIC_SALT_V1 = parse_salt("38762cf7f55934b34d179ae6a4c80cadccbb7f0a")
local QUIC_SALT_V2 = parse_salt("0dede3def700a6db819381be6e269dcbf9bd2ed9")
local IPAD64 = string.rep(string.char(0x36), 64)
local OPAD64 = string.rep(string.char(0x5c), 64)
local ZEROS8 = string.rep("\0", 8)

local function encode_be_uint(v, nbytes)
	local b = {}
	local n = v
	for i = nbytes, 1, -1 do
		b[i] = string.char(n % 256)
		n = math.floor(n / 256)
	end
	return table.concat(b)
end

local function decode_be_uint(s, off, nbytes)
	local v = 0
	for i = 0, nbytes - 1 do
		v = v * 256 + string.byte(s, off + i)
	end
	return v
end

local function encode_tvb_2b(v)
	return bu16(0x4000 + v)
end

function z2k_hmac_sha256(key, msg)
	if type(hash) ~= "function" or type(bxor) ~= "function" then return nil end
	local k = key
	if #k > 64 then k = hash("sha256", k) end
	if #k < 64 then k = k .. string.rep("\0", 64 - #k) end
	local i_key = bxor(k, IPAD64)
	local o_key = bxor(k, OPAD64)
	return hash("sha256", o_key .. hash("sha256", i_key .. msg))
end

function z2k_hkdf_expand_label(prk, label, context, out_len)
	local full = "tls13 " .. label
	local info = bu16(out_len) .. bu8(#full) .. full .. bu8(#context) .. context
	if out_len <= 32 then
		local block = z2k_hmac_sha256(prk, info .. bu8(1))
		if not block then return nil end
		return string.sub(block, 1, out_len)
	end
	local t = ""
	local out = {}
	local ctr = 1
	while ctr * 32 < out_len + 32 do
		t = z2k_hmac_sha256(prk, t .. info .. bu8(ctr))
		if not t then return nil end
		out[#out + 1] = t
		ctr = ctr + 1
	end
	return string.sub(table.concat(out), 1, out_len)
end

function z2k_quic_derive_initial_keys(version, dcid)
	local salt, klabel, ilabel, hlabel
	if version == QUIC_V1 then
		salt = QUIC_SALT_V1
		klabel = "quic key"
		ilabel = "quic iv"
		hlabel = "quic hp"
	elseif version == QUIC_V2 then
		salt = QUIC_SALT_V2
		klabel = "quicv2 key"
		ilabel = "quicv2 iv"
		hlabel = "quicv2 hp"
	else
		return nil
	end
	if type(dcid) ~= "string" or #dcid > 20 then return nil end

	local initial_secret = z2k_hmac_sha256(salt, dcid)
	if not initial_secret then return nil end
	local client_secret = z2k_hkdf_expand_label(initial_secret, "client in", "", 32)
	if not client_secret then return nil end

	local key = z2k_hkdf_expand_label(client_secret, klabel, "", 16)
	local iv = z2k_hkdf_expand_label(client_secret, ilabel, "", 12)
	local hp = z2k_hkdf_expand_label(client_secret, hlabel, "", 16)
	if not (key and iv and hp) then return nil end

	return {
		initial_secret = initial_secret,
		client_secret = client_secret,
		key = key,
		iv = iv,
		hp = hp
	}
end

local function quic_nonce(iv, pn)
	return bxor(iv, ZEROS8 .. encode_be_uint(pn, 4))
end

local function parse_initial_packet(pkt)
	if type(pkt) ~= "string" or #pkt < 40 then return nil end
	if type(aes) ~= "function" or type(aes_gcm) ~= "function" then return nil end

	local first = u8(pkt, 1)
	-- Long header (0x80) and fixed bit (0x40) must be set.
	if bitand(first, 0xC0) ~= 0xC0 then return nil end

	local version = u32(pkt, 2)
	local expected_type
	if version == QUIC_V1 then
		expected_type = 0
	elseif version == QUIC_V2 then
		expected_type = 1
	else
		return nil
	end
	if bitand(bitrshift(first, 4), 0x03) ~= expected_type then return nil end

	local dcid_len = u8(pkt, 6)
	if dcid_len > 20 or 6 + dcid_len > #pkt then return nil end
	local dcid = string.sub(pkt, 7, 6 + dcid_len)
	local pos = 7 + dcid_len

	if pos > #pkt then return nil end
	local scid_len = u8(pkt, pos)
	if scid_len > 20 or pos + scid_len > #pkt then return nil end
	local scid = string.sub(pkt, pos + 1, pos + scid_len)
	pos = pos + 1 + scid_len

	local tok_off = pos
	local tok_len, tok_n = quic_tvb(pkt, pos)
	if not tok_len or type(tok_len) ~= "number" or tok_len > 1200 then return nil end
	pos = pos + tok_n + tok_len
	if pos > #pkt + 1 then return nil end
	local token_raw = string.sub(pkt, tok_off, pos - 1)

	local pkt_len, len_n = quic_tvb(pkt, pos)
	if not pkt_len or type(pkt_len) ~= "number" or pkt_len < 20 then return nil end
	local pn_off = pos + len_n
	local init_end = pn_off + pkt_len - 1
	if init_end > #pkt then return nil end
	if pn_off + 4 + 15 > init_end then return nil end

	local keys = z2k_quic_derive_initial_keys(version, dcid)
	if not keys then return nil end

	local sample = string.sub(pkt, pn_off + 4, pn_off + 19)
	local hp_mask = aes(true, keys.hp, sample)
	if not hp_mask or #hp_mask < 16 then return nil end

	local unmasked_first = bitxor(first, bitand(u8(hp_mask, 1), 0x0F))
	local pn_len = bitand(unmasked_first, 0x03) + 1
	if pn_off + pn_len + 16 - 1 > init_end then return nil end

	local masked_pn = string.sub(pkt, pn_off, pn_off + pn_len - 1)
	local pn_bytes = bxor(masked_pn, string.sub(hp_mask, 2, 1 + pn_len))
	local pn = decode_be_uint(pn_bytes, 1, pn_len)

	local aad = bu8(unmasked_first) .. string.sub(pkt, 2, pn_off - 1) .. pn_bytes
	local ct_all = string.sub(pkt, pn_off + pn_len, init_end)
	local ct = string.sub(ct_all, 1, #ct_all - 16)
	local tag = string.sub(ct_all, #ct_all - 15)

	local plaintext, tag2 = aes_gcm(false, keys.key, quic_nonce(keys.iv, pn), ct, aad)
	if not plaintext or tag2 ~= tag then return nil end

	return {
		version = version,
		version_raw = string.sub(pkt, 2, 5),
		unmasked_first = unmasked_first,
		dcid = dcid,
		scid = scid,
		token_raw = token_raw,
		pn = pn,
		pn_len = pn_len,
		keys = keys,
		plaintext = plaintext,
		init_end = init_end,
		trail = (init_end < #pkt) and string.sub(pkt, init_end + 1) or ""
	}
end

local function parse_initial_frames(pt)
	local pos = 1
	local pad_count = 0
	local cryptos = {}
	local others = {}

	while pos <= #pt do
		local ftype, fn = quic_tvb(pt, pos)
		if not ftype or type(ftype) ~= "number" then return nil end
		local start_pos = pos
		pos = pos + fn

		if ftype == 0x00 then
			local z = pos - 1
			while z <= #pt and string.byte(pt, z) == 0 do
				pad_count = pad_count + 1
				z = z + 1
			end
			pos = z
		elseif ftype == 0x01 then
			others[#others + 1] = string.sub(pt, start_pos, pos - 1)
		elseif ftype == 0x02 or ftype == 0x03 then
			-- ACK frame: largest_acked, ack_delay, ack_range_count, first_ack_range, gaps/lens, optional ECN.
			local _, n1 = quic_tvb(pt, pos); if not n1 then return nil end; pos = pos + n1
			local _, n2 = quic_tvb(pt, pos); if not n2 then return nil end; pos = pos + n2
			local rcnt, n3 = quic_tvb(pt, pos); if not n3 or type(rcnt) ~= "number" or rcnt > 64 then return nil end; pos = pos + n3
			local _, n4 = quic_tvb(pt, pos); if not n4 then return nil end; pos = pos + n4
			for _ = 1, rcnt do
				local _, ng = quic_tvb(pt, pos); if not ng then return nil end; pos = pos + ng
				local _, nl = quic_tvb(pt, pos); if not nl then return nil end; pos = pos + nl
			end
			if ftype == 0x03 then
				for _ = 1, 3 do
					local _, ne = quic_tvb(pt, pos); if not ne then return nil end; pos = pos + ne
				end
			end
			if pos - 1 > #pt then return nil end
			others[#others + 1] = string.sub(pt, start_pos, pos - 1)
		elseif ftype == 0x06 then
			local coff, n1 = quic_tvb(pt, pos); if not n1 or type(coff) ~= "number" then return nil end; pos = pos + n1
			local clen, n2 = quic_tvb(pt, pos); if not n2 or type(clen) ~= "number" then return nil end; pos = pos + n2
			if pos + clen - 1 > #pt then return nil end
			cryptos[#cryptos + 1] = {
				off = coff,
				data = string.sub(pt, pos, pos + clen - 1)
			}
			pos = pos + clen
		else
			-- Unknown/control frame (e.g. CONNECTION_CLOSE): do not rewrite.
			return nil
		end
	end

	if #cryptos == 0 then return nil end
	table.sort(cryptos, function(a, b) return a.off < b.off end)
	local base_off = cryptos[1].off
	local parts = {}
	local cur_off = base_off
	for i = 1, #cryptos do
		if cryptos[i].off ~= cur_off then return nil end
		parts[i] = cryptos[i].data
		cur_off = cur_off + #cryptos[i].data
	end

	return {
		base_off = base_off,
		crypto = table.concat(parts),
		others = table.concat(others),
		pad_count = pad_count
	}
end

-- Locate byte offsets inside TLS Handshake ClientHello bytes (no 5-byte record header).
-- Returns sni_ext_off (start of 0x0000 extension) and/or fallback midpoint inside ClientHello.
local function find_crypto_sni_split(hs, pos_arg)
	local mode = pos_arg or "sniext"
	if mode == "mid" then return math.floor(#hs / 2) + 1 end
	if tonumber(mode) then
		local n = tonumber(mode)
		if n >= 2 and n <= #hs then return n end
	end

	-- TLS Handshake ClientHello starts with 0x01 + u24 len + u16 ver + random(32)
	if #hs >= 40 and u8(hs, 1) == 0x01 then
		local pos = 39
		local sid_len = u8(hs, pos)
		pos = pos + 1 + sid_len
		if pos + 1 <= #hs then
			local cs_len = u16(hs, pos)
			pos = pos + 2 + cs_len
			if pos <= #hs then
				local comp_len = u8(hs, pos)
				pos = pos + 1 + comp_len
				if pos + 1 <= #hs then
					local ext_start = pos + 2
					local p = ext_start
					while p + 3 <= #hs do
						local et = u16(hs, p)
						local el = u16(hs, p + 2)
						if et == 0x0000 then
							if mode == "host" and el >= 5 and p + 8 < #hs then
								local hpos = p + 9
								local hlen = u16(hs, p + 7)
								local mid_host = hpos + math.floor(hlen / 2)
								if mid_host >= 2 and mid_host <= #hs then return mid_host end
							end
							if p >= 2 and p <= #hs then return p end
						end
						p = p + 4 + el
					end
				end
			end
		end
	end
	local mid = math.floor(#hs / 2) + 1
	return (mid >= 2 and mid <= #hs) and mid or nil
end

local function encode_crypto_frame(off, data, overvarint)
	local enc_off = (overvarint and off < 16384) and encode_tvb_2b(off) or bquic_tvb(off)
	local enc_len = (overvarint and #data < 16384) and encode_tvb_2b(#data) or bquic_tvb(#data)
	return "\06" .. enc_off .. enc_len .. data
end

function z2k_quic_seal_initial(parsed, pn, plaintext_body, min_udp_len)
	local pn_len = parsed.pn_len or 1
	if pn > 0xFFFFFF and pn_len < 4 then pn_len = 4
	elseif pn > 0xFFFF and pn_len < 3 then pn_len = 3
	elseif pn > 0xFF and pn_len < 2 then pn_len = 2 end

	local pn_bytes = encode_be_uint(pn, pn_len)
	local new_first = bitor(bitand(parsed.unmasked_first, 0xFC), (pn_len - 1))
	local pre_len = bu8(new_first) .. parsed.version_raw .. bu8(#parsed.dcid) .. parsed.dcid ..
		bu8(#parsed.scid) .. parsed.scid .. parsed.token_raw

	-- Ensure Initial packet meets minimum datagram length (RFC 9000 >= 1200B).
	-- QUIC Length varint for >= 1150B and < 16384B is always 2 bytes.
	local target_len = min_udp_len or 1200
	local fixed_hdr_and_tag = #pre_len + 2 + pn_len + #plaintext_body + 16
	if fixed_hdr_and_tag >= 16384 then return nil end

	local pt = plaintext_body
	local pad_need = target_len - fixed_hdr_and_tag
	if pad_need > 0 then
		pt = pt .. string.rep("\0", pad_need)
	end

	local len_val = pn_len + #pt + 16
	local len_field = (len_val >= 64) and bquic_tvb(len_val) or encode_tvb_2b(len_val)
	if #len_field ~= 2 and pad_need > 0 then
		-- Defensive adjustment if length varint size ever differed from 2 bytes.
		local diff = 2 - #len_field
		if diff > 0 and #pt >= diff then
			pt = string.sub(pt, 1, #pt - diff)
			len_val = pn_len + #pt + 16
			len_field = bquic_tvb(len_val)
		end
	end

	local aad = pre_len .. len_field .. pn_bytes
	local ct, tag = aes_gcm(true, parsed.keys.key, quic_nonce(parsed.keys.iv, pn), pt, aad)
	if not ct or not tag then return nil end

	local ct_all = ct .. tag
	local tail = pn_bytes .. ct_all
	if #tail < 20 then return nil end
	local sample = string.sub(tail, 5, 20)
	local hp_mask = aes(true, parsed.keys.hp, sample)
	if not hp_mask or #hp_mask < 16 then return nil end

	local masked_first = bu8(bitxor(new_first, bitand(u8(hp_mask, 1), 0x0F)))
	local masked_pn = bxor(pn_bytes, string.sub(hp_mask, 2, 1 + pn_len))
	return masked_first .. string.sub(pre_len, 2) .. len_field .. masked_pn .. ct_all
end

-- Transform a raw QUIC Initial datagram cleanly according to opts.mode:
-- Returns table { pkt1, [pkt2] } or nil on any parse/crypto/budget invariant failure.
function z2k_quic_transform_initial(pkt, opts)
	local p = parse_initial_packet(pkt)
	if not p then return nil end
	local frames = parse_initial_frames(p.plaintext)
	if not frames or #frames.crypto < 8 then return nil end

	local mode = opts and opts.mode or "pad_prefix"
	local overvarint = opts and opts.overvarint or false
	local pad_req = opts and tonumber(opts.pad) or 128
	if pad_req < 16 then pad_req = 16 elseif pad_req > 512 then pad_req = 512 end

	local split_pos = find_crypto_sni_split(frames.crypto, opts and opts.pos)

	if mode == "crypto_split_pkt" and split_pos and #p.trail == 0 and #pkt >= 1200 then
		local part1 = string.sub(frames.crypto, 1, split_pos - 1)
		local part2 = string.sub(frames.crypto, split_pos)
		local f1 = encode_crypto_frame(frames.base_off, part1, overvarint) .. frames.others
		local prefix_p = math.min(pad_req, 128)
		local f2 = string.rep("\0", prefix_p) .. encode_crypto_frame(frames.base_off + split_pos - 1, part2, overvarint)

		local wire1 = z2k_quic_seal_initial(p, p.pn, f1, 1200)
		local wire2 = z2k_quic_seal_initial(p, p.pn + 1, f2, 1200)
		if not (wire1 and wire2) then return nil end
		if opts and opts.disorder then
			return { wire2, wire1 }
		end
		return { wire1, wire2 }
	end

	-- Fallback from crypto_split_pkt when coalesced 0-RTT is present or unsplit: use crypto_reorder preserving datagram size.
	if mode == "crypto_split_pkt" then
		mode = "crypto_reorder"
	end

	local body
	local target_init_len = p.init_end
	if mode == "crypto_reorder" and split_pos then
		local part1 = string.sub(frames.crypto, 1, split_pos - 1)
		local part2 = string.sub(frames.crypto, split_pos)
		local c2 = encode_crypto_frame(frames.base_off + split_pos - 1, part2, overvarint)
		local c1 = encode_crypto_frame(frames.base_off, part1, overvarint)
		local pref = ""
		if frames.pad_count >= 32 then
			pref = string.rep("\0", math.min(math.floor(frames.pad_count / 2), pad_req))
		end
		body = pref .. frames.others .. c2 .. c1
	else
		-- pad_prefix: place PADDING(0x00...) before CRYPTO so ClientHello/SNI shifts deeper in Initial payload.
		local c = encode_crypto_frame(frames.base_off, frames.crypto, overvarint)
		local min_needed = #c + #frames.others
		local free_space = #p.plaintext - min_needed
		if free_space < 8 then
			-- No padding budget in this Initial packet; allow mild growth only if no coalesced trailer and below safe MTU.
			if #p.trail > 0 or target_init_len + 64 > 1350 then return nil end
			target_init_len = target_init_len + 64
			free_space = 64
		end
		local plen = math.min(pad_req, free_space)
		body = string.rep("\0", plen) .. frames.others .. c
	end

	-- Ensure body fits cleanly inside target_init_len (expanding non-coalesced Initial slightly up to 1350 only if CRYPTO overhead added).
	local hdr_min = (target_init_len - #p.plaintext) + #body
	if hdr_min > target_init_len then
		local grow = hdr_min - target_init_len
		if #p.trail > 0 or target_init_len + grow > 1350 then return nil end
		target_init_len = target_init_len + grow
	end

	local wire = z2k_quic_seal_initial(p, p.pn, body, target_init_len)
	if not wire then return nil end
	return { wire .. p.trail }
end

-- nfqws2 desync function: cryptographically valid QUIC Initial frame desync.
-- standard args: direction, payload, ip_id, ipfrag, rawsend, reconstruct
-- arg: mode=pad_prefix|crypto_reorder|crypto_split_pkt, pad=<N>, pos=sniext|host|mid|<int>, overvarint=1, disorder=1
function quic_crypto_desync(ctx, desync)
	if not desync.dis.udp then
		if not desync.dis.icmp and desync.func_instance then instance_cutoff_shim(ctx, desync) end
		return
	end
	if desync.func_instance then direction_cutoff_opposite(ctx, desync) end
	if not (direction_check(desync) and payload_check(desync, "quic_initial")) then return end

	local raw = desync.dis.payload
	if type(raw) ~= "string" or #raw < 1200 then return VERDICT_PASS end

	local opts = {
		mode = desync.arg.mode or "pad_prefix",
		pad = tonumber(desync.arg.pad) or 128,
		pos = desync.arg.pos or "sniext",
		overvarint = desync.arg.overvarint == "1" or desync.arg.overvarint == "true",
		disorder = desync.arg.disorder == "1" or desync.arg.disorder == "true"
	}

	local pkts = z2k_quic_transform_initial(raw, opts)
	if not pkts or #pkts == 0 then
		DLOG("quic_crypto_desync: skipped (unsupported/coalesced/verify failed)")
		return VERDICT_PASS
	end

	if #pkts == 1 then
		desync.dis.payload = pkts[1]
		DLOG("quic_crypto_desync: applied mode=" .. opts.mode .. " (" .. #pkts[1] .. "B)")
		return VERDICT_MODIFY
	end

	local send_opts = {
		rawsend = rawsend_opts(desync),
		reconstruct = reconstruct_opts(desync),
		ipfrag = desync.arg,
		ipid = desync.arg
	}
	for i = 1, #pkts do
		local d = deepcopy(desync.dis)
		d.payload = pkts[i]
		apply_ip_id(desync, d, send_opts.ipid)
		if not rawsend_dissect_ipfrag(d, send_opts) then
			DLOG("quic_crypto_desync: rawsend failed at split pkt " .. i)
			return VERDICT_PASS
		end
	end
	DLOG("quic_crypto_desync: sent " .. #pkts .. " split Initial packets")
	return VERDICT_DROP
end
