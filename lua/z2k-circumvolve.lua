-- CircumVolve Phase 1 primitives for nfqws2
-- Zero-sequence-delta TLS/HTTP structural mutations and timed split transmission.
-- Designed for LuaJIT (nfqws2) and syntactically compatible with Lua 5.4 (CI luac -p).

local TLS_REC_HANDSHAKE = 0x16
local TLS_HS_CLIENT_HELLO = 0x01
local TLS_EXT_SNI = 0x0000
local TLS_EXT_PAD = 0x0015
local TLS_EXT_PSK = 0x0029

-- Parse single TLS record ClientHello into structural offsets and raw TLV extensions.
-- Using raw TLV slices preserves unknown/GREASE extensions byte-for-byte.
function z2k_parse_tls_client_hello(data)
	if type(data) ~= "string" or #data < 48 then return nil end
	if u8(data, 1) ~= TLS_REC_HANDSHAKE then return nil end
	local rec_ver = u16(data, 2)
	if rec_ver < 0x0300 or rec_ver > 0x0304 then return nil end
	local rec_len = u16(data, 4)
	if #data ~= 5 + rec_len or rec_len < 44 then return nil end

	if u8(data, 6) ~= TLS_HS_CLIENT_HELLO then return nil end
	local hs_len = u24(data, 7)
	if hs_len + 4 ~= rec_len then return nil end

	-- ClientHello fixed header: legacy_version(2) + random(32) at offset 10..43
	local pos = 44
	if pos > #data then return nil end
	local sid_len = u8(data, pos)
	pos = pos + 1 + sid_len
	if pos + 1 > #data then return nil end

	local cs_len = u16(data, pos)
	if cs_len < 2 or (cs_len % 2) ~= 0 then return nil end
	pos = pos + 2 + cs_len
	if pos > #data then return nil end

	local comp_len = u8(data, pos)
	if comp_len < 1 then return nil end
	pos = pos + 1 + comp_len
	if pos + 1 > #data then return nil end

	local ext_len_off = pos
	local ext_len = u16(data, ext_len_off)
	pos = ext_len_off + 2
	if pos + ext_len - 1 ~= #data then return nil end

	local exts = {}
	local end_pos = #data
	while pos <= end_pos do
		if pos + 3 > end_pos then return nil end
		local etype = u16(data, pos)
		local elen = u16(data, pos + 2)
		local next_pos = pos + 4 + elen
		if next_pos - 1 > end_pos then return nil end
		exts[#exts + 1] = {
			type = etype,
			data = string.sub(data, pos + 4, next_pos - 1),
			raw = string.sub(data, pos, next_pos - 1)
		}
		pos = next_pos
	end
	if pos ~= end_pos + 1 then return nil end

	return {
		rec_ver = rec_ver,
		hs_len = hs_len,
		ext_len_off = ext_len_off,
		ext_len = ext_len,
		exts = exts
	}
end

local function toggle_ascii_case_alt(s)
	local out = {}
	for i = 1, #s do
		local b = string.byte(s, i)
		if b >= 97 and b <= 122 then
			if (i % 2) == 1 then b = b - 32 end
		elseif b >= 65 and b <= 90 then
			if (i % 2) == 0 then b = b + 32 end
		end
		out[i] = string.char(b)
	end
	return table.concat(out)
end

local function apply_sni_case_ext(ext)
	local d = ext.data
	if #d < 5 then return ext end
	local list_len = u16(d, 1)
	if 2 + list_len > #d then return ext end
	local pos = 3
	local end_pos = 2 + list_len
	local chunks = { string.sub(d, 1, 2) }
	while pos + 2 <= end_pos do
		local ntype = u8(d, pos)
		local nlen = u16(d, pos + 1)
		if pos + 2 + nlen > end_pos then return ext end
		local h = string.sub(d, pos + 3, pos + 2 + nlen)
		if ntype == 0 and nlen > 0 then
			h = toggle_ascii_case_alt(h)
		end
		chunks[#chunks + 1] = string.sub(d, pos, pos + 2) .. h
		pos = pos + 3 + nlen
	end
	local ndata = table.concat(chunks) .. string.sub(d, end_pos + 1)
	if #ndata ~= #d then return ext end
	return {
		type = ext.type,
		data = ndata,
		raw = bu16(ext.type) .. bu16(#ndata) .. ndata
	}
end

local function find_ext_index(exts, etype)
	for i = 1, #exts do
		if exts[i].type == etype then return i end
	end
	return nil
end

local function build_reordered_exts(exts, opts)
	local out = {}
	for i = 1, #exts do
		local e = exts[i]
		if opts and opts.case and e.type == TLS_EXT_SNI then
			e = apply_sni_case_ext(e)
		end
		out[i] = e
	end

	local mode = opts and opts.mode or "sni_last"
	local psk_idx = find_ext_index(out, TLS_EXT_PSK)
	local sni_idx = find_ext_index(out, TLS_EXT_SNI)
	local pad_idx = find_ext_index(out, TLS_EXT_PAD)

	if mode == "pad_first" and pad_idx and pad_idx > 1 then
		local pad = table.remove(out, pad_idx)
		table.insert(out, 1, pad)
		sni_idx = find_ext_index(out, TLS_EXT_SNI)
		psk_idx = find_ext_index(out, TLS_EXT_PSK)
	end

	if sni_idx and #out > 1 then
		local max_pos = (psk_idx and psk_idx == #out) and (#out - 1) or #out
		if sni_idx < max_pos then
			local sni = table.remove(out, sni_idx)
			table.insert(out, max_pos, sni)
		elseif #out >= 3 then
			-- SNI is already at the tail boundary; swap first two non-PSK extensions so fingerprint still shifts.
			local limit = (psk_idx and psk_idx == #out) and (#out - 1) or #out
			if limit >= 3 then
				local first = table.remove(out, 1)
				table.insert(out, limit - 1, first)
			end
		end
	end
	return out
end

local function concat_ext_raw(exts)
	local parts = {}
	for i = 1, #exts do
		parts[i] = exts[i].raw
	end
	return table.concat(parts)
end

-- Move TLS SNI (0x0000) toward end of ClientHello extensions (always before 0x0029 pre_shared_key).
-- Preserves exact byte length (delta == 0).
function z2k_tls_reorder_extensions(data, opts)
	local p = z2k_parse_tls_client_hello(data)
	if not p or #p.exts < 2 then return nil end
	local exts = build_reordered_exts(p.exts, opts)
	local body = concat_ext_raw(exts)
	if #body ~= p.ext_len then return nil end
	local out = string.sub(data, 1, p.ext_len_off + 1) .. body
	if #out ~= #data then return nil end
	return out
end

-- Split ClientHello into two TLS Plaintext records while preserving exact wire length (#out == #data)
-- by trimming 5 bytes from RFC 7685 TLS_EXT_PADDING (0x0015).
-- Default cut is right before extensions_length ('ext_start') so Record 1 stops before any extension/SNI.
function z2k_tls_record_split_zero(data, opts)
	local p = z2k_parse_tls_client_hello(data)
	if not p then return nil end

	local pad_idx = find_ext_index(p.exts, TLS_EXT_PAD)
	if not pad_idx or #p.exts[pad_idx].data < 5 then
		if opts and opts.fallback == "none" then return nil end
		return z2k_tls_reorder_extensions(data, opts)
	end

	local work = {}
	for i = 1, #p.exts do work[i] = p.exts[i] end
	local pe = work[pad_idx]
	local trimmed = string.sub(pe.data, 1, #pe.data - 5)
	work[pad_idx] = {
		type = TLS_EXT_PAD,
		data = trimmed,
		raw = bu16(TLS_EXT_PAD) .. bu16(#trimmed) .. trimmed
	}

	if opts and opts.reorder ~= false then
		work = build_reordered_exts(work, opts)
	end

	local exts_blob = concat_ext_raw(work)
	local new_ext_len = #exts_blob
	if new_ext_len ~= p.ext_len - 5 then return nil end

	local fixed_middle = string.sub(data, 10, p.ext_len_off - 1)
	local hs_inner = fixed_middle .. bu16(new_ext_len) .. exts_blob
	local new_hs = bu8(TLS_HS_CLIENT_HELLO) .. bu24(#hs_inner) .. hs_inner

	local cut
	if opts and opts.cut and opts.cut > 0 then
		cut = opts.cut
	else
		-- Handshake starts at byte 6 of TLS record; ext_len_off - 6 places split just before extensions_length.
		cut = p.ext_len_off - 6
	end
	if cut < 4 or cut >= #new_hs then return nil end

	local rec1 = bu8(TLS_REC_HANDSHAKE) .. bu16(p.rec_ver) .. bu16(cut) .. string.sub(new_hs, 1, cut)
	local rec2 = bu8(TLS_REC_HANDSHAKE) .. bu16(p.rec_ver) .. bu16(#new_hs - cut) .. string.sub(new_hs, cut + 1)
	local out = rec1 .. rec2
	if #out ~= #data then return nil end
	return out
end

-- Zero-delta HTTP Host header folding (RFC 7230 obs-fold), compensating added bytes by trimming User-Agent tail.
function z2k_http_host_fold_payload(data, opts)
	if type(data) ~= "string" or #data < 20 then return nil end
	local hdis = http_dissect_req(data)
	if not hdis or not hdis.headers then return nil end

	local h_host, h_ua
	for i = 1, #hdis.headers do
		local h = hdis.headers[i]
		if h.header_low == "host" and not h_host then
			h_host = h
		elseif h.header_low == "user-agent" and not h_ua then
			h_ua = h
		end
	end
	if not h_host or not h_ua then return nil end
	if string.sub(data, h_host.pos_end + 1, h_host.pos_end + 2) ~= "\r\n" then return nil end

	local colon_pos = string.find(data, ":", h_host.pos_start, true)
	if not colon_pos or colon_pos > h_host.pos_value_start then return nil end
	local old_prefix = string.sub(data, h_host.pos_start, h_host.pos_value_start - 1)
	local hname = (opts and opts.tab) and "HoSt" or h_host.header
	local new_prefix = (opts and opts.tab) and (hname .. ":\t\r\n ") or (hname .. ":\r\n ")
	local delta = #new_prefix - #old_prefix
	if delta <= 0 then return nil end

	-- Keep at least 4 chars of User-Agent value so the header remains syntactically healthy.
	if #h_ua.value < delta + 4 then return nil end
	local ua_cut_start = h_ua.pos_end - delta + 1
	local ua_cut_end = h_ua.pos_end

	local out
	if h_ua.pos_start > h_host.pos_end then
		-- Edit User-Agent (larger offset) first, then Host.
		out = string.sub(data, 1, ua_cut_start - 1) .. string.sub(data, ua_cut_end + 1)
		out = string.sub(out, 1, h_host.pos_start - 1) .. new_prefix .. string.sub(out, h_host.pos_value_start)
	else
		-- Edit Host (larger offset) first, then User-Agent.
		out = string.sub(data, 1, h_host.pos_start - 1) .. new_prefix .. string.sub(data, h_host.pos_value_start)
		out = string.sub(out, 1, ua_cut_start - 1) .. string.sub(out, ua_cut_end + 1)
	end

	if #out ~= #data then return nil end
	return out
end

local function apply_payload_transform(ctx, desync, transform_fn, opts, label)
	if not desync.dis.tcp then
		if not desync.dis.icmp and desync.func_instance then instance_cutoff_shim(ctx, desync) end
		return
	end
	if desync.func_instance then direction_cutoff_opposite(ctx, desync) end
	if not (direction_check(desync) and payload_check(desync, "tls_client_hello")) then return end

	local is_multi = desync.reasm_data and #desync.reasm_data > #desync.dis.payload
	if is_multi and desync.arg.send == "1" then
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
		if replay_first(desync) then
			local out = transform_fn(desync.reasm_data, opts)
			if out and #out == #desync.reasm_data then
				local send_opts = {
					rawsend = rawsend_opts(desync),
					reconstruct = reconstruct_opts(desync),
					ipfrag = desync.arg,
					ipid = desync.arg
				}
				if rawsend_payload_segmented(desync, out, 0, send_opts) then
					DLOG(label .. ": sent reassembled zero-delta transform (" .. #out .. "B)")
					replay_drop_set(desync)
					return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
				end
			end
		end
		return VERDICT_PASS
	end

	local src = is_multi and desync.reasm_data or desync.dis.payload
	local out = transform_fn(src, opts)
	if not out or #out ~= #src then
		DLOG(label .. ": skipped (invariant or unsupported structure)")
		return VERDICT_PASS
	end
	if is_multi then
		desync.reasm_data = out
		DLOG(label .. ": updated reasm_data in place (" .. #out .. "B)")
		return VERDICT_PASS
	end
	desync.dis.payload = out
	if desync.reasm_data then desync.reasm_data = out end
	DLOG(label .. ": applied zero-delta transform (" .. #out .. "B)")
	return VERDICT_MODIFY
end

-- nfqws2 desync function: move SNI extension toward end of TLS ClientHello (before PSK).
-- standard args: direction, payload, ip_id, ipfrag, rawsend, reconstruct
-- arg: mode=sni_last|pad_first, case=1 (mixed-case SNI in-place), send=1 (emit multi-pkt reasm standalone)
function tls_ext_reorder(ctx, desync)
	local opts = {
		mode = desync.arg.mode or "sni_last",
		case = desync.arg.case == "1" or desync.arg.case == "true"
	}
	return apply_payload_transform(ctx, desync, z2k_tls_reorder_extensions, opts, "tls_ext_reorder")
end

-- nfqws2 desync function: split TLS ClientHello into 2 records with zero stream length delta
-- by trimming 5 bytes from RFC 7685 Padding extension (0x0015), with tls_ext_reorder fallback.
-- standard args: direction, payload, ip_id, ipfrag, rawsend, reconstruct
-- arg: pos=ext_start|<int>, reorder=0|1, case=1, fallback=none|reorder, send=1
function tlsrec_zero(ctx, desync)
	local pos_arg = desync.arg.pos
	local cut = nil
	if pos_arg and pos_arg ~= "ext_start" then
		cut = tonumber(pos_arg)
	end
	local opts = {
		cut = cut,
		reorder = desync.arg.reorder ~= "0",
		case = desync.arg.case == "1" or desync.arg.case == "true",
		fallback = desync.arg.fallback
	}
	return apply_payload_transform(ctx, desync, z2k_tls_record_split_zero, opts, "tlsrec_zero")
end

-- nfqws2 desync function: fold HTTP Host header across CRLF while trimming User-Agent by exact delta.
-- standard args: direction, payload
-- arg: tab=1 (use HoSt:\t\r\n  instead of Host:\r\n )
function http_host_fold(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp and desync.func_instance then instance_cutoff_shim(ctx, desync) end
		return
	end
	if desync.func_instance then direction_cutoff_opposite(ctx, desync) end
	if not (direction_check(desync) and payload_check(desync, "http_req")) then return end
	if desync.reasm_data and #desync.reasm_data > #desync.dis.payload then
		return VERDICT_PASS
	end
	local out = z2k_http_host_fold_payload(desync.dis.payload, { tab = desync.arg.tab == "1" or desync.arg.tab == "true" })
	if not out then
		DLOG("http_host_fold: skipped (missing/short User-Agent or unsupported request)")
		return VERDICT_PASS
	end
	desync.dis.payload = out
	if desync.reasm_data then desync.reasm_data = out end
	DLOG("http_host_fold: applied zero-delta Host fold")
	return VERDICT_MODIFY
end

-- Global timer callback for delayed segment delivery in timed_fake_split.
function z2k_timed_send_cb(name, data)
	if not data or not data.chunks then return end
	for i = 1, #data.chunks do
		rawsend_dissect_ipfrag(data.chunks[i], data.opts)
	end
end

local function build_tcp_chunks(desync, payload, seq_off, real_opts)
	local chunks = {}
	local mss = desync.tcp_mss or 1460
	local extra_len = l3l4_extra_len(desync.dis)
	local max_data = (mss > extra_len) and (mss - extra_len) or #payload
	if max_data < 1 then max_data = #payload end

	local pos = 1
	while pos <= #payload do
		local len = #payload - pos + 1
		if len > max_data then len = max_data end
		local d = deepcopy(desync.dis)
		d.payload = string.sub(payload, pos, pos + len - 1)
		d.tcp.th_seq = u32add(desync.dis.tcp.th_seq, seq_off + pos - 1)
		apply_ip_id(desync, d, real_opts and real_opts.ipid)
		chunks[#chunks + 1] = d
		pos = pos + len
	end
	return chunks
end

-- nfqws2 desync function: send pre-SNI TCP segment (plus optional decoy) at t=0,
-- and schedule the SNI-bearing remainder via timer_set after delay=<ms> (default 8 ms).
-- standard args: direction, payload, fooling, ip_id, ipfrag, rawsend, reconstruct
-- arg: pos=<marker> (default sniext+1), delay=<ms> (1..100, default 8), blob=<blob>, repeats=<N>, tls_mod=<mod>, nodrop
function timed_fake_split(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp and desync.func_instance then instance_cutoff_shim(ctx, desync) end
		return
	end
	if desync.func_instance then direction_cutoff_opposite(ctx, desync) end
	if not (direction_check(desync) and payload_check(desync, "known")) then return end

	if replay_drop(desync) then
		return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
	end
	if not replay_first(desync) then return VERDICT_PASS end

	local data = desync.reasm_data or desync.dis.payload
	if type(data) ~= "string" or #data < 2 then return VERDICT_PASS end

	local spos = desync.arg.pos or "sniext+1"
	local split_pos = resolve_pos(data, desync.l7payload, spos)
	if not split_pos or split_pos < 2 or split_pos > #data then
		split_pos = resolve_pos(data, desync.l7payload, "midsld")
	end
	if not split_pos or split_pos < 2 or split_pos > #data then
		split_pos = math.floor(#data / 2) + 1
	end
	if split_pos < 2 or split_pos > #data then return VERDICT_PASS end

	local delay_ms = tonumber(desync.arg.delay) or 8
	if delay_ms < 1 then delay_ms = 1 elseif delay_ms > 100 then delay_ms = 100 end

	local part1 = string.sub(data, 1, split_pos - 1)
	local part2 = string.sub(data, split_pos)

	local real_opts = {
		rawsend = rawsend_opts(desync),
		reconstruct = reconstruct_opts(desync),
		ipfrag = desync.arg,
		ipid = desync.arg
	}

	if desync.arg.blob and blob_exist(desync, desync.arg.blob) then
		local fake_pl = blob(desync, desync.arg.blob)
		if desync.arg.tls_mod and #fake_pl > 0 then
			fake_pl = tls_mod_shim(desync, fake_pl, desync.arg.tls_mod, data)
		end
		local reps = tonumber(desync.arg.repeats) or 1
		if reps < 1 then reps = 1 elseif reps > 16 then reps = 16 end
		local fake_opts = desync_opts(desync)
		for _ = 1, reps do
			rawsend_payload_segmented(desync, fake_pl, 0, fake_opts)
		end
	end

	-- t=0: transmit pre-SNI part1 immediately
	local c1 = build_tcp_chunks(desync, part1, 0, real_opts)
	for i = 1, #c1 do
		if not rawsend_dissect_ipfrag(c1[i], real_opts) then
			return VERDICT_PASS
		end
	end

	-- t=delay_ms: schedule SNI-bearing part2 after decoy / part1 batch window
	local c2 = build_tcp_chunks(desync, part2, split_pos - 1, real_opts)
	if type(timer_set) == "function" then
		local tname = desync_timer_name(desync) .. "_p2"
		timer_set(tname, "z2k_timed_send_cb", delay_ms, true, { chunks = c2, opts = real_opts })
		DLOG("timed_fake_split: split at " .. split_pos .. ", delayed part2 (" .. #part2 .. "B) by " .. delay_ms .. "ms")
	else
		z2k_timed_send_cb("sync", { chunks = c2, opts = real_opts })
	end

	replay_drop_set(desync)
	return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
end
