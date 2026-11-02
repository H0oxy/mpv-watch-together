-- watch-together: synchronized pause/seek/speed between two mpv players over one TCP link
-- (made for Porthole, works over any TCP tunnel). Networking is done by bridge.ps1.
local mp = require "mp"
local utils = require "mp.utils"
local options = require "mp.options"

local o = {
    port = 47800,
    bind = "127.0.0.1",     -- host listens here; Porthole forwards to localhost
    address = "127.0.0.1",  -- where "join" connects; with Porthole the host's port appears locally
    threshold = 0.3,        -- seconds of drift before a correcting seek
}
options.read_options(o, "watch_together")

local MENU_TITLE = "Совместный просмотр"
local STATUS_TEXT = {
    off = "не в комнате",
    listening = "комната открыта, ждём друга",
    connecting = "подключаемся…",
    connected = "друг подключён",
    disconnected = "друг отключился, ждём",
    lost = "друг не отвечает",
}

local role            -- "host" | "join" | nil
local status = "off"
local helper          -- async subprocess handle of bridge.ps1
local rtt = 0.1
local last_rx = 0
local expected_pause, expected_speed
local ignore_restart_until = 0
local loading = false
local warned_mismatch = false
local quiet_until = 0       -- no "different file" warning right after an episode change
local expected_switch       -- playlist index we switched to because the friend did
local peer_name             -- friend's current file name

local function osd(text) mp.osd_message(text, 3) end

-- Menu titles: cut long names on a UTF-8 boundary, and "&" is a mnemonic in Windows menus.
local function menu_name(name)
    if not name then return "—" end
    local chars = {}
    for ch in name:gmatch("[^\128-\191][\128-\191]*") do chars[#chars + 1] = ch end
    if #chars > 60 then name = table.concat(chars, "", 1, 57) .. "..." end
    return (name:gsub("&", "&&"))
end

local function fmt_time(t)
    t = math.floor(t + 0.5)
    return string.format("%d:%02d:%02d", math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
end

------------------------------------------------------------------ menu

local function menu_item()
    local active = helper ~= nil
    local function st(disabled) return disabled and { "disabled" } or {} end
    return {
        type = "submenu",
        title = MENU_TITLE,
        submenu = {
            { title = "Статус: " .. STATUS_TEXT[status], state = { "disabled" } },
            { title = "У тебя: " .. menu_name(mp.get_property("filename")), state = { "disabled" } },
            { title = "У друга: " .. menu_name(peer_name), state = { "disabled" } },
            { type = "separator" },
            { title = "Создать комнату (порт " .. o.port .. ")", cmd = "script-message watch-together-host", state = st(active) },
            { title = "Подключиться к другу (Porthole)", cmd = "script-message watch-together-join", state = st(active) },
            { title = "Подключиться к адресу из буфера обмена", cmd = "script-message watch-together-join-clipboard", state = st(active) },
            { title = "Выйти из комнаты", cmd = "script-message watch-together-leave", state = st(not active) },
        },
    }
end

-- select.lua rewrites menu-data from menu.conf whenever its items change, so re-insert ours each time.
local function refresh_menu()
    local data = mp.get_property_native("menu-data")
    if type(data) ~= "table" then return end
    local mine = menu_item()
    for i, item in ipairs(data) do
        if item.title == MENU_TITLE then
            if utils.format_json(item) == utils.format_json(mine) then return end
            table.remove(data, i)
            break
        end
    end
    table.insert(data, 1, mine)
    mp.set_property_native("menu-data", data)
end
mp.observe_property("menu-data", "native", refresh_menu)

local function set_status(s)
    status = s
    mp.set_property("user-data/watch-together/status", s)  -- for tests and other scripts
    refresh_menu()
end

------------------------------------------------------------------ messages

local function send(msg)
    if status ~= "connected" and status ~= "lost" then return end
    mp.commandv("script-message", "watch-together-out", utils.format_json(msg))
end

local function file_info()
    return mp.get_property_number("duration"), mp.get_property("filename")
end

local function send_state(ev)
    local pos = mp.get_property_number("time-pos")
    local dur = file_info()
    if not pos or not dur then return end
    send({ t = "state", ev = ev, pos = pos, dur = dur,
           paused = mp.get_property_native("pause"), speed = mp.get_property_number("speed") })
end

-- follow=true asks the friend to switch to this file (manual episode change, or the host on connect).
local function send_hello(follow)
    local dur, name = file_info()
    send({ t = "hello", dur = dur, name = name, pl = mp.get_property_number("playlist-pos"), follow = follow })
end

local function basename(path) return path:match("[^/\\]+$") or path end

-- Same file name in my playlist first; different releases fall back to the same playlist position.
local function follow_file(m)
    if type(m.name) ~= "string" or m.name == mp.get_property("filename") then return false end
    local playlist = mp.get_property_native("playlist") or {}
    local index
    for i, entry in ipairs(playlist) do
        if basename(entry.filename) == m.name then index = i - 1 break end
    end
    if not index and type(m.pl) == "number" and m.pl >= 0 and m.pl < #playlist then index = m.pl end
    if not index or index == mp.get_property_number("playlist-pos") then return false end
    expected_switch = index
    quiet_until = mp.get_time() + 3
    mp.commandv("playlist-play-index", index)
    osd("Друг включил: " .. m.name)
    return true
end

-- Different durations mean different files: syncing them would only jump around.
local function same_file(dur)
    local mine, name = file_info()
    if not mine then return false end
    if type(dur) ~= "number" or math.abs(dur - mine) <= 1 then
        warned_mismatch = false
        return type(dur) == "number"
    end
    if not warned_mismatch and mp.get_time() > quiet_until then
        warned_mismatch = true
        osd("У друга другой файл (длительность " .. fmt_time(dur) .. ", у тебя " .. fmt_time(mine) .. ")\n" .. (name or ""))
    end
    return false
end

local function valid_state(m)
    return type(m.pos) == "number" and m.pos >= 0 and m.pos < 1e7
       and type(m.speed) == "number" and m.speed >= 0.01 and m.speed <= 100
       and type(m.paused) == "boolean"
end

local function apply_state(m)
    if not valid_state(m) or not same_file(m.dur) then return end

    if math.abs(m.speed - mp.get_property_number("speed", 1)) > 1e-3 then
        expected_speed = m.speed
        mp.set_property_number("speed", m.speed)
        if m.ev == "speed" then osd(string.format("Друг: скорость %.2gx", m.speed)) end
    end

    local target = m.pos + (m.paused and 0 or rtt / 2 * m.speed)
    local cur = mp.get_property_number("time-pos")
    if cur and math.abs(cur - target) > o.threshold then
        ignore_restart_until = mp.get_time() + 2
        mp.commandv("seek", target, "absolute+exact")
        if m.ev == "seek" then osd("Друг перемотал на " .. fmt_time(target)) end
    end

    if m.paused ~= mp.get_property_native("pause") then
        expected_pause = m.paused
        mp.set_property_native("pause", m.paused)
        if m.ev == "pause" then osd(m.paused and "Друг: пауза" or "Друг: воспроизведение") end
    end

    if m.ev == "sync" then osd("Синхронизировано с другом") end
end

local function on_peer_message(line)
    local m = utils.parse_json(line)
    if type(m) ~= "table" then return end
    last_rx = mp.get_time()
    if status == "lost" then set_status("connected") end

    if m.t == "ping" then
        send({ t = "pong", id = m.id })
    elseif m.t == "pong" and type(m.id) == "number" then
        local sample = mp.get_time() - m.id
        if sample >= 0 and sample < 10 then rtt = rtt * 0.7 + sample * 0.3 end
    elseif m.t == "hello" then
        peer_name = type(m.name) == "string" and m.name:sub(1, 512) or nil
        mp.set_property("user-data/watch-together/peer-file", peer_name or "")
        refresh_menu()
        if m.follow == true and follow_file(m) then return end  -- our own hello follows after loading
        same_file(m.dur)
        if role == "host" then send_state("sync") end
    elseif m.t == "state" then
        if m.ev == "tick" and role ~= "join" then return end  -- only the host's clock is the reference
        apply_state(m)
    end
end

------------------------------------------------------------------ bridge process

local function stop()
    if helper then
        local h = helper
        helper = nil
        mp.abort_async_command(h)
    end
    role = nil
    peer_name = nil
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
        osd("Совместный просмотр пока работает только на Windows")
        return
    end
    stop()
    role = mode
    local args = {
        "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
        "-File", utils.join_path(mp.get_script_directory(), "bridge.ps1"),
        "-Pipe", ipc_pipe_name(), "-Mode", mode, "-Script", mp.get_script_name(),
        "-Address", address, "-Port", tostring(port), "-Bind", o.bind,
    }
    local h
    h = mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
                                  capture_stderr = true }, function(_, res)
        if helper ~= h then return end  -- stopped on purpose
        helper = nil
        role = nil
        set_status("off")
        osd("Совместный просмотр остановлен (ошибка сети)")
        mp.msg.error("bridge.ps1 exited: " .. utils.format_json(res))
    end)
    helper = h
    set_status(mode == "host" and "listening" or "connecting")
end

mp.register_script_message("watch-together-net", function(kind, data)
    if not helper then return end
    if kind == "in" then
        on_peer_message(data)
    elseif kind == "connected" then
        last_rx = mp.get_time()
        set_status("connected")
        osd("Друг подключился")
        send_hello(role == "host")  -- the friend jumps to the host's episode
    elseif kind == "disconnected" then
        peer_name = nil
        set_status(role == "host" and "disconnected" or "connecting")
        osd("Связь с другом потеряна, ждём переподключения")
    elseif kind == "listening" or kind == "connecting" then
        set_status(kind)
    elseif kind == "error" then
        osd("Ошибка: " .. tostring(data))
        stop()
    end
end)

------------------------------------------------------------------ menu actions

local function host()
    start("host", o.bind, o.port)
    osd("Комната открыта на порту " .. o.port .. ".\nДобавь этот порт в лобби Porthole и пригласи друга.")
end

local function join()
    start("join", o.address, o.port)
    osd("Подключаемся к " .. o.address .. ":" .. o.port .. "…")
end

local function join_clipboard()
    mp.commandv("update-clipboard", "text")
    local text = (mp.get_property("clipboard/text") or ""):match("^%s*(.-)%s*$")
    local addr, port = text:match("^([%w%.%-]+):(%d+)$")
    if not addr then addr, port = text:match("^([%w%.%-]+)$"), o.port end
    port = tonumber(port)
    if not addr or not port or port < 1 or port > 65535 then
        osd("В буфере обмена нет адреса вида 1.2.3.4:47800")
        return
    end
    start("join", addr, port)
    osd("Подключаемся к " .. addr .. ":" .. port .. "…")
end

local function leave()
    stop()
    osd("Ты вышел из комнаты")
end

mp.register_script_message("watch-together-host", host)
mp.register_script_message("watch-together-join", join)
mp.register_script_message("watch-together-join-clipboard", join_clipboard)
mp.register_script_message("watch-together-leave", leave)
-- Keyless bindings for players without a context menu: bind in input.conf, e.g. `Ctrl+h script-binding watch_together/host`.
mp.add_key_binding(nil, "host", host)
mp.add_key_binding(nil, "join", join)
mp.add_key_binding(nil, "leave", leave)

------------------------------------------------------------------ local changes -> peer

mp.observe_property("pause", "bool", function(_, paused)
    if paused == expected_pause then expected_pause = nil return end
    send_state("pause")
end)

mp.observe_property("speed", "number", function(_, speed)
    if expected_speed and math.abs(speed - expected_speed) < 1e-3 then expected_speed = nil return end
    send_state("speed")
end)

mp.register_event("file-loaded", function()
    loading = true
    warned_mismatch = false
    quiet_until = mp.get_time() + 3
    -- A switch we made to follow the friend is not echoed back as a new request.
    local followed = expected_switch ~= nil and expected_switch == mp.get_property_number("playlist-pos")
    expected_switch = nil
    send_hello(not followed)
    refresh_menu()
end)

mp.register_event("playback-restart", function()
    if loading then loading = false return end  -- start of a file, not a user seek
    if mp.get_time() < ignore_restart_until then ignore_restart_until = 0 return end
    send_state("seek")
end)

mp.add_periodic_timer(1, function()
    if status ~= "connected" and status ~= "lost" then return end
    send({ t = "ping", id = mp.get_time() })
    if role == "host" then send_state("tick") end
    if status == "connected" and mp.get_time() - last_rx > 6 then
        set_status("lost")
        osd("Друг не отвечает")
    end
end)

mp.register_event("shutdown", stop)
