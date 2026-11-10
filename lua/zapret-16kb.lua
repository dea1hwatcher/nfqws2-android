--[[
ZAPRET 16KB BLOCK BYPASS

Specialized routines to bypass "16 KB" blocks on Cloudflare/Rostelecom.
Strategy: flood TSPU with white-SNI fakes so it classifies the flow as whitelisted.

Usage:
--lua-init=@zapret-lib.lua --lua-init=@zapret-antidpi.lua --lua-init=@zapret-16kb.lua
--lua-desync=flood_white:blob=bin_max:count=10:badsum:pos=1,midsld

]]

-- Send a single fake with the specified options
local function send_one_fake(desync, payload, opts)
    local dis = deepcopy(desync.dis)
    dis.payload = payload
    if opts.fooling then
        for k,v in pairs(opts.fooling) do
            dis[k] = v
        end
    end
    apply_fooling(desync, dis)
    return rawsend_dissect(dis, opts)
end

-- Create payload with white SNI
local function make_white_payload(desync)
    local white = blob(desync, desync.arg.blob or desync.arg.white_blob)
    if not white then
        error("flood_white: blob required")
    end
    if desync.arg.tls_mod then
        white = tls_mod_shim(desync, white, desync.arg.tls_mod, nil)
    end
    return white
end

--[[
flood_white - flood TSPU with whitelisted fakes before the real packet

Arguments:
- blob - TLS ClientHello with whitelisted SNI (e.g. bin_max with max.ru)
- tls_mod - SNI modification (e.g. sni=hp.com)
- count - fake packet count (default 10)
- pos - split positions for the real packet (default 1,midsld)
- badsum, ip_ttl, tcp_md5 and other fooling parameters

Example:
--lua-desync=flood_white:blob=bin_max:count=15:badsum:pos=1,midsld
]]
function flood_white(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync)

    if not direction_check(desync) or not payload_check(desync) then
        return
    end

    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    -- Create whitelisted payload
    local white = make_white_payload(desync)
    local count = tonumber(desync.arg.count) or 10

    DLOG("flood_white: sending "..count.." white fakes")

    -- Flood with white fakes
    for i = 1, count do
        local dis = deepcopy(desync.dis)
        dis.payload = white
        apply_fooling(desync, dis)
        if b_debug then
            DLOG("flood_white: fake #"..i)
        end
        rawsend_dissect(dis, {repeats = 1})
    end

    -- Send real packet via multisplit
    local data = desync.reasm_data or desync.dis.payload
    local spos = desync.arg.pos or "1,midsld"

    if b_debug then
        DLOG("flood_white: splitting real payload at "..spos)
    end

    local pos = resolve_multi_pos(data, desync.l7payload, spos)
    delete_pos_1(pos)

    if #pos > 0 then
        for i = 0, #pos do
            local pos_start = pos[i] or 1
            local pos_end = i < #pos and pos[i+1] - 1 or #data
            local part = string.sub(data, pos_start, pos_end)

            if b_debug then
                DLOG("flood_white: sending part "..(i+1))
            end

            if not rawsend_payload_segmented(desync, part, pos_start - 1) then
                return VERDICT_PASS
            end
        end
        replay_drop_set(desync)
        return VERDICT_DROP
    else
        DLOG("flood_white: no split positions, sending as-is")
        rawsend_payload_segmented(desync)
        return VERDICT_DROP
    end
end

--[[
ttl_ladder - send fakes with increasing TTL

Idea: TSPU can reside on different hops. Send fakes with TTL from min to max,
so at least one reaches TSPU without hitting the server.

Arguments:
- blob - TLS ClientHello with whitelisted SNI
- ttl_min - minimum TTL (default 3)
- ttl_max - maximum TTL (default 12)
- pos - split positions for the real packet

Example:
--lua-desync=ttl_ladder:blob=bin_max:ttl_min=4:ttl_max=10:pos=1,midsld
]]
function ttl_ladder(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync)

    if not direction_check(desync) or not payload_check(desync) then
        return
    end

    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    local white = make_white_payload(desync)
    local ttl_min = tonumber(desync.arg.ttl_min) or 3
    local ttl_max = tonumber(desync.arg.ttl_max) or 12

    DLOG("ttl_ladder: sending fakes with TTL "..ttl_min.."-"..ttl_max)

    -- Send fakes with variable TTL
    for ttl = ttl_min, ttl_max do
        local dis = deepcopy(desync.dis)
        dis.payload = white
        if dis.ip then dis.ip.ip_ttl = ttl end
        if dis.ip6 then dis.ip6.ip6_hlim = ttl end
        if b_debug then
            DLOG("ttl_ladder: fake TTL="..ttl)
        end
        rawsend_dissect(dis, {repeats = 1})
    end

    -- Send real packet
    local data = desync.reasm_data or desync.dis.payload
    local spos = desync.arg.pos or "1,midsld"
    local pos = resolve_multi_pos(data, desync.l7payload, spos)
    delete_pos_1(pos)

    if #pos > 0 then
        for i = 0, #pos do
            local pos_start = pos[i] or 1
            local pos_end = i < #pos and pos[i+1] - 1 or #data
            local part = string.sub(data, pos_start, pos_end)
            if not rawsend_payload_segmented(desync, part, pos_start - 1) then
                return VERDICT_PASS
            end
        end
        replay_drop_set(desync)
        return VERDICT_DROP
    else
        rawsend_payload_segmented(desync)
        return VERDICT_DROP
    end
end

--[[
white_sandwich - wrap real packet segments in whitelisted fakes

Idea: send whitelisted fakes BEFORE and AFTER each segment of the real packet.
TSPU sees white-white-real-white-white pattern.

Arguments:
- blob - TLS ClientHello with whitelisted SNI
- before - fakes before segment (default 3)
- after - fakes after segment (default 3)
- pos - split positions
- badsum, ip_ttl and other fooling parameters

Example:
--lua-desync=white_sandwich:blob=bin_max:before=5:after=2:badsum:pos=1,midsld
]]
function white_sandwich(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync)

    if not direction_check(desync) or not payload_check(desync) then
        return
    end

    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    local white = make_white_payload(desync)
    local before = tonumber(desync.arg.before) or 3
    local after = tonumber(desync.arg.after) or 3

    local data = desync.reasm_data or desync.dis.payload
    local spos = desync.arg.pos or "1,midsld"
    local pos = resolve_multi_pos(data, desync.l7payload, spos)
    delete_pos_1(pos)

    DLOG("white_sandwich: before="..before..", after="..after)

    -- Send fakes helper
    local function send_fakes(count, label)
        for i = 1, count do
            local dis = deepcopy(desync.dis)
            dis.payload = white
            apply_fooling(desync, dis)
            if b_debug then
                DLOG("white_sandwich: "..label.." fake #"..i)
            end
            rawsend_dissect(dis, {repeats = 1})
        end
    end

    if #pos > 0 then
        for i = 0, #pos do
            local pos_start = pos[i] or 1
            local pos_end = i < #pos and pos[i+1] - 1 or #data
            local part = string.sub(data, pos_start, pos_end)

            -- Fakes BEFORE segment
            send_fakes(before, "before")

            -- Real segment
            if b_debug then
                DLOG("white_sandwich: real segment "..(i+1))
            end
            if not rawsend_payload_segmented(desync, part, pos_start - 1) then
                return VERDICT_PASS
            end

            -- Fakes AFTER segment
            send_fakes(after, "after")
        end
        replay_drop_set(desync)
        return VERDICT_DROP
    else
        send_fakes(before, "before")
        rawsend_payload_segmented(desync)
        send_fakes(after, "after")
        return VERDICT_DROP
    end
end

--[[
seqovl_white - sequence overlap containing whitelisted SNI

Idea: with seqovl the first packet slice is sent twice (original and overlap).
If overlap contains whitelisted SNI, TSPU may treat flow as allowed.

Arguments:
- blob - TLS ClientHello with whitelisted SNI (takes first N bytes)
- ovl_size - overlap size (default 200)
- pos - split positions
- badsum and other fooling parameters for the overlap packet

Example:
--lua-desync=seqovl_white:blob=bin_max:ovl_size=150:pos=1,midsld
]]
function seqovl_white(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end

    direction_cutoff_opposite(ctx, desync)

    if not direction_check(desync) or not payload_check(desync) then
        return
    end

    if not replay_first(desync) then
        if replay_drop(desync) then
            return VERDICT_DROP
        end
        return
    end

    local white = make_white_payload(desync)
    local ovl_size = tonumber(desync.arg.ovl_size) or 200
    local data = desync.reasm_data or desync.dis.payload

    -- Take first ovl_size bytes of whitelisted payload
    local white_prefix = string.sub(white, 1, ovl_size)

    DLOG("seqovl_white: overlap size="..ovl_size)

    -- Send overlap packet with whitelisted content
    local dis_ovl = deepcopy(desync.dis)
    dis_ovl.payload = white_prefix
    if dis_ovl.tcp and desync.dis.tcp then
        dis_ovl.tcp.th_seq = u32add(desync.dis.tcp.th_seq, -ovl_size)  -- Shift sequence back
    end
    apply_fooling(desync, dis_ovl)

    if b_debug then
        DLOG("seqovl_white: sending white overlap")
    end
    rawsend_dissect(dis_ovl, {repeats = 1})

    -- Send real packet with split
    local spos = desync.arg.pos or "1,midsld"
    local pos = resolve_multi_pos(data, desync.l7payload, spos)
    delete_pos_1(pos)

    if #pos > 0 then
        for i = 0, #pos do
            local pos_start = pos[i] or 1
            local pos_end = i < #pos and pos[i+1] - 1 or #data
            local part = string.sub(data, pos_start, pos_end)

            if b_debug then
                DLOG("seqovl_white: sending part "..(i+1))
            end

            if not rawsend_payload_segmented(desync, part, pos_start - 1) then
                return VERDICT_PASS
            end
        end
        replay_drop_set(desync)
        return VERDICT_DROP
    else
        rawsend_payload_segmented(desync)
        return VERDICT_DROP
    end
end

-- Register functions for --lua-desync
DLOG("zapret-16kb.lua loaded: flood_white, ttl_ladder, white_sandwich, seqovl_white")
DLOG("zapret-16kb.lua loaded: flood_white, ttl_ladder, white_sandwich, seqovl_white")
