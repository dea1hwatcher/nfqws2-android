--[[

NFQWS2 MULTISHAKE - Advanced Stealth Fakesplit Variants

Stealthier, less aggressive variants of hostfakesplit.

Usage:
--lua-init=@zapret-lib.lua --lua-init=@zapret-antidpi.lua --lua-init=@zapret-multishake.lua

IMPORTANT: Use the same fooling parameters that work on your network.
If this works: hostfakesplit:host=vimeo.com:tcp_ts=-1000:tcp_md5:repeats=4
Then use:      hostfakesplit_stealth:host=vimeo.com:tcp_ts=-1000:tcp_md5:repeats=2:mode=soft

FUNCTIONS:

hostfakesplit_stealth - stealthier hostfakesplit
  mode=soft     - 1 fake instead of 2
  mode=blend    - fake resembles real domain (mutates subset of letters)
  mode=minimal  - fake only for long SNIs
  mode=random   - randomized 0-2 fakes

hostfakesplit_chaos - randomized segment order

hostfakesplit_multi - multiple distinct fake domains
  hosts=google.com,vimeo.com,amazon.com

hostfakesplit_gradual - interleaved fake and real slices
  parts=3

hostfakesplit_decoy - supplemental decoy packets
  decoys=2
  decoy_size=50

]]

-- Upstream API compatibility check
-- These functions must be provided by zapret-lib.lua and zapret-antidpi.lua
do
    local required = {
        "DLOG", "resolve_range", "genhost", "direction_check", "payload_check",
        "replay_first", "replay_drop", "replay_drop_set",
        "rawsend_payload_segmented", "rawsend_opts_base", "rawsend_opts",
        "reconstruct_opts", "blob_or_def", "direction_cutoff_opposite",
        "hostfakesplit"
    }
    local missing = {}
    for _, name in ipairs(required) do
        if not _G[name] then
            table.insert(missing, name)
        end
    end
    if #missing > 0 then
        local msg = "zapret-multishake.lua: SKIPPED - missing upstream functions: " .. table.concat(missing, ", ")
        if DLOG then DLOG(msg) else print(msg) end
        return
    end
    -- Use instance_cutoff_shim if available, fallback to instance_cutoff
    if not _G["instance_cutoff_shim"] then
        if _G["instance_cutoff"] then
            instance_cutoff_shim = function(ctx, desync) instance_cutoff(ctx) end
        else
            instance_cutoff_shim = function() end
        end
    end
end

-- ============================================================================
-- HOSTFAKESPLIT_STEALTH - stealthier hostfakesplit
-- ============================================================================

--[[
hostfakesplit_stealth - stealth version of hostfakesplit

Differences from standard hostfakesplit:
- mode=soft: 1 fake instead of 2, fewer repeats
- mode=blend: fake resembles real domain (mutates subset of chars)
- mode=minimal: fake sent only if SNI is long
- mode=random: randomly chooses fake count (0-2)

standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
arg : host=<str> - fake host template
arg : midhost=<posmarker> - split SNI
arg : mode=soft|blend|minimal|random - stealth mode
arg : min_sni=N - for mode=minimal, minimum SNI length (default 15)
arg : nodrop
]]
function hostfakesplit_stealth(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
        DLOG("hostfakesplit_stealth: blob '"..desync.arg.blob.."' not found. skipped")
        return
    end
    local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
    if #data > 0 and direction_check(desync) and payload_check(desync) then
        if replay_first(desync) then
            local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
            if pos then
                if b_debug then DLOG("hostfakesplit_stealth: resolved host range: "..table.concat(zero_based_pos(pos), " ")) end

                local mode = desync.arg.mode or "soft"
                local sni_len = pos[2] - pos[1] + 1
                local real_sni = string.sub(data, pos[1], pos[2])

                -- minimal mode: skip short SNIs
                if mode == "minimal" then
                    local min_sni = tonumber(desync.arg.min_sni) or 15
                    if sni_len < min_sni then
                        DLOG("hostfakesplit_stealth: SNI too short ("..sni_len.." < "..min_sni.."), passing through")
                        return
                    end
                end

                -- determine fake count
                local send_fake1, send_fake2 = true, true
                if mode == "soft" then
                    send_fake1 = true
                    send_fake2 = false  -- only 1 fake
                elseif mode == "random" then
                    local rnd = math.random(100)
                    if rnd < 25 then
                        send_fake1, send_fake2 = false, false  -- 25% no fakes
                    elseif rnd < 60 then
                        send_fake1, send_fake2 = true, false   -- 35% 1 fake
                    else
                        send_fake1, send_fake2 = true, true    -- 40% 2 fakes
                    end
                    DLOG("hostfakesplit_stealth: random mode, fake1="..tostring(send_fake1).." fake2="..tostring(send_fake2))
                end

                -- manual fake disabling
                if desync.arg.nofake1 then send_fake1 = false end
                if desync.arg.nofake2 then send_fake2 = false end

                -- generate fake host
                local fakehost
                if mode == "blend" then
                    -- mutate subset of characters in real SNI
                    fakehost = ""
                    for i = 1, sni_len do
                        local c = string.sub(real_sni, i, i)
                        if c ~= "." and math.random(100) < 40 then
                            -- 40% chance to replace character
                            fakehost = fakehost .. string.char(math.random(97, 122))
                        else
                            fakehost = fakehost .. c
                        end
                    end
                    DLOG("hostfakesplit_stealth: blend mode, fake="..fakehost)
                else
                    fakehost = genhost(sni_len, desync.arg.host)
                end

                local part
                local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
                local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

                -- prefix before host
                part = string.sub(data, 1, pos[1] - 1)
                if b_debug then DLOG("hostfakesplit_stealth: sending before_host 0-"..(pos[1]-2).." len="..#part) end
                if not rawsend_payload_segmented(desync, part, 0, opts_orig) then return VERDICT_PASS end

                -- fake 1
                if send_fake1 then
                    if b_debug then DLOG("hostfakesplit_stealth: sending fake1 "..(pos[1]-1).."-"..(pos[2]-1)) end
                    if not rawsend_payload_segmented(desync, fakehost, pos[1] - 1, opts_fake) then return VERDICT_PASS end
                end

                -- real host (with optional split)
                local midhost
                if desync.arg.midhost then
                    midhost = resolve_pos(data, desync.l7payload, desync.arg.midhost)
                    if midhost and (midhost <= pos[1] or midhost > pos[2]) then
                        midhost = nil
                    end
                end

                if midhost then
                    part = string.sub(data, pos[1], midhost - 1)
                    if b_debug then DLOG("hostfakesplit_stealth: sending real host part1 "..(pos[1]-1).."-"..(midhost-2)) end
                    if not rawsend_payload_segmented(desync, part, pos[1] - 1, opts_orig) then return VERDICT_PASS end

                    part = string.sub(data, midhost, pos[2])
                    if b_debug then DLOG("hostfakesplit_stealth: sending real host part2 "..(midhost-1).."-"..(pos[2]-1)) end
                    if not rawsend_payload_segmented(desync, part, midhost - 1, opts_orig) then return VERDICT_PASS end
                else
                    part = string.sub(data, pos[1], pos[2])
                    if b_debug then DLOG("hostfakesplit_stealth: sending real host "..(pos[1]-1).."-"..(pos[2]-1)) end
                    if not rawsend_payload_segmented(desync, part, pos[1] - 1, opts_orig) then return VERDICT_PASS end
                end

                -- fake 2
                if send_fake2 then
                    if b_debug then DLOG("hostfakesplit_stealth: sending fake2 "..(pos[1]-1).."-"..(pos[2]-1)) end
                    if not rawsend_payload_segmented(desync, fakehost, pos[1] - 1, opts_fake) then return VERDICT_PASS end
                end

                -- suffix after host
                part = string.sub(data, pos[2] + 1)
                if b_debug then DLOG("hostfakesplit_stealth: sending after_host "..pos[2].."-"..(#data-1)) end
                if not rawsend_payload_segmented(desync, part, pos[2], opts_orig) then return VERDICT_PASS end

                replay_drop_set(desync)
                return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
            else
                DLOG("hostfakesplit_stealth: host range cannot be resolved")
            end
        else
            DLOG("hostfakesplit_stealth: not acting on further replay pieces")
        end
        if replay_drop(desync) then
            return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
        end
    end
end


-- ============================================================================
-- HOSTFAKESPLIT_CHAOS - randomized segment delivery order with fakes
-- ============================================================================

--[[
hostfakesplit_chaos - hostfakesplit with shuffled packet delivery order

Sends segments in randomized order while preserving valid TCP sequence numbers,
instead of fixed (before -> fake1 -> real -> fake2 -> after) sequencing.

standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
arg : host=<str> - fake host template
arg : midhost=<posmarker> - split SNI
arg : order=<str> - explicit indices 1..5 (1=before, 2=fake1, 3=real, 4=fake2, 5=after)
                    default: random
arg : nofake1, nofake2
arg : nodrop
]]
function hostfakesplit_chaos(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    if desync.arg.optional and desync.arg.blob and not blob_exist(desync, desync.arg.blob) then
        DLOG("hostfakesplit_chaos: blob '"..desync.arg.blob.."' not found. skipped")
        return
    end
    local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
    if #data > 0 and direction_check(desync) and payload_check(desync) then
        if replay_first(desync) then
            local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
            if pos then
                if b_debug then DLOG("hostfakesplit_chaos: resolved host range: "..table.concat(zero_based_pos(pos), " ")) end

                local sni_len = pos[2] - pos[1] + 1
                local fakehost = genhost(sni_len, desync.arg.host)

                local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
                local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

                -- prepare all segments
                local segments = {}

                -- 1: before_host
                segments[1] = {
                    name = "before",
                    data = string.sub(data, 1, pos[1] - 1),
                    offset = 0,
                    opts = opts_orig,
                    enabled = true
                }

                -- 2: fake1
                segments[2] = {
                    name = "fake1",
                    data = fakehost,
                    offset = pos[1] - 1,
                    opts = opts_fake,
                    enabled = not desync.arg.nofake1
                }

                -- 3: real host
                segments[3] = {
                    name = "real",
                    data = string.sub(data, pos[1], pos[2]),
                    offset = pos[1] - 1,
                    opts = opts_orig,
                    enabled = true
                }

                -- 4: fake2
                segments[4] = {
                    name = "fake2",
                    data = fakehost,
                    offset = pos[1] - 1,
                    opts = opts_fake,
                    enabled = not desync.arg.nofake2
                }

                -- 5: after_host
                segments[5] = {
                    name = "after",
                    data = string.sub(data, pos[2] + 1),
                    offset = pos[2],
                    opts = opts_orig,
                    enabled = true
                }

                -- determine delivery order
                local order
                if desync.arg.order then
                    order = {}
                    for num in string.gmatch(desync.arg.order, "(%d+)") do
                        table.insert(order, tonumber(num))
                    end
                else
                    -- random order
                    order = {1, 2, 3, 4, 5}
                    for i = 5, 2, -1 do
                        local j = math.random(i)
                        order[i], order[j] = order[j], order[i]
                    end
                end

                if b_debug then DLOG("hostfakesplit_chaos: order="..table.concat(order, ",")) end

                -- send in designated order
                for _, idx in ipairs(order) do
                    local seg = segments[idx]
                    if seg and seg.enabled and #seg.data > 0 then
                        if b_debug then DLOG("hostfakesplit_chaos: sending "..seg.name.." offset="..seg.offset.." len="..#seg.data) end
                        if not rawsend_payload_segmented(desync, seg.data, seg.offset, seg.opts) then
                            return VERDICT_PASS
                        end
                    end
                end

                replay_drop_set(desync)
                return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
            else
                DLOG("hostfakesplit_chaos: host range cannot be resolved")
            end
        else
            DLOG("hostfakesplit_chaos: not acting on further replay pieces")
        end
        if replay_drop(desync) then
            return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
        end
    end
end


-- ============================================================================
-- HOSTFAKESPLIT_MULTI - multiple fakes with different domains
-- ============================================================================

--[[
hostfakesplit_multi - send multiple different fake SNIs

Sends several fakes across different domains instead of a single fake host
to induce DPI classification failure.

standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
arg : hosts=<str> - comma-separated domain list: google.com,vimeo.com,amazon.com
arg : midhost=<posmarker>
arg : nodrop
]]
function hostfakesplit_multi(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
    if #data > 0 and direction_check(desync) and payload_check(desync) then
        if replay_first(desync) then
            local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
            if pos then
                if b_debug then DLOG("hostfakesplit_multi: resolved host range: "..table.concat(zero_based_pos(pos), " ")) end

                local sni_len = pos[2] - pos[1] + 1

                -- parse host list
                local hosts = {}
                local hosts_str = desync.arg.hosts or "google.com,vimeo.com,amazon.com"
                for host in string.gmatch(hosts_str, "([^,]+)") do
                    table.insert(hosts, host)
                end

                local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
                local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

                local part

                -- before host
                part = string.sub(data, 1, pos[1] - 1)
                if b_debug then DLOG("hostfakesplit_multi: sending before_host") end
                if not rawsend_payload_segmented(desync, part, 0, opts_orig) then return VERDICT_PASS end

                -- fakes BEFORE real SNI
                for i, host in ipairs(hosts) do
                    local fakehost = genhost(sni_len, host)
                    if b_debug then DLOG("hostfakesplit_multi: sending fake"..i.." ("..host..")") end
                    if not rawsend_payload_segmented(desync, fakehost, pos[1] - 1, opts_fake) then return VERDICT_PASS end
                end

                -- real host
                local midhost
                if desync.arg.midhost then
                    midhost = resolve_pos(data, desync.l7payload, desync.arg.midhost)
                    if midhost and (midhost <= pos[1] or midhost > pos[2]) then
                        midhost = nil
                    end
                end

                if midhost then
                    part = string.sub(data, pos[1], midhost - 1)
                    if not rawsend_payload_segmented(desync, part, pos[1] - 1, opts_orig) then return VERDICT_PASS end
                    part = string.sub(data, midhost, pos[2])
                    if not rawsend_payload_segmented(desync, part, midhost - 1, opts_orig) then return VERDICT_PASS end
                else
                    part = string.sub(data, pos[1], pos[2])
                    if not rawsend_payload_segmented(desync, part, pos[1] - 1, opts_orig) then return VERDICT_PASS end
                end

                -- after host
                part = string.sub(data, pos[2] + 1)
                if not rawsend_payload_segmented(desync, part, pos[2], opts_orig) then return VERDICT_PASS end

                replay_drop_set(desync)
                return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
            else
                DLOG("hostfakesplit_multi: host range cannot be resolved")
            end
        else
            DLOG("hostfakesplit_multi: not acting on further replay pieces")
        end
        if replay_drop(desync) then
            return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
        end
    end
end


-- ============================================================================
-- HOSTFAKESPLIT_GRADUAL - phased delivery with split fake
-- ============================================================================

--[[
hostfakesplit_gradual - splits fake host into slices

Instead of sending the fake whole, splits it into small slices
and interleaves them with slices of the real SNI.

Pattern: fake_part1 -> real_part1 -> fake_part2 -> real_part2 -> ...

standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
arg : host=<str>
arg : parts=N - number of slices (default 3)
arg : nodrop
]]
function hostfakesplit_gradual(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
    if #data > 0 and direction_check(desync) and payload_check(desync) then
        if replay_first(desync) then
            local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
            if pos then
                if b_debug then DLOG("hostfakesplit_gradual: resolved host range: "..table.concat(zero_based_pos(pos), " ")) end

                local sni_len = pos[2] - pos[1] + 1
                local real_sni = string.sub(data, pos[1], pos[2])
                local fakehost = genhost(sni_len, desync.arg.host)
                local num_parts = tonumber(desync.arg.parts) or 3

                local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
                local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

                -- before host
                local part = string.sub(data, 1, pos[1] - 1)
                if b_debug then DLOG("hostfakesplit_gradual: sending before_host") end
                if not rawsend_payload_segmented(desync, part, 0, opts_orig) then return VERDICT_PASS end

                -- split SNI into slices and alternate fake/real
                local part_size = math.ceil(sni_len / num_parts)
                for i = 1, num_parts do
                    local start_idx = (i - 1) * part_size + 1
                    local end_idx = math.min(i * part_size, sni_len)
                    if start_idx > sni_len then break end

                    local fake_part = string.sub(fakehost, start_idx, end_idx)
                    local real_part = string.sub(real_sni, start_idx, end_idx)
                    local offset = pos[1] - 1 + start_idx - 1

                    -- fake slice first
                    if b_debug then DLOG("hostfakesplit_gradual: sending fake part "..i.." offset="..offset) end
                    if not rawsend_payload_segmented(desync, fake_part, offset, opts_fake) then return VERDICT_PASS end

                    -- real slice second
                    if b_debug then DLOG("hostfakesplit_gradual: sending real part "..i.." offset="..offset) end
                    if not rawsend_payload_segmented(desync, real_part, offset, opts_orig) then return VERDICT_PASS end
                end

                -- after host
                part = string.sub(data, pos[2] + 1)
                if b_debug then DLOG("hostfakesplit_gradual: sending after_host") end
                if not rawsend_payload_segmented(desync, part, pos[2], opts_orig) then return VERDICT_PASS end

                replay_drop_set(desync)
                return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
            else
                DLOG("hostfakesplit_gradual: host range cannot be resolved")
            end
        else
            DLOG("hostfakesplit_gradual: not acting on further replay pieces")
        end
        if replay_drop(desync) then
            return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
        end
    end
end


-- ============================================================================
-- HOSTFAKESPLIT_DECOY - send decoy packets around payload
-- ============================================================================

--[[
hostfakesplit_decoy - injects decoy junk packets

Sends additional decoy packets with randomized contents alongside fake SNI
to saturate DPI state and reassembly buffers.

standard args : direction, payload, fooling, ip_id, rawsend, reconstruct
arg : host=<str>
arg : decoys=N - number of decoy packets (default 2)
arg : decoy_size=N - size of each decoy in bytes (default 50)
arg : midhost=<posmarker>
arg : nodrop
]]
function hostfakesplit_decoy(ctx, desync)
    if not desync.dis.tcp then
        instance_cutoff_shim(ctx, desync)
        return
    end
    direction_cutoff_opposite(ctx, desync)
    local data = blob_or_def(desync, desync.arg.blob) or desync.reasm_data or desync.dis.payload
    if #data > 0 and direction_check(desync) and payload_check(desync) then
        if replay_first(desync) then
            local pos = resolve_range(data, desync.l7payload, "host,endhost-1", true)
            if pos then
                if b_debug then DLOG("hostfakesplit_decoy: resolved host range: "..table.concat(zero_based_pos(pos), " ")) end

                local sni_len = pos[2] - pos[1] + 1
                local fakehost = genhost(sni_len, desync.arg.host)
                local num_decoys = tonumber(desync.arg.decoys) or 2
                local decoy_size = tonumber(desync.arg.decoy_size) or 50

                local opts_orig = {rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = {tcp_ts_up = desync.arg.tcp_ts_up}}
                local opts_fake = {rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg}

                -- generate decoy data (random bytes)
                local function gen_decoy(size)
                    local s = ""
                    for i = 1, size do
                        s = s .. string.char(math.random(0, 255))
                    end
                    return s
                end

                local part

                -- decoys BEFORE
                for i = 1, num_decoys do
                    local decoy = gen_decoy(decoy_size)
                    local offset = math.random(0, pos[1] - 2)
                    if b_debug then DLOG("hostfakesplit_decoy: sending decoy "..i.." offset="..offset) end
                    rawsend_payload_segmented(desync, decoy, offset, opts_fake)
                end

                -- before host
                part = string.sub(data, 1, pos[1] - 1)
                if not rawsend_payload_segmented(desync, part, 0, opts_orig) then return VERDICT_PASS end

                -- fake
                if not desync.arg.nofake1 then
                    if not rawsend_payload_segmented(desync, fakehost, pos[1] - 1, opts_fake) then return VERDICT_PASS end
                end

                -- real host
                local midhost
                if desync.arg.midhost then
                    midhost = resolve_pos(data, desync.l7payload, desync.arg.midhost)
                    if midhost and (midhost <= pos[1] or midhost > pos[2]) then
                        midhost = nil
                    end
                end

                if midhost then
                    part = string.sub(data, pos[1], midhost - 1)
                    if not rawsend_payload_segmented(desync, part, pos[1] - 1, opts_orig) then return VERDICT_PASS end
                    part = string.sub(data, midhost, pos[2])
                    if not rawsend_payload_segmented(desync, part, midhost - 1, opts_orig) then return VERDICT_PASS end
                else
                    part = string.sub(data, pos[1], pos[2])
                    if not rawsend_payload_segmented(desync, part, pos[1] - 1, opts_orig) then return VERDICT_PASS end
                end

                -- fake2
                if not desync.arg.nofake2 then
                    if not rawsend_payload_segmented(desync, fakehost, pos[1] - 1, opts_fake) then return VERDICT_PASS end
                end

                -- after host
                part = string.sub(data, pos[2] + 1)
                if not rawsend_payload_segmented(desync, part, pos[2], opts_orig) then return VERDICT_PASS end

                -- decoys AFTER
                for i = 1, num_decoys do
                    local decoy = gen_decoy(decoy_size)
                    local offset = pos[2] + math.random(1, 50)
                    if b_debug then DLOG("hostfakesplit_decoy: sending trailing decoy "..i.." offset="..offset) end
                    rawsend_payload_segmented(desync, decoy, offset, opts_fake)
                end

                replay_drop_set(desync)
                return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
            else
                DLOG("hostfakesplit_decoy: host range cannot be resolved")
            end
        else
            DLOG("hostfakesplit_decoy: not acting on further replay pieces")
        end
        if replay_drop(desync) then
            return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
        end
    end
end


-- ============================================================================
-- ALIASES / SHORTCUTS
-- ============================================================================

-- snifakesplit = hostfakesplit (identical: host/endhost markers work for TLS as well)
function snifakesplit(ctx, desync)
    return hostfakesplit(ctx, desync)
end

-- hostfakesplit_soft - shortcut to soft mode
function hostfakesplit_soft(ctx, desync)
    desync.arg.mode = "soft"
    return hostfakesplit_stealth(ctx, desync)
end

-- hostfakesplit_blend - shortcut to blend mode
function hostfakesplit_blend(ctx, desync)
    desync.arg.mode = "blend"
    return hostfakesplit_stealth(ctx, desync)
end


DLOG("zapret-multishake.lua loaded")
