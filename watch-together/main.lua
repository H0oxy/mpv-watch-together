-- watch-together: one host and several guests keep pause/seek/speed/episode in sync over TCP
-- (made for Porthole, works over any TCP tunnel). Networking is done by bridge.ps1.
--
-- The host is the only authority. Guests never change the room state themselves: a local action
-- becomes a request; the host applies it (or refuses it in "only me" mode) and broadcasts a numbered
-- state to everyone. Periodic ticks only correct drift and are ignored while a guest's own request
-- is still unanswered, so a guest never gets pulled back by stale data.
local mp = require "mp"
local utils = require "mp.utils"
local options = require "mp.options"

local VERSION = "1.2.0"
local PROTOCOL = 2

local o = {
    port = 47800,
    bind = "127.0.0.1",     -- host listens here; Porthole forwards to localhost
    address = "127.0.0.1",  -- where "join" connects; with Porthole the host's port appears locally
    threshold = 0.3,        -- seconds of drift before a correcting seek
    lang = "auto",          -- auto (Windows display language) | ru | en
    control = "all",        -- host default: all | host (only the host controls playback)
    name = "",              -- shown to others; empty means the Steam name, else the Windows user name
    auto_update = true,     -- check GitHub releases at every start and offer a newer one
    max_guests = 50,        -- host: connections beyond this are refused
}
options.read_options(o, "watch_together")

local STRINGS = {
    ru = {
        menu = "Совместный просмотр",
        status = "Статус: %s",
        off = "не в комнате",
        listening = "комната открыта, ждём гостей",
        hosting = "комната открыта, гостей: %d",
        connecting = "подключаемся…",
        connected = "в комнате",
        lost = "хост не отвечает",
        you = "У тебя: %s",
        members = "Участники (%d)",
        host_tag = "хост",
        stale_tag = "не отвечает",
        paused_tag = "пауза",
        show_times = "Время участников на экране",
        control = "Управление",
        control_all = "Все участники",
        control_host = "Только я",
        copy_invite = "Скопировать адрес приглашения",
        invite_copied = "Скопировано: %s\nДрузья выбирают «Подключиться к адресу из буфера обмена»",
        no_address = "Не удалось узнать адрес этого компьютера",
        control_is = "Управление: %s",
        control_all_short = "все",
        control_host_short = "только хост",
        host = "Создать комнату (порт %d)",
        join = "Подключиться к другу (Porthole)",
        join_clipboard = "Подключиться к адресу из буфера обмена",
        leave = "Выйти из комнаты",
        version = "Версия %s",
        check_update = "Проверить обновления",
        by_paused = "%s: пауза",
        by_playing = "%s: воспроизведение",
        by_seek = "%s: перемотка на %s",
        by_speed = "%s: скорость %.2gx",
        by_file = "%s: включён файл %s",
        joined = "Участник %s подключился",
        member_left = "Участник %s отключился",
        old_version = "У участника %s старая версия плагина, пусть обновится",
        host_only = "Управлять может только хост",
        synced = "Синхронизировано с комнатой",
        mismatch = "У хоста другой файл (длительность %s, у тебя %s)\n%s",
        windows_only = "Совместный просмотр пока работает только на Windows",
        bridge_died = "Совместный просмотр остановлен (ошибка сети)",
        in_room = "Ты в комнате",
        host_dropped = "Связь с хостом потеряна, переподключаемся",
        error = "Ошибка: %s",
        hosted = "Комната открыта на порту %d.\nДобавь этот порт в лобби Porthole и пригласи друзей.",
        connecting_to = "Подключаемся к %s:%s…",
        bad_clipboard = "В буфере обмена нет адреса вида 1.2.3.4:47800",
        left = "Ты вышел из комнаты",
        updated = "Плагин обновлён до %s. Перезапусти mpv, чтобы применить",
        update_prompt = "Вышла новая версия watch-together %s (у тебя %s). Обновить?",
        update_ready = "Доступна версия %s: меню «Совместный просмотр» → «Обновить»",
        install_update = "Обновить до %s",
        yes = "Да",
        no = "Нет",
        up_to_date = "Установлена последняя версия (%s)",
        update_failed = "Не удалось проверить обновления: %s",
        seconds = "с",
        more = "…и ещё %d",
    },
    en = {
        menu = "Watch together",
        status = "Status: %s",
        off = "not in a room",
        listening = "room open, waiting for guests",
        hosting = "room open, guests: %d",
        connecting = "connecting…",
        connected = "in the room",
        lost = "host not responding",
        you = "You: %s",
        members = "Members (%d)",
        host_tag = "host",
        stale_tag = "not responding",
        paused_tag = "paused",
        show_times = "Show members' time on screen",
        control = "Control",
        control_all = "Everyone",
        control_host = "Only me",
        copy_invite = "Copy invite address",
        invite_copied = "Copied: %s\nFriends choose Join address from clipboard",
        no_address = "Could not find this PC's address",
        control_is = "Control: %s",
        control_all_short = "everyone",
        control_host_short = "host only",
        host = "Create room (port %d)",
        join = "Join friend (Porthole)",
        join_clipboard = "Join address from clipboard",
        leave = "Leave room",
        version = "Version %s",
        check_update = "Check for updates",
        by_paused = "%s: paused",
        by_playing = "%s: playing",
        by_seek = "%s: jumped to %s",
        by_speed = "%s: speed %.2gx",
        by_file = "%s: opened %s",
        joined = "%s joined",
        member_left = "%s left",
        old_version = "%s has an old plugin version and should update",
        host_only = "Only the host can control playback",
        synced = "Synced with the room",
        mismatch = "The host has a different file (duration %s, yours %s)\n%s",
        windows_only = "Watch together only works on Windows for now",
        bridge_died = "Watch together stopped (network error)",
        in_room = "You are in the room",
        host_dropped = "Lost connection to the host, reconnecting",
        error = "Error: %s",
        hosted = "Room open on port %d.\nShare this port in a Porthole lobby and invite your friends.",
        connecting_to = "Connecting to %s:%s…",
        bad_clipboard = "No address like 1.2.3.4:47800 in the clipboard",
        left = "You left the room",
        updated = "Plugin updated to %s. Restart mpv to apply it",
        update_prompt = "watch-together %s is out (you have %s). Update?",
        update_ready = "Version %s is available: Watch together menu → Update",
        install_update = "Update to %s",
        yes = "Yes",
        no = "No",
        up_to_date = "You have the latest version (%s)",
        update_failed = "Could not check for updates: %s",
        seconds = "s",
        more = "…and %d more",
    },
}
local lang = "en"  -- until the Windows display language is known
local function T(key, ...) return string.format(STRINGS[lang][key], ...) end

local my_name = (o.name ~= "" and o.name or os.getenv("USERNAME") or "mpv"):sub(1, 32)
local control = o.control == "host" and "host" or "all"

local role                  -- "host" | "join" | nil
local status = "off"
local helper                -- async subprocess handle of bridge.ps1
local rtt = 0.1             -- guest: smoothed round trip to the host
local last_rx = 0           -- guest: last message from the host

-- Changes we make ourselves to follow the room, so the observers don't report them as user actions.
local expected_pause, expected_speed
local own_seeks = {}        -- {pos, at, playing} of our recent follow seeks; mpv may merge several into one restart
local seek_latency = 0.05   -- smoothed time from our seek command to playback-restart
local expected_switch       -- playlist index we switched to because of the room
local loading = false
local quiet_until = 0       -- no "different file" warning right after an episode change
local warned_mismatch = false
local last_local_action = -10

-- host
local epoch = 0             -- bumped on every discrete change; guests use it to drop stale ticks
local members = {}          -- bridge id -> {name, file, dur, pos, paused, rtt, at, v}
local switch_by             -- name of the guest whose request made the host switch files

-- guest
local host_state            -- last state from the host, plus .received
local room                  -- last room info from the host: {control, members}
local pending               -- {count, at}: our requests the host hasn't answered yet

local update_available      -- release tag newer than VERSION, once checked

local show_panel = false
local PANEL_LINES = 20
local panel = mp.create_osd_overlay("ass-events")

local function osd(text) mp.osd_message(text, 3) end

local function fmt_time(t)
    t = math.floor(t + 0.5)
    return string.format("%d:%02d:%02d", math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
end

-- Cut long names on a UTF-8 boundary.
local function short(name, max)
    if not name then return "—" end
    local chars = {}
    for ch in name:gmatch("[^\128-\191][\128-\191]*") do chars[#chars + 1] = ch end
    if #chars > max then name = table.concat(chars, "", 1, max - 3) .. "..." end
    return name
end

-- "&" is a mnemonic in Windows menus.
local function menu_name(name) return (short(name, 60):gsub("&", "&&")) end

local function basename(path) return path:match("[^/\\]+$") or path end

local function in_room() return status == "connected" or status == "lost" or status == "hosting" end

------------------------------------------------------------------ room info

local function local_member()
    return { name = my_name, file = mp.get_property("filename"), pos = mp.get_property_number("time-pos"),
             paused = mp.get_property_native("pause"), host = role == "host" }
end

-- Host: the member list as everyone sees it; off = seconds ahead (+) or behind (-) the host.
local function room_info()
    local now = mp.get_time()
    local me = local_member()
    local list = { me }
    local speed = mp.get_property_number("speed", 1)
    local ids = {}
    for id in pairs(members) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local m = members[id]
        -- Every guest gets the whole list each second, so keep entries small.
        local e = { name = m.name, file = m.file and short(m.file, 80), pos = m.pos, paused = m.paused, stale = now - m.at > 6 }
        if m.pos and me.pos and m.file == me.file then
            local pos = m.pos + (m.paused and 0 or (now - m.at + (m.rtt or 0) / 2) * speed)
            e.off = pos - me.pos
        end
        list[#list + 1] = e
    end
    return { t = "room", control = control, members = list }
end

local function current_room()
    if role == "host" then return room_info() end
    return room
end

-- with_time: the on-screen panel, which keeps lines short so they stay in the right part of the screen.
local function member_label(m, with_time)
    local parts = { short(m.name, with_time and 20 or 24) }
    if m.host then parts[#parts + 1] = "(" .. T("host_tag") .. ")" end
    parts[#parts + 1] = "— " .. short(m.file, with_time and 28 or 40)
    if with_time and m.pos then parts[#parts + 1] = fmt_time(m.pos) end
    if with_time and m.off then parts[#parts + 1] = string.format("(%+.1f %s)", m.off, T("seconds")) end
    if m.paused then parts[#parts + 1] = "[" .. T("paused_tag") .. "]" end
    if m.stale then parts[#parts + 1] = "[" .. T("stale_tag") .. "]" end
    return table.concat(parts, " ")
end

local function ass_escape(s) return (s:gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")) end

local function update_panel()
    local r = current_room()
    if not show_panel or not r or not in_room() then
        panel:remove()
        return
    end
    local lines = {}
    local list = r.members or {}
    for i = 1, math.min(#list, PANEL_LINES) do lines[#lines + 1] = ass_escape(member_label(list[i], true)) end
    if #list > PANEL_LINES then lines[#lines + 1] = T("more", #list - PANEL_LINES) end
    -- Top right, below where fullscreen window buttons appear: the top left belongs to mpv's own
    -- messages (our notices, volume, seek time, stats), which would overlap the panel.
    local w, h = mp.get_osd_size()
    panel.res_y = 720
    panel.res_x = (w and h and w > 0 and h > 0) and math.floor(720 * w / h) or 1280
    panel.data = string.format("{\\an9\\pos(%d,%d)\\fs18\\bord1.5}", panel.res_x - 20, 50) .. table.concat(lines, "\\N")
    panel:update()
end

------------------------------------------------------------------ menu

-- Positions are left out on purpose: rewriting menu-data rebuilds the native menu, even while it is open.
local function menu_item()
    local active = helper ~= nil
    local function st(disabled, checked)
        local s = {}
        if disabled then s[#s + 1] = "disabled" end
        if checked then s[#s + 1] = "checked" end
        return s
    end
    local status_text = status == "hosting" and T("hosting", #(room_info().members) - 1) or T(status)
    local items = {
        { title = T("status", status_text), state = { "disabled" } },
        { title = T("you", menu_name(mp.get_property("filename"))), state = { "disabled" } },
    }
    local r = current_room()
    if in_room() and r and r.members then
        local sub = {}
        for _, m in ipairs(r.members) do sub[#sub + 1] = { title = menu_name(member_label(m, false)), state = { "disabled" } } end
        items[#items + 1] = { type = "submenu", title = T("members", #r.members), submenu = sub }
        items[#items + 1] = { title = T("show_times"), cmd = "script-message watch-together-panel", state = st(false, show_panel) }
    end
    if role == "host" then
        items[#items + 1] = { type = "submenu", title = T("control"), submenu = {
            { title = T("control_all"), cmd = "script-message watch-together-control all", state = st(false, control == "all") },
            { title = T("control_host"), cmd = "script-message watch-together-control host", state = st(false, control == "host") },
        } }
        items[#items + 1] = { title = T("copy_invite"), cmd = "script-message watch-together-invite" }
    elseif role == "join" and r then
        items[#items + 1] = { title = T("control_is", T(r.control == "host" and "control_host_short" or "control_all_short")), state = { "disabled" } }
    end
    for _, item in ipairs({
        { type = "separator" },
        { title = T("host", o.port), cmd = "script-message watch-together-host", state = st(active) },
        { title = T("join"), cmd = "script-message watch-together-join", state = st(active) },
        { title = T("join_clipboard"), cmd = "script-message watch-together-join-clipboard", state = st(active) },
        { title = T("leave"), cmd = "script-message watch-together-leave", state = st(not active) },
        { type = "separator" },
        { title = T("version", VERSION), state = { "disabled" } },
    }) do items[#items + 1] = item end
    if update_available then
        items[#items + 1] = { title = T("install_update", update_available), cmd = "script-message watch-together-install" }
    else
        items[#items + 1] = { title = T("check_update"), cmd = "script-message watch-together-update" }
    end
    return { type = "submenu", title = T("menu"), submenu = items }
end

-- Found by its commands, not its title: the title changes when the language is detected.
local function is_ours(item)
    for _, sub in ipairs(item.submenu or {}) do
        if sub.cmd == "script-message watch-together-leave" then return true end
    end
    return false
end

-- select.lua rewrites menu-data from menu.conf whenever its items change, so re-insert ours each time.
local function refresh_menu()
    local data = mp.get_property_native("menu-data")
    if type(data) ~= "table" then return end
    local mine = menu_item()
    for i, item in ipairs(data) do
        if is_ours(item) then
            if utils.format_json(item) == utils.format_json(mine) then return end
            table.remove(data, i)
            break
        end
    end
    table.insert(data, 1, mine)
    mp.set_property_native("menu-data", data)
end
mp.observe_property("menu-data", "native", refresh_menu)

-- Any "ru-*" display language means Russian.
local function set_lang(code)
    lang = tostring(code or ""):lower():match("^%s*ru") and "ru" or "en"
    mp.set_property("user-data/watch-together/lang", lang)
    refresh_menu()
end
if o.lang ~= "auto" then set_lang(o.lang) end
mp.set_property("user-data/watch-together/name", my_name)

-- mpv knows neither the OS language nor the Steam name, so ask Windows once at startup.
if mp.get_property_native("platform") == "windows" and (o.lang == "auto" or o.name == "") then
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                 "-File", utils.join_path(mp.get_script_directory(), "sysinfo.ps1") },
    }, function(ok, res)
        local info = ok and res.status == 0 and utils.parse_json(res.stdout or "")
        if type(info) ~= "table" then return end
        if o.name == "" and type(info.steam) == "string" and info.steam ~= "" then
            my_name = short(info.steam, 32)
            mp.set_property("user-data/watch-together/name", my_name)
        end
        if o.lang == "auto" then set_lang(info.lang) end
    end)
end

local function publish()
    mp.set_property("user-data/watch-together/status", status)  -- for tests and other scripts
    mp.set_property_native("user-data/watch-together/room", current_room() or {})
end

local function set_status(s)
    status = s
    publish()
    refresh_menu()
    update_panel()
end

------------------------------------------------------------------ messages

local function send(target, msg)
    mp.commandv("script-message", "watch-together-out", target, utils.format_json(msg))
end

local function valid_state(m)
    return type(m.pos) == "number" and m.pos >= 0 and m.pos < 1e7
       and type(m.speed) == "number" and m.speed >= 0.01 and m.speed <= 100
       and type(m.paused) == "boolean"
end

-- Different durations mean different files: syncing them would only jump around.
local function same_file(dur)
    local mine, name = mp.get_property_number("duration"), mp.get_property("filename")
    if not mine then return false end
    if type(dur) ~= "number" or math.abs(dur - mine) <= 1 then
        warned_mismatch = false
        return type(dur) == "number"
    end
    if not warned_mismatch and mp.get_time() > quiet_until then
        warned_mismatch = true
        osd(T("mismatch", fmt_time(dur), fmt_time(mine), name or ""))
    end
    return false
end

-- Same file name in my playlist first; different releases fall back to the same playlist position.
local function follow_file(m)
    if type(m.file) ~= "string" or m.file == mp.get_property("filename") then return false end
    local playlist = mp.get_property_native("playlist") or {}
    local index
    for i, entry in ipairs(playlist) do
        if basename(entry.filename) == m.file then index = i - 1 break end
    end
    if not index and type(m.pl) == "number" and m.pl >= 0 and m.pl < #playlist then index = m.pl end
    if not index or index == mp.get_property_number("playlist-pos") then return false end
    expected_switch = index
    quiet_until = mp.get_time() + 3
    mp.commandv("playlist-play-index", index)
    return true
end

-- Bring this player to a state without reporting the resulting property changes as user actions.
local function apply(paused, target, speed)
    if math.abs(speed - mp.get_property_number("speed", 1)) > 1e-3 then
        expected_speed = speed
        mp.set_property_number("speed", speed)
    end
    local cur = mp.get_property_number("time-pos")
    -- A seek while paused is invisible, so line up to about a frame then; while playing every seek
    -- stutters, so only real drift is corrected. The paused limit stays above one frame, or a
    -- player with a coarse frame rate would seek again on every tick.
    local fps = mp.get_property_number("container-fps", 25)
    local limit = paused and math.max(0.1, 1.5 / math.max(fps, 1)) or o.threshold
    if cur and math.abs(cur - target) > limit then
        -- The picture stands still while an exact seek decodes, and the room keeps playing:
        -- aim ahead by this player's usual seek time so we land level with everyone else.
        if not paused then target = target + seek_latency * speed end
        own_seeks[#own_seeks + 1] = { pos = target, at = mp.get_time(), playing = not paused }
        mp.msg.debug(string.format("follow seek %.2f -> %.2f", cur, target))
        mp.commandv("seek", target, "absolute+exact")
    end
    if paused ~= mp.get_property_native("pause") then
        expected_pause = paused
        mp.set_property_native("pause", paused)
    end
end

local room_name             -- guest: our name as the host shows it

-- The host may rename us to keep names unique; until it says so, our own name is used.
local function is_me(by) return by ~= nil and by == (room_name or my_name) end

local function notify(ev, by, m)
    if not by or is_me(by) then return end
    if ev == "pause" then osd(T(m.paused and "by_paused" or "by_playing", by))
    elseif ev == "seek" then osd(T("by_seek", by, fmt_time(m.pos)))
    elseif ev == "speed" then osd(T("by_speed", by, m.speed))
    elseif ev == "file" and type(m.file) == "string" then osd(T("by_file", by, m.file))
    end
end

------------------------------------------------------------------ host side

local function host_state_msg(ev, by, pos, paused, speed)
    if paused == nil then paused = mp.get_property_native("pause") end
    return { t = "state", epoch = epoch, ev = ev, by = by,
             pos = pos or mp.get_property_number("time-pos"),
             paused = paused,
             speed = speed or mp.get_property_number("speed", 1),
             dur = mp.get_property_number("duration"), file = mp.get_property("filename"),
             pl = mp.get_property_number("playlist-pos") }
end

-- A discrete change: new epoch, sent to everyone.
local function broadcast(ev, by, pos, paused, speed)
    epoch = epoch + 1
    local m = host_state_msg(ev, by, pos, paused, speed)
    if m.pos then send("*", m) end
end

local function on_guest_message(id, m)
    local g = members[id]
    if not g then return end
    g.at = mp.get_time()
    if m.t == "req" then mp.msg.debug(string.format("req from %s: %s pos=%s paused=%s", g.name, tostring(m.ev), tostring(m.pos), tostring(m.paused))) end

    if m.t == "hello" then
        local name = type(m.name) == "string" and m.name:sub(1, 32) or id
        for other_id, other in pairs(members) do
            if other_id ~= id and other.name == name then name = name .. " (" .. id .. ")" end
        end
        if name == my_name then name = name .. " (" .. id .. ")" end
        g.name, g.v = name, m.v
        if m.v ~= PROTOCOL then
            osd(T("old_version", name))
            return
        end
        osd(T("joined", name))
        for other_id in pairs(members) do
            if other_id ~= id then send(other_id, { t = "notice", key = "joined", name = name }) end
        end
        local s = host_state_msg("sync")
        s.you = name  -- the guest learns its name in the room (it may have been made unique)
        if s.pos then send(id, s) else send(id, { t = "welcome", you = name }) end
        set_status("hosting")
    elseif m.t == "ping" then
        send(id, { t = "pong", id = m.id })
    elseif m.t == "status" then
        g.file = type(m.file) == "string" and m.file:sub(1, 512) or nil
        g.pos = type(m.pos) == "number" and m.pos or nil
        g.paused = m.paused == true
        g.rtt = type(m.rtt) == "number" and m.rtt or nil
    elseif m.t == "req" then
        if control ~= "all" or not valid_state(m) then
            local s = host_state_msg("sync")  -- puts the guest back
            if s.pos then send(id, s) end
            return
        end
        if m.ev == "file" then
            if follow_file(m) then
                switch_by = g.name   -- broadcast after the file has loaded
                osd(T("by_file", g.name, m.file))
            else
                local s = host_state_msg("sync")
                if s.pos then send(id, s) end
            end
            return
        end
        local target = m.pos + (m.paused and 0 or (g.rtt or 0.1) / 2 * m.speed)
        apply(m.paused, target, m.speed)
        notify(m.ev, g.name, m)
        broadcast(m.ev, g.name, target, m.paused, m.speed)
    end
end

------------------------------------------------------------------ guest side

-- Where the host is now, judging by its last state.
local function host_now(m)
    if m.paused then return m.pos end
    return m.pos + ((mp.get_time() - m.received) + rtt / 2) * m.speed
end

local function apply_host_state()
    local m = host_state
    if not m then return end
    if follow_file(m) then return end      -- the rest happens after the file has loaded
    if not same_file(m.dur) then return end
    apply(m.paused, host_now(m), m.speed)
end

local function on_host_message(m)
    last_rx = mp.get_time()
    if status == "lost" then set_status("connected") end

    if type(m.you) == "string" then room_name = m.you end
    if m.t == "pong" and type(m.id) == "number" then
        local sample = mp.get_time() - m.id
        if sample >= 0 and sample < 10 then rtt = rtt * 0.7 + sample * 0.3 end
    elseif m.t == "notice" and type(m.name) == "string" then
        if m.key == "joined" then osd(T("joined", m.name)) elseif m.key == "left" then osd(T("member_left", m.name)) end
    elseif m.t == "room" and type(m.members) == "table" then
        local before = room and room.control
        room = { control = m.control == "host" and "host" or "all", members = m.members }
        if before and before ~= room.control then
            osd(T("control_is", T(room.control == "host" and "control_host_short" or "control_all_short")))
        end
        publish()
        refresh_menu()
        update_panel()
    elseif m.t == "state" and valid_state(m) then
        m.received = mp.get_time()
        if m.ev ~= "tick" then
            mp.msg.debug(string.format("state e%s %s by %s pos=%.2f paused=%s pending=%s", tostring(m.epoch), m.ev,
                tostring(m.by), m.pos, tostring(m.paused), tostring(pending and pending.count)))
            host_state = m
            -- The answer to our own request: we already did that locally, and we may have done more
            -- since (a seek right after unpausing). Applying it would undo the newer action; ticks
            -- take care of any small difference later.
            if is_me(m.by) then
                if pending then
                    pending.count = pending.count - 1
                    if pending.count <= 0 then pending = nil end
                end
                return
            end
            local switching = follow_file(m)
            if not switching and same_file(m.dur) then apply(m.paused, host_now(m), m.speed) end
            if m.ev == "sync" then osd(T("synced")) else notify(m.ev, m.by, m) end
            return
        end
        -- Wait a moment so that mpv's queued seek/restart events of a user action are handled before
        -- the drift is judged, then skip the tick if we are seeking or waiting for the host's answer.
        mp.add_timeout(0.25, function()
            if role ~= "join" then return end
            if pending and mp.get_time() - pending.at < 3 then return end
            pending = nil
            if mp.get_property_native("seeking") or mp.get_time() - last_local_action < 1.5 then return end
            if host_state and type(host_state.epoch) == "number" and type(m.epoch) == "number"
               and m.epoch < host_state.epoch then return end
            host_state = m
            apply_host_state()
        end)
    end
end

------------------------------------------------------------------ local actions

local function local_req(ev)
    local m = { t = "req", ev = ev, pos = mp.get_property_number("time-pos"), paused = mp.get_property_native("pause"),
                speed = mp.get_property_number("speed", 1), dur = mp.get_property_number("duration"),
                file = mp.get_property("filename"), pl = mp.get_property_number("playlist-pos") }
    return m.pos and m
end

-- The user paused, seeked, changed speed or opened another file.
local function local_action(ev)
    last_local_action = mp.get_time()
    mp.msg.debug("local action " .. ev .. " at " .. tostring(mp.get_property_number("time-pos")))
    if role == "host" then
        if status == "hosting" or status == "listening" then broadcast(ev, my_name) end
    elseif role == "join" and (status == "connected" or status == "lost") then
        if room and room.control == "host" then
            osd(T("host_only"))
            apply_host_state()
            return
        end
        local m = local_req(ev)
        if not m then return end
        pending = { count = (pending and pending.count or 0) + 1, at = mp.get_time() }
        send("host", m)
    end
end

------------------------------------------------------------------ bridge process

local function stop()
    if helper then
        local h = helper
        helper = nil
        mp.abort_async_command(h)
    end
    role, members, room, host_state, pending, switch_by, room_name = nil, {}, nil, nil, nil, nil, nil
    set_status("off")
end

local function ipc_pipe_name()
    local ipc = mp.get_property("input-ipc-server")
    if ipc == "" then
        ipc = "mpv-watch-together-" .. mp.get_property("pid")
        mp.set_property("input-ipc-server", ipc)
    end
    -- shortcut: assumes a plain pipe name or \\.\pipe\ prefix, not a /tmp-style path.
    return (ipc:gsub("^\\\\%.\\pipe\\", ""))
end

local function start(mode, address, port)
    if mp.get_property_native("platform") ~= "windows" then
        osd(T("windows_only"))
        return false
    end
    stop()
    role = mode
    local args = {
        "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
        "-File", utils.join_path(mp.get_script_directory(), "bridge.ps1"),
        "-Pipe", ipc_pipe_name(), "-Mode", mode, "-Script", mp.get_script_name(),
        "-Address", address, "-Port", tostring(port), "-Bind", o.bind, "-MaxPeers", tostring(o.max_guests),
    }
    local h
    h = mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
                                  capture_stderr = true }, function(_, res)
        if helper ~= h then return end  -- stopped on purpose
        helper = nil
        stop()
        osd(T("bridge_died"))
        mp.msg.error("bridge.ps1 exited: " .. utils.format_json(res))
    end)
    helper = h
    set_status(mode == "host" and "listening" or "connecting")
    return true
end

mp.register_script_message("watch-together-net", function(kind, id, data)
    if not helper then return end
    if kind == "in" then
        local m = utils.parse_json(data or "")
        if type(m) ~= "table" then return end
        if role == "host" then on_guest_message(id, m) else on_host_message(m) end
    elseif kind == "connected" then
        if role == "host" then
            members[id] = { name = id, at = mp.get_time() }  -- named by its hello
        else
            last_rx = mp.get_time()
            set_status("connected")
            osd(T("in_room"))
            send("host", { t = "hello", v = PROTOCOL, name = my_name })
        end
    elseif kind == "disconnected" then
        if role == "host" then
            local g = members[id]
            members[id] = nil
            if g and g.v == PROTOCOL then
                osd(T("member_left", g.name))
                send("*", { t = "notice", key = "left", name = g.name })
            end
            set_status(next(members) and "hosting" or "listening")
        else
            host_state, room, pending = nil, nil, nil
            set_status("connecting")
            osd(T("host_dropped"))
        end
    elseif kind == "listening" or kind == "connecting" then
        set_status(kind)
    elseif kind == "error" then
        osd(T("error", tostring(id)))
        stop()
    end
end)

------------------------------------------------------------------ menu actions

local function host()
    if start("host", o.bind, o.port) then osd(T("hosted", o.port)) end
end

local function join()
    if start("join", o.address, o.port) then osd(T("connecting_to", o.address, o.port)) end
end

local function join_clipboard()
    mp.commandv("update-clipboard", "text")
    local text = (mp.get_property("clipboard/text") or ""):match("^%s*(.-)%s*$")
    local addr, port = text:match("^([%w%.%-]+):(%d+)$")
    if not addr then addr, port = text:match("^([%w%.%-]+)$"), o.port end
    port = tonumber(port)
    if not addr or not port or port < 1 or port > 65535 then
        osd(T("bad_clipboard"))
        return
    end
    if start("join", addr, port) then osd(T("connecting_to", addr, port)) end
end

local function leave()
    stop()
    osd(T("left"))
end

local function set_control(value)
    if role ~= "host" or (value ~= "all" and value ~= "host") then return end
    control = value
    osd(T("control_is", T(control == "host" and "control_host_short" or "control_all_short")))
    send("*", room_info())
    publish()
    refresh_menu()
end

-- Which of this PC's addresses friends most likely can reach. Lower is better.
local function ip_rank(ip)
    local a, b = ip:match("^(%d+)%.(%d+)%.")
    a, b = tonumber(a), tonumber(b)
    if not a then return 9 end
    if a == 100 and b >= 64 and b <= 127 then return 1 end  -- Tailscale
    if a == 192 and b == 168 then return 2 end
    if a == 10 then return 3 end
    if a == 169 and b == 254 then return 8 end              -- no DHCP answer
    if a == 172 and b >= 16 and b <= 31 then return 6 end   -- often Hyper-V/WSL virtual adapters
    return 4                                                -- public address
end

-- "address:port" for "Join address from clipboard". With Porthole (bind 127.0.0.1) that is
-- the local address the guests' Porthole opens; with bind=0.0.0.0 it is this PC's best address.
local function copy_invite()
    if role ~= "host" then return end
    local function copy(addr)
        local text = addr .. ":" .. o.port
        mp.set_property("clipboard/text", text)
        osd(T("invite_copied", text))
    end
    if o.bind ~= "0.0.0.0" then copy(o.bind) return end
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                 "-File", utils.join_path(mp.get_script_directory(), "sysinfo.ps1"), "-Addresses" },
    }, function(ok, res)
        local info = ok and res.status == 0 and utils.parse_json(res.stdout or "")
        local ips = type(info) == "table" and info.ips or {}
        if type(ips) == "string" then ips = { ips } end
        table.sort(ips, function(x, y) return ip_rank(x) < ip_rank(y) end)
        if ips[1] then copy(ips[1]) else osd(T("no_address")) end
    end)
end

local function toggle_panel()
    show_panel = not show_panel
    update_panel()
    refresh_menu()
end

------------------------------------------------------------------ auto-update

-- update.ps1 prints one line: "available <tag>", "latest", "updated <tag>" or "error <text>".
local function run_updater(extra, cb)
    if mp.get_property_native("platform") ~= "windows" then return end
    local args = { "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                   "-File", utils.join_path(mp.get_script_directory(), "update.ps1"),
                   "-Dir", mp.get_script_directory(), "-Current", VERSION }
    for _, a in ipairs(extra) do args[#args + 1] = a end
    mp.command_native_async({ name = "subprocess", args = args, playback_only = false, capture_stdout = true },
        function(ok, res)
            local out = ok and (res.stdout or ""):match("^%s*(.-)%s*$") or "error subprocess failed"
            local word, rest = out:match("^(%S+)%s*(.*)$")
            cb(word or "error", rest or out)
        end)
end

local function install_update(tag)
    run_updater({ "-Install", tag }, function(word, rest)
        if word == "updated" then
            update_available = nil
            refresh_menu()
            osd(T("updated", rest))
        else
            osd(T("update_failed", rest))
        end
    end)
end

local function ask_update(tag)
    local ok, input = pcall(require, "mp.input")
    if not ok then osd(T("update_ready", tag)) return end  -- no console: the menu item stays
    input.select({
        prompt = T("update_prompt", tag, VERSION),
        items = { T("yes"), T("no") },
        default_item = 1,
        submit = function(i) if i == 1 then install_update(tag) end end,
    })
end

-- interactive: the user asked from the menu, so also report "latest" and errors.
local function check_update(interactive)
    run_updater({}, function(word, rest)
        if word == "available" then
            update_available = rest
            refresh_menu()
            ask_update(rest)
        elseif interactive then
            osd(word == "latest" and T("up_to_date", VERSION) or T("update_failed", rest))
        elseif word == "error" then
            mp.msg.warn("update check: " .. rest)
        end
    end)
end

mp.register_script_message("watch-together-host", host)
mp.register_script_message("watch-together-join", join)
mp.register_script_message("watch-together-join-clipboard", join_clipboard)
mp.register_script_message("watch-together-leave", leave)
mp.register_script_message("watch-together-control", set_control)
mp.register_script_message("watch-together-panel", toggle_panel)
mp.register_script_message("watch-together-invite", copy_invite)
mp.register_script_message("watch-together-update", function() check_update(true) end)
mp.register_script_message("watch-together-install", function()
    if update_available then install_update(update_available) end
end)
-- Keyless bindings for players without a context menu: bind in input.conf, e.g. `Ctrl+h script-binding watch_together/host`.
mp.add_key_binding(nil, "host", host)
mp.add_key_binding(nil, "join", join)
mp.add_key_binding(nil, "leave", leave)
mp.add_key_binding(nil, "members", toggle_panel)

-- A short delay so the question shows up over the video, not before the window opens.
if o.auto_update then mp.add_timeout(3, function() check_update(false) end) end

------------------------------------------------------------------ local changes

mp.observe_property("pause", "bool", function(_, paused)
    if paused == expected_pause then expected_pause = nil return end
    local_action("pause")
    refresh_menu()
end)

mp.observe_property("speed", "number", function(_, speed)
    if expected_speed and math.abs(speed - expected_speed) < 1e-3 then expected_speed = nil return end
    local_action("speed")
end)

mp.register_event("file-loaded", function()
    loading = true
    warned_mismatch = false
    quiet_until = mp.get_time() + 3
    local followed = expected_switch ~= nil and expected_switch == mp.get_property_number("playlist-pos")
    expected_switch = nil
    if role == "host" then
        local by = switch_by or my_name
        switch_by = nil
        if status == "hosting" or status == "listening" then broadcast("file", by) end
    elseif role == "join" then
        if followed then apply_host_state() else local_action("file") end
    end
    refresh_menu()
end)

mp.register_event("playback-restart", function()
    if loading then loading = false return end  -- start of a file, not a user seek
    -- Ours if we landed where we aimed. A user seek merged with ours lands elsewhere and is still sent.
    local pos, now = mp.get_property_number("time-pos"), mp.get_time()
    local ours = false
    for i = #own_seeks, 1, -1 do
        local s = own_seeks[i]
        if now - s.at > 5 then
            table.remove(own_seeks, i)
        elseif not ours and pos and math.abs(pos - s.pos) < 1 then
            ours = true
            table.remove(own_seeks, i)
            if s.playing then seek_latency = math.min(1, seek_latency * 0.7 + (now - s.at) * 0.3) end
        end
    end
    if not ours then local_action("seek") end
end)

mp.add_periodic_timer(1, function()
    if role == "host" and status == "hosting" then
        local s = host_state_msg("tick")
        if s.pos then send("*", s) end
        send("*", room_info())
        publish()
        refresh_menu()  -- members' files and pauses; unchanged menus are not rewritten
    elseif role == "join" and (status == "connected" or status == "lost") then
        send("host", { t = "ping", id = mp.get_time() })
        send("host", { t = "status", file = mp.get_property("filename"), pos = mp.get_property_number("time-pos"),
                       paused = mp.get_property_native("pause"), rtt = rtt })
        if status == "connected" and mp.get_time() - last_rx > 6 then
            set_status("lost")
            osd(T("lost"))
        end
    end
    update_panel()
end)

mp.register_event("shutdown", stop)
publish()
