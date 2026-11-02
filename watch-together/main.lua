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

local VERSION = "1.4.2"
local PROTOCOL = 2

local o = {
    port = 47800,
    bind = "127.0.0.1",     -- host listens here; Porthole forwards to localhost
    address = "127.0.0.1",  -- where "join" connects; with Porthole the host's port appears locally
    threshold = 0.5,        -- seconds of drift before a correcting seek; less is caught up by speed
    lang = "auto",          -- auto (Windows display language) | ru | en
    control = "all",        -- host default: all | host (only the host controls playback)
    name = "",              -- shown to others; empty means the Steam name, else the Windows user name
    auto_update = true,     -- check GitHub releases at every start and offer a newer one
    max_guests = 50,        -- host: connections beyond this are refused
    wait_for_others = true, -- host: pause the room while someone is buffering or loading a file
    wait_timeout = 30,      -- host: seconds to wait for one member before playing on without them
    countdown = 10,         -- host: seconds of "next episode in ..." after an episode ends; 0 = off
    resume_memory = true,   -- remember episode and time per folder, offer them when hosting again
    share_files = true,     -- host: let guests download episodes from the host's playlist
    share_port = 47801,     -- host: port for those downloads (share it in Porthole next to port)
    download_dir = "",      -- guest: where downloads go; empty = next to the current file, else Downloads
}
options.read_options(o, "watch_together")
local COUNTDOWN_SECONDS = o.countdown > 0 and o.countdown or 10  -- also the length offered when the setting is off

-- Command line for one of our PowerShell helpers next to this script.
local function ps_args(script, ...)
    return { "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
             "-File", utils.join_path(mp.get_script_directory(), script), ... }
end

-- A file in mpv's config folder, or nil when mpv runs without one (--no-config): then "~~/" expands to
-- a bare relative name, and writing it would litter whatever folder mpv was started from.
local function state_file(name)
    local path = mp.command_native({ "expand-path", "~~/" .. name })
    if type(path) == "string" and (path:match("^%a:[\\/]") or path:match("^[\\/]")) then return path end
    return nil
end

-- Toggles from the Settings menu override the conf file and survive restarts.
local SETTINGS_FILE = state_file("watch_together_settings.json")
local settings = {
    wait_for_others = o.wait_for_others,
    countdown = o.countdown > 0,
    resume_memory = o.resume_memory,
    share_files = o.share_files,
    download_to = "video",  -- guest: "video" (the open video's folder) | "downloads"
}
do
    local f = SETTINGS_FILE and io.open(SETTINGS_FILE, "r")
    if f then
        local saved = utils.parse_json(f:read("*a") or "")
        f:close()
        for k, v in pairs(type(saved) == "table" and saved or {}) do
            if type(settings[k]) == type(v) then settings[k] = v end
        end
        if settings.download_to ~= "downloads" then settings.download_to = "video" end
    end
end

local function save_settings()
    local f = SETTINGS_FILE and io.open(SETTINGS_FILE, "w")
    if f then f:write(utils.format_json(settings)) f:close() end
end

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
        control = "Кто управляет просмотром",
        control_all = "Все: любой может ставить паузу, перематывать, менять скорость и серию",
        control_host = "Только я: гости смотрят, управляет хост",
        copy_invite = "Скопировать адрес приглашения",
        invite_copied = "Скопировано: %s\nДрузья выбирают «Подключиться к адресу из буфера обмена»",
        no_address = "Не удалось узнать адрес этого компьютера",
        control_is = "Управляет просмотром: %s",
        control_all_short = "все участники",
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
        host_only = "Управляет только хост. Пауза, перемотка и смена серии у гостей отключены",
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
        waiting = "Ждём: %s",
        reason_buffering = "буферизация",
        reason_loading = "загрузка файла",
        you_word = "тебя",
        all_ready = "Все готовы, продолжаем",
        gave_up = "Не дождались: %s, продолжаем",
        settings = "Настройки комнаты (когда ты хост)",
        set_wait = "Ждать тех, у кого буферизация или загрузка файла",
        set_countdown = "Отсчёт %d с перед следующей серией",
        set_resume = "Предлагать продолжить с места остановки",
        set_share = "Разрешить гостям скачивать у меня серии (порт %d)",
        setting_on = "Включено: %s",
        setting_off = "Выключено: %s",
        countdown = "Следующая серия через %d с\nПробел: подождать",
        countdown_wait = "Отсчёт остановлен (%s). Пробел: начать серию",
        you_self = "ты",
        go = "Поехали!",
        resume_prompt = "Продолжить с %s, %s?",
        download_menu = "Скачать у хоста",
        download_all = "Все недостающие (%d)",
        download_none = "Все серии хоста у тебя уже есть",
        downloading = "Скачивается: %s",
        download_cancel = "Отменить загрузку",
        dl_progress = "Загрузка %s: %d%% (%s из %s)",
        dl_done = "Скачано: %s",
        dl_failed = "Не удалось скачать %s: %s",
        dl_hint = "Проверь, что хост добавил порт %d в лобби Porthole",
        share_sending = "%s скачивает %s",
        mb = "%.0f МБ",
        save_to = "Куда сохранять",
        save_video = "В папку открытого видео",
        save_downloads = "В «Загрузки»",
        save_to_set = "Серии будут сохраняться: %s",
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
        control = "Who controls playback",
        control_all = "Everyone: anyone can pause, seek, change speed or episode",
        control_host = "Only me: guests watch, the host controls",
        copy_invite = "Copy invite address",
        invite_copied = "Copied: %s\nFriends choose Join address from clipboard",
        no_address = "Could not find this PC's address",
        control_is = "Controls playback: %s",
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
        host_only = "Only the host controls playback. Pause, seek and episode changes are off for guests",
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
        waiting = "Waiting for: %s",
        reason_buffering = "buffering",
        reason_loading = "loading the file",
        you_word = "you",
        all_ready = "Everyone is ready, playing on",
        gave_up = "Gave up waiting for %s, playing on",
        settings = "Room settings (when you host)",
        set_wait = "Wait for anyone buffering or loading a file",
        set_countdown = "%d s countdown before the next episode",
        set_resume = "Offer to continue where we stopped",
        set_share = "Let guests download episodes from me (port %d)",
        setting_on = "On: %s",
        setting_off = "Off: %s",
        countdown = "Next episode in %d s\nSpace: wait",
        countdown_wait = "Countdown stopped (%s). Space: start the episode",
        you_self = "you",
        go = "Here we go!",
        resume_prompt = "Continue from %s, %s?",
        download_menu = "Download from host",
        download_all = "All missing (%d)",
        download_none = "You already have all the host's episodes",
        downloading = "Downloading: %s",
        download_cancel = "Cancel download",
        dl_progress = "Downloading %s: %d%% (%s of %s)",
        dl_done = "Downloaded: %s",
        dl_failed = "Could not download %s: %s",
        dl_hint = "Check that the host shared port %d in the Porthole lobby",
        share_sending = "%s is downloading %s",
        mb = "%.0f MB",
        save_to = "Save to",
        save_video = "The open video's folder",
        save_downloads = "Downloads",
        save_to_set = "Episodes will be saved to: %s",
        more = "…and %d more",
    },
}
local lang = "en"  -- until the Windows display language is known
local function T(key, ...) return string.format(STRINGS[lang][key], ...) end
local function control_text(c) return T(c == "host" and "control_host_short" or "control_all_short") end

local my_name = (o.name ~= "" and o.name or os.getenv("USERNAME") or "mpv"):sub(1, 32)
local control = o.control == "host" and "host" or "all"

local role                  -- "host" | "join" | nil
local status = "off"
local helper                -- async subprocess handle of bridge.ps1
local rtt = 0.1             -- guest: round trip to the host, the smallest of the last few
local rtt_samples = {}      -- guest: last round trips; one slow ping must not shift the projected host position
local last_rx = 0           -- guest: last message from the host

-- Changes we make ourselves to follow the room, so the observers don't report them as user actions.
local expected_pause, expected_speed
local nudge = 1             -- guest: speed factor on top of the room speed while catching up a small drift
local NUDGE_MAX = 0.05      -- at most 5 % faster or slower: mpv keeps the pitch, so it is not heard
local NUDGE_DEAD = 0.04     -- drift below this counts as in sync (time-pos moves in whole frames)
local own_seeks = {}        -- {pos, at, playing} of our recent follow seeks; mpv may merge several into one restart
local seek_latency = 0.05   -- smoothed time from our seek command to playback-restart
local expected_switch       -- playlist index we switched to because of the room
local loading = false
local quiet_until = 0       -- no "different file" warning right after an episode change
local warned_mismatch = false
local last_local_action = -10

-- Waiting: this player is buffering or still loading a file, so the room should pause for it.
local my_wait               -- nil | "buffering" | "loading"
local my_wait_since = 0
local buffering_since       -- paused-for-cache seen at this time (debounced)
local loading_since         -- start-file seen, first playback-restart not yet

-- host
local epoch = 0             -- bumped on every discrete change; guests use it to drop stale ticks
local members = {}          -- bridge id -> {name, file, dur, pos, paused, rtt, at, v, wait, wait_since, gave_up}
local switch_by             -- name of the guest whose request made the host switch files
local holding = false       -- the room is paused because someone is waiting
local want_paused = false   -- what the room's users last asked for, applied when the hold ends
local wait_list = {}        -- {name, reason} of the members we are waiting for

-- guest
local host_state            -- last state from the host, plus .received
local room                  -- last room info from the host: {control, members}
local pending               -- {count, at}: our requests the host hasn't answered yet

local update_available      -- release tag newer than VERSION, once checked

-- next-episode countdown
local countdown_end         -- host: mp.get_time() when the next episode starts on its own
local countdown_pending = false  -- host: start the countdown once the new episode has really started
local eof_advance = false   -- the last file ended by itself, so the next one started on its own
local keep_file_until = 0   -- guest: after our own end-of-episode advance, don't follow the host back

-- resume memory
local HISTORY_FILE = state_file("watch_together_history.json")
local history_mem = {}      -- used instead of the file when mpv has no config folder
local pending_resume        -- seek here once the remembered episode has loaded

-- episode downloads
local host_files            -- guest: {names, port} the host offers
local joined_address        -- guest: address the room was joined at; downloads go there too
local dl_queue = {}         -- guest: names waiting to download
local dl_current            -- guest: {name, handle} of the running fetch.ps1
local share_helper          -- host: async handle of share.ps1
local remember, start_share, stop_share, send_files, cancel_downloads, offer_resume  -- defined further down

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
             paused = mp.get_property_native("pause"), host = role == "host", wait = my_wait }
end

-- Peer data: only known reasons become text.
local function reason_text(r)
    return (r == "buffering" or r == "loading") and T("reason_" .. r) or nil
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
        local e = { name = m.name, file = m.file and short(m.file, 80), pos = m.pos, paused = m.paused,
                    stale = now - m.at > 6, wait = m.wait }
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
    if reason_text(m.wait) then parts[#parts + 1] = "[" .. reason_text(m.wait) .. "]" end
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

local function is_url(path) return path:find("^%a[%w+.-]*://") ~= nil end

-- Full path of the current file, or nil for streams.
local function current_path()
    local path = mp.get_property("path")
    if not path or is_url(path) then return nil end
    return utils.join_path(mp.get_property("working-directory") or "", path)
end

-- Windows' real Downloads folder once sysinfo.ps1 has told us; it can be moved off the profile.
local downloads_folder = utils.join_path(os.getenv("USERPROFILE") or "", "Downloads")

-- A download_dir in the conf wins; else the menu choice: next to the open video (so the episodes
-- stay together, Downloads when a stream is open) or always Downloads.
local function download_dir()
    if o.download_dir ~= "" then return mp.command_native({ "expand-path", o.download_dir }) end
    if settings.download_to == "video" then
        local full = current_path()
        local dir = full and utils.split_path(full)
        if dir and dir ~= "" then return dir end
    end
    return downloads_folder
end

-- Names from the host become file names here, so nothing that could leave the folder is accepted.
local function safe_name(name)
    return type(name) == "string" and #name <= 255 and name ~= "." and name ~= ".."
       and name:match('^[^\\/:*?"<>|%c]+$') ~= nil
end

-- Host episodes this guest has neither in the playlist nor in the download folder.
local function missing_files()
    if not host_files then return {} end
    local have = {}
    for _, e in ipairs(mp.get_property_native("playlist") or {}) do have[basename(e.filename)] = true end
    local dir, list = download_dir(), {}
    for _, name in ipairs(host_files.names) do
        if not have[name] and not utils.file_info(utils.join_path(dir, name)) then list[#list + 1] = name end
    end
    return list
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
        items[#items + 1] = { title = T("control_is", control_text(r.control)), state = { "disabled" } }
    end
    if role == "join" and host_files and #host_files.names > 0 then
        local sub = {}
        if dl_current then
            sub[#sub + 1] = { title = T("downloading", menu_name(dl_current.name)), state = { "disabled" } }
            sub[#sub + 1] = { title = T("download_cancel"), cmd = "script-message watch-together-dl-cancel" }
            sub[#sub + 1] = { type = "separator" }
        end
        local missing = missing_files()
        if #missing == 0 then
            sub[#sub + 1] = { title = T("download_none"), state = { "disabled" } }
        else
            sub[#sub + 1] = { title = T("download_all", #missing), cmd = "script-message watch-together-dl-all" }
            sub[#sub + 1] = { type = "separator" }
            -- By position in the host's list: file names can hold characters that break command parsing.
            for i, name in ipairs(host_files.names) do
                for _, m in ipairs(missing) do
                    if m == name and #sub < 40 then
                        sub[#sub + 1] = { title = menu_name(name), cmd = "script-message watch-together-dl " .. i }
                    end
                end
            end
        end
        sub[#sub + 1] = { type = "separator" }
        sub[#sub + 1] = { type = "submenu", title = T("save_to"), submenu = {
            { title = T("save_video"), cmd = "script-message watch-together-download-to video", state = st(false, settings.download_to == "video") },
            { title = T("save_downloads"), cmd = "script-message watch-together-download-to downloads", state = st(false, settings.download_to == "downloads") },
        } }
        items[#items + 1] = { type = "submenu", title = T("download_menu"), submenu = sub }
    end
    items[#items + 1] = { type = "submenu", title = T("settings"), submenu = {
        { title = T("set_wait"), cmd = "script-message watch-together-setting wait_for_others", state = st(false, settings.wait_for_others) },
        { title = T("set_countdown", COUNTDOWN_SECONDS), cmd = "script-message watch-together-setting countdown", state = st(false, settings.countdown) },
        { title = T("set_resume"), cmd = "script-message watch-together-setting resume_memory", state = st(false, settings.resume_memory) },
        { title = T("set_share", o.share_port), cmd = "script-message watch-together-setting share_files", state = st(false, settings.share_files) },
    } }
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

-- mpv knows neither the OS language, the Steam name nor the Downloads folder, so ask Windows once.
if mp.get_property_native("platform") == "windows" then
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
        args = ps_args("sysinfo.ps1"),
    }, function(ok, res)
        local info = ok and res.status == 0 and utils.parse_json(res.stdout or "")
        if type(info) ~= "table" then return end
        if o.name == "" and type(info.steam) == "string" and info.steam ~= "" then
            my_name = short(info.steam, 32)
            mp.set_property("user-data/watch-together/name", my_name)
        end
        if o.lang == "auto" then set_lang(info.lang) end
        if type(info.downloads) == "string" and info.downloads ~= "" then downloads_folder = info.downloads end
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
    -- We just moved on to the next episode by ourselves; the host gets there a moment later.
    if role == "join" and mp.get_time() < keep_file_until then return false end
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
    local cur = mp.get_property_number("time-pos")
    -- A seek while paused is invisible, so line up to about a frame then; while playing every seek
    -- stutters, so only drift over threshold is sought. The paused limit stays above one frame, or a
    -- player with a coarse frame rate would seek again on every tick.
    local fps = mp.get_property_number("container-fps", 25)
    local limit = paused and math.max(0.1, 1.5 / math.max(fps, 1)) or o.threshold
    local drift = cur and target - cur or 0
    -- A guest a little off while playing catches up by playing slightly faster or slower, halving the
    -- drift about every tick. The host is the reference and never nudges.
    nudge = 1
    if role == "join" and not paused and math.abs(drift) > NUDGE_DEAD and math.abs(drift) <= limit then
        nudge = 1 + math.max(-NUDGE_MAX, math.min(NUDGE_MAX, drift / 2))
    end
    if math.abs(speed * nudge - mp.get_property_number("speed", 1)) > 1e-3 then
        expected_speed = speed * nudge
        mp.set_property_number("speed", speed * nudge)
    end
    if cur and math.abs(drift) > limit then
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

-- Back to the plain room speed: on leaving, losing the host, or a user action that ticks won't steer for a while.
local function end_nudge()
    if nudge == 1 then return end
    local speed = mp.get_property_number("speed", 1) / nudge
    nudge = 1
    expected_speed = speed
    mp.set_property_number("speed", speed)
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
             pl = mp.get_property_number("playlist-pos"),
             wait = holding and wait_list or nil,
             countdown = countdown_end and math.max(0, math.ceil(countdown_end - mp.get_time())) or nil }
end

-- A discrete change: new epoch, sent to everyone.
local function broadcast(ev, by, pos, paused, speed)
    epoch = epoch + 1
    local m = host_state_msg(ev, by, pos, paused, speed)
    if m.pos then send("*", m) end
end

-- "Аня (буферизация), тебя (загрузка файла)"; entries come from the host, so they are checked.
local function wait_text(list)
    local parts = {}
    for _, w in ipairs(type(list) == "table" and list or {}) do
        if type(w) == "table" and type(w.name) == "string" and reason_text(w.reason) then
            local who = is_me(w.name) and T("you_word") or short(w.name, 24)
            parts[#parts + 1] = who .. " (" .. reason_text(w.reason) .. ")"
        end
    end
    return table.concat(parts, ", ")
end

-- Who the room waits for now. Silent or outdated members never block it, and nobody blocks it for
-- longer than wait_timeout: after that the room plays on and everyone is told whom it gave up on.
local function waiting_list()
    local now, list = mp.get_time(), {}
    if my_wait and now - my_wait_since <= o.wait_timeout then list[1] = { name = my_name, reason = my_wait } end
    local ids = {}
    for id in pairs(members) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local g = members[id]
        if g.wait and g.v == PROTOCOL and now - g.at <= 6 then
            if now - g.wait_since <= o.wait_timeout then
                list[#list + 1] = { name = g.name, reason = g.wait }
            elseif not g.gave_up then
                g.gave_up = true
                osd(T("gave_up", g.name))
                send("*", { t = "notice", key = "gave_up", name = g.name })
            end
        end
    end
    return list
end

-- Pause the room while someone waits; resume, as the users last wanted, once nobody does.
local function update_hold()
    if role ~= "host" then return end
    local list = (settings.wait_for_others and status == "hosting") and waiting_list() or {}
    wait_list = list
    if #list > 0 and not holding then
        holding = true
        if not mp.get_property_native("pause") then
            want_paused = false
            expected_pause = true
            mp.set_property_native("pause", true)
        end
        broadcast("hold", nil, nil, true)
        osd(T("waiting", wait_text(list)))
    elseif #list == 0 and holding then
        holding = false
        if not want_paused and mp.get_property_native("pause") then
            expected_pause = false
            mp.set_property_native("pause", false)
        end
        broadcast("resume", nil, nil, want_paused)
        osd(T("all_ready"))
    end
end

-- Next episode: everyone starts paused at its beginning and plays together when the count ends.
local function start_countdown()
    countdown_end = mp.get_time() + COUNTDOWN_SECONDS
    want_paused = false
    if not mp.get_property_native("pause") then
        expected_pause = true
        mp.set_property_native("pause", true)
    end
    osd(T("countdown", COUNTDOWN_SECONDS))
end

-- Someone pressed play during the count: that means "wait". The next play starts the episode.
local function stop_countdown(who)
    countdown_end = nil
    want_paused = true
    epoch = epoch + 1
    local m = host_state_msg("wait_req", nil, nil, true)
    m.who = who  -- not "by": the guest who asked must apply this too, its own play is undone
    if m.pos then send("*", m) end
    osd(T("countdown_wait", who))
end

local function finish_countdown()
    countdown_end = nil
    want_paused = false
    if holding then return end  -- the hold ends with resume, as wanted
    expected_pause = false
    mp.set_property_native("pause", false)
    broadcast("go", nil, nil, false)
    osd(T("go"))
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
        send_files(id)
        set_status("hosting")
    elseif m.t == "ping" then
        send(id, { t = "pong", id = m.id })
    elseif m.t == "status" then
        g.file = type(m.file) == "string" and m.file:sub(1, 512) or nil
        g.pos = type(m.pos) == "number" and m.pos or nil
        g.paused = m.paused == true
        g.rtt = type(m.rtt) == "number" and m.rtt or nil
    elseif m.t == "wait" then
        local r = (m.reason == "buffering" or m.reason == "loading") and m.reason or nil
        if r ~= g.wait then g.wait, g.wait_since, g.gave_up = r, mp.get_time(), nil end
        update_hold()
    elseif m.t == "req" then
        if control ~= "all" or not valid_state(m) then
            local s = host_state_msg("sync")  -- puts the guest back
            if s.pos then send(id, s) end
            return
        end
        if m.ev == "pause" then
            if countdown_end and not m.paused then
                stop_countdown(g.name)
                return
            end
            want_paused = m.paused
            if holding and not m.paused then
                send(id, host_state_msg("hold"))  -- back to paused, with whom we are waiting for
                return
            end
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
        -- A seek or speed change sent before this guest saw the hold or the countdown must not start the room.
        if holding or countdown_end then m.paused = true end
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
        if sample >= 0 and sample < 10 then
            rtt_samples[#rtt_samples + 1] = sample
            if #rtt_samples > 10 then table.remove(rtt_samples, 1) end
            rtt = math.min(unpack(rtt_samples))
        end
    elseif m.t == "files" and type(m.names) == "table" then
        local names = {}
        for _, n in ipairs(m.names) do
            if safe_name(n) and #names < 500 then names[#names + 1] = n end
        end
        local port = tonumber(m.port)
        host_files = (port and port >= 1 and port <= 65535) and { names = names, port = port } or nil
        refresh_menu()
    elseif m.t == "notice" and type(m.name) == "string" then
        if m.key == "joined" then osd(T("joined", m.name))
        elseif m.key == "left" then osd(T("member_left", m.name))
        elseif m.key == "gave_up" then osd(T("gave_up", is_me(m.name) and T("you_word") or m.name))
        end
    elseif m.t == "room" and type(m.members) == "table" then
        local before = room and room.control
        -- Host data ends up in labels and the menu: keep only fields of the expected types.
        local list = {}
        local function num(v) return type(v) == "number" and v or nil end
        for _, e in ipairs(m.members) do
            if type(e) == "table" and type(e.name) == "string" and #list < 500 then
                list[#list + 1] = { name = e.name, file = type(e.file) == "string" and e.file or nil,
                                    pos = num(e.pos), off = num(e.off), paused = e.paused == true,
                                    host = e.host == true, stale = e.stale == true,
                                    wait = type(e.wait) == "string" and e.wait or nil }
            end
        end
        room = { control = m.control == "host" and "host" or "all", members = list }
        if before and before ~= room.control then
            osd(T("control_is", control_text(room.control)))
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
            if m.ev == "hold" then osd(T("waiting", wait_text(m.wait)))
            elseif m.ev == "resume" then osd(T("all_ready"))
            elseif m.ev == "go" then osd(T("go"))
            elseif m.ev == "wait_req" and type(m.who) == "string" then
                osd(T("countdown_wait", is_me(m.who) and T("you_self") or short(m.who, 24)))
            elseif m.ev == "sync" then osd(T("synced"))
            elseif type(m.countdown) == "number" then osd(T("countdown", m.countdown))
            else notify(m.ev, m.by, m) end
            return
        end
        -- Keep "waiting for ..." and the countdown on screen while they last.
        if m.wait and wait_text(m.wait) ~= "" then osd(T("waiting", wait_text(m.wait)))
        elseif type(m.countdown) == "number" and m.countdown > 0 then osd(T("countdown", m.countdown)) end
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
                speed = mp.get_property_number("speed", 1) / nudge, dur = mp.get_property_number("duration"),
                file = mp.get_property("filename"), pl = mp.get_property_number("playlist-pos") }
    return m.pos and m
end

-- The user paused, seeked, changed speed or opened another file.
local function local_action(ev)
    last_local_action = mp.get_time()
    mp.msg.debug("local action " .. ev .. " at " .. tostring(mp.get_property_number("time-pos")))
    if role == "host" then
        if ev == "pause" and countdown_end and not mp.get_property_native("pause") then
            expected_pause = true
            mp.set_property_native("pause", true)
            stop_countdown(my_name)
            return
        end
        if ev == "pause" then
            want_paused = mp.get_property_native("pause")
            if holding and not want_paused then  -- play pressed while the room waits: remembered, not done
                expected_pause = true
                mp.set_property_native("pause", true)
                osd(T("waiting", wait_text(wait_list)))
                return
            end
        end
        if status == "hosting" or status == "listening" then broadcast(ev, my_name) end
    elseif role == "join" and (status == "connected" or status == "lost") then
        end_nudge()
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

-- After buffering, wait until the cache can really keep up, or we would stall again at once.
local function cache_ready()
    if not mp.get_property_native("demuxer-via-network") then return true end
    if mp.get_property_native("demuxer-cache-idle") or mp.get_property_native("eof-reached") then return true end
    return (mp.get_property_number("demuxer-cache-duration") or 0) >= 2
end

-- Short stalls (under 0.5 s buffering, 0.7 s loading) are not worth pausing everyone for.
local function current_wait(now)
    if loading_since and now - loading_since > 0.7 then return "loading" end
    if mp.get_property_native("paused-for-cache") then
        buffering_since = buffering_since or now
    elseif buffering_since and (my_wait ~= "buffering" or cache_ready()) then
        buffering_since = nil
    end
    if buffering_since and now - buffering_since > 0.5 then return "buffering" end
    return nil
end

local function report_wait()
    if role == "host" then update_hold()
    elseif role == "join" and (status == "connected" or status == "lost") then
        send("host", { t = "wait", reason = my_wait or "" })
    end
end

mp.add_periodic_timer(0.25, function()
    local now = mp.get_time()
    local w = current_wait(now)
    if w == my_wait then return end
    my_wait, my_wait_since = w, now
    report_wait()
end)

------------------------------------------------------------------ bridge process

local function stop()
    if helper then
        local h = helper
        helper = nil
        mp.abort_async_command(h)
    end
    end_nudge()
    rtt_samples = {}
    remember()
    stop_share()
    cancel_downloads()
    role, members, room, host_state, pending, switch_by, room_name = nil, {}, nil, nil, nil, nil, nil
    holding, wait_list, countdown_end, countdown_pending, host_files = false, {}, nil, false, nil
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
    local args = ps_args("bridge.ps1",
        "-Pipe", ipc_pipe_name(), "-Mode", mode, "-Script", mp.get_script_name(),
        "-Address", address, "-Port", tostring(port), "-Bind", o.bind, "-MaxPeers", tostring(o.max_guests))
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
    joined_address = mode == "join" and address or nil
    want_paused = mp.get_property_native("pause") == true
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
            if my_wait then report_wait() end
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
            update_hold()  -- the member we were waiting for may have gone
        else
            host_state, room, pending = nil, nil, nil
            end_nudge()
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
    if not start("host", o.bind, o.port) then return end
    osd(T("hosted", o.port))
    start_share()
    offer_resume()
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
    osd(T("control_is", control_text(control)))
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
        args = ps_args("sysinfo.ps1", "-Addresses"),
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

------------------------------------------------------------------ resume memory

-- Per folder of episodes: which file and where we were, while watching in a room.
local function history_key()
    local full = current_path()
    local dir = full and utils.split_path(full)
    return dir and dir:lower()
end

local function load_history()
    if not HISTORY_FILE then return history_mem end
    local f = io.open(HISTORY_FILE, "r")
    if not f then return {} end
    local h = utils.parse_json(f:read("*a") or "")
    f:close()
    return type(h) == "table" and h or {}
end

function remember()
    if not settings.resume_memory or not role then return end
    local key, pos, name = history_key(), mp.get_property_number("time-pos"), mp.get_property("filename")
    if not key or not pos or not name then return end
    local h = load_history()
    h[key] = { file = name, pos = pos, t = os.time() }
    -- Keep the 50 most recent folders.
    local keys = {}
    for k, v in pairs(h) do if type(v) == "table" and type(v.t) == "number" then keys[#keys + 1] = k else h[k] = nil end end
    table.sort(keys, function(x, y) return h[x].t > h[y].t end)
    for i = 51, #keys do h[keys[i]] = nil end
    if not HISTORY_FILE then history_mem = h return end
    local f = io.open(HISTORY_FILE, "w")
    if f then f:write(utils.format_json(h)) f:close() end
end

local function resume_to(e)
    if e.file == mp.get_property("filename") then
        mp.commandv("seek", e.pos, "absolute+exact")
        return
    end
    for i, entry in ipairs(mp.get_property_native("playlist") or {}) do
        if basename(entry.filename) == e.file then
            pending_resume = e.pos  -- the seek happens once the file has loaded
            mp.commandv("playlist-play-index", i - 1)
            return
        end
    end
end

-- When the host opens a room in a folder watched before, offer the remembered episode and time.
function offer_resume()
    if not settings.resume_memory then return end
    local key = history_key()
    local e = key and load_history()[key]
    if type(e) ~= "table" or type(e.file) ~= "string" or type(e.pos) ~= "number" then return end
    if e.file == mp.get_property("filename") and math.abs(e.pos - (mp.get_property_number("time-pos") or 0)) < 30 then return end
    local ok, input = pcall(require, "mp.input")
    if not ok then return end
    input.select({
        prompt = T("resume_prompt", e.file, fmt_time(e.pos)),
        items = { T("yes"), T("no") },
        default_item = 1,
        submit = function(i) if i == 1 then resume_to(e) end end,
    })
end

------------------------------------------------------------------ episode sharing

local function host_file_names()
    local names = {}
    if not settings.share_files then return names end
    for _, e in ipairs(mp.get_property_native("playlist") or {}) do
        if not is_url(e.filename) and #names < 500 then names[#names + 1] = basename(e.filename) end
    end
    return names
end

function send_files(target)
    if role == "host" then send(target, { t = "files", names = host_file_names(), port = o.share_port }) end
end

-- share.ps1 serves only files from this mpv's current playlist, by exact name.
function start_share()
    if share_helper or role ~= "host" or not settings.share_files then return end
    local h
    h = mp.command_native_async({ name = "subprocess", playback_only = false, capture_stderr = true,
        args = ps_args("share.ps1", "-Pipe", ipc_pipe_name(), "-Script", mp.get_script_name(),
                       "-Bind", o.bind, "-Port", tostring(o.share_port)),
    }, function(_, res)
        if share_helper ~= h then return end
        share_helper = nil
        mp.msg.warn("share.ps1 exited: " .. utils.format_json(res))
    end)
    share_helper = h
end

function stop_share()
    if not share_helper then return end
    local h = share_helper
    share_helper = nil
    mp.abort_async_command(h)
end

-- Guests' download menus follow the host's playlist.
mp.observe_property("playlist-count", "number", function() if role == "host" then send_files("*") end end)

mp.register_script_message("watch-together-share", function(kind, a, b)
    if kind == "sending" and type(a) == "string" and type(b) == "string" then
        osd(T("share_sending", short(a, 24), short(b, 60)))
    elseif kind == "error" then
        osd(T("error", tostring(a)))
    end
end)

------------------------------------------------------------------ episode downloads

local function mb(bytes) return T("mb", (tonumber(bytes) or 0) / 1048576) end

local function next_download()
    if dl_current then return end
    if #dl_queue == 0 or role ~= "join" or not host_files or not joined_address then
        dl_queue = {}
        refresh_menu()
        return
    end
    local name = table.remove(dl_queue, 1)
    local h
    h = mp.command_native_async({ name = "subprocess", playback_only = false, capture_stderr = true,
        args = ps_args("fetch.ps1", "-Pipe", ipc_pipe_name(), "-Script", mp.get_script_name(), "-Address", joined_address,
                       "-Port", tostring(host_files.port), "-Name", name, "-Dir", download_dir(), "-Who", room_name or my_name),
    }, function()
        if dl_current and dl_current.handle == h then
            dl_current = nil
            next_download()
        end
    end)
    dl_current = { name = name, handle = h }
    osd(T("downloading", name))
    refresh_menu()
end

local function queue_download(name)
    if not safe_name(name) or (dl_current and dl_current.name == name) then return end
    for _, q in ipairs(dl_queue) do if q == name then return end end
    dl_queue[#dl_queue + 1] = name
    next_download()
end

function cancel_downloads()
    dl_queue = {}
    if dl_current then
        local h = dl_current.handle
        dl_current = nil  -- the .part file stays, the next download of it continues from there
        mp.abort_async_command(h)
    end
end

mp.register_script_message("watch-together-dl", function(i)
    local name = host_files and host_files.names[tonumber(i) or 0]
    if name then queue_download(name) end
end)
mp.register_script_message("watch-together-dl-all", function()
    for _, name in ipairs(missing_files()) do queue_download(name) end
end)
mp.register_script_message("watch-together-dl-cancel", function()
    cancel_downloads()
    refresh_menu()
end)

-- From fetch.ps1: progress <name> <bytes> <total> | done <name> <path> | error <name> <text>
mp.register_script_message("watch-together-dl-event", function(kind, name, a, b)
    if not dl_current or name ~= dl_current.name then return end
    if kind == "progress" then
        local done, total = tonumber(a) or 0, tonumber(b) or 0
        if total > 0 then mp.osd_message(T("dl_progress", name, math.floor(done * 100 / total), mb(done), mb(total)), 2) end
    elseif kind == "done" and type(a) == "string" then
        osd(T("dl_done", name))
        mp.commandv("loadfile", a, "append")
        -- The room may be on this episode already.
        if host_state and host_state.file == name then mp.add_timeout(0.5, apply_host_state) end
    elseif kind == "error" then
        osd(T("dl_failed", name, tostring(a)) .. "\n" .. T("dl_hint", host_files and host_files.port or o.share_port))
    end
end)

------------------------------------------------------------------ settings

local SETTING_LABELS = { wait_for_others = "set_wait", countdown = "set_countdown",
                         resume_memory = "set_resume", share_files = "set_share" }

local function toggle_setting(key)
    if type(settings[key]) ~= "boolean" or not SETTING_LABELS[key] then return end
    settings[key] = not settings[key]
    save_settings()
    local arg = key == "countdown" and COUNTDOWN_SECONDS or o.share_port
    osd(T(settings[key] and "setting_on" or "setting_off", T(SETTING_LABELS[key], arg)))
    if key == "wait_for_others" then update_hold() end
    if key == "countdown" and not settings.countdown and countdown_end then finish_countdown() end
    if key == "share_files" then
        if settings.share_files then start_share() else stop_share() end
        send_files("*")
    end
    refresh_menu()
end

mp.register_script_message("watch-together-setting", toggle_setting)
mp.register_script_message("watch-together-download-to", function(where)
    if where ~= "video" and where ~= "downloads" then return end
    settings.download_to = where
    save_settings()
    osd(T("save_to_set", download_dir()))
    refresh_menu()
end)

------------------------------------------------------------------ auto-update

-- update.ps1 prints one line: "available <tag>", "latest", "updated <tag>" or "error <text>".
local function run_updater(extra, cb)
    if mp.get_property_native("platform") ~= "windows" then return end
    local args = ps_args("update.ps1", "-Dir", mp.get_script_directory(), "-Current", VERSION)
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
    if nudge ~= 1 then
        -- The user changed speed while we were catching up: keep their change, drop ours.
        -- "[" and "]" multiply the nudged speed; Backspace sets exactly 1.
        local wanted = speed == 1 and 1 or speed / nudge
        nudge = 1
        if wanted ~= speed then
            expected_speed = wanted
            mp.set_property_number("speed", wanted)
        end
    end
    local_action("speed")
end)

mp.register_event("file-loaded", function()
    loading = true
    warned_mismatch = false
    quiet_until = mp.get_time() + 3
    local followed = expected_switch ~= nil and expected_switch == mp.get_property_number("playlist-pos")
    expected_switch = nil
    -- Opening is done. Whatever delays the first frame now is buffering (seen separately) or a pause:
    -- after a gapless episode change mpv plays out the old audio first, which never ends while paused.
    loading_since = nil
    local ended_by_itself = eof_advance
    eof_advance = false
    if pending_resume then
        mp.commandv("seek", pending_resume, "absolute+exact")
        pending_resume = nil
    end
    if role == "host" then
        local by = switch_by or my_name
        switch_by = nil
        -- Pausing right here would stall that old-audio play-out, so the count starts at playback-restart.
        countdown_pending = ended_by_itself and settings.countdown and status == "hosting"
        if status == "hosting" or status == "listening" then broadcast("file", by) end
        send_files("*")
    elseif role == "join" then
        if followed then apply_host_state()
        elseif ended_by_itself then keep_file_until = mp.get_time() + 3  -- the host moves on in a moment
        else local_action("file") end
    end
    refresh_menu()
end)

mp.register_event("start-file", function() loading_since = mp.get_time() end)
mp.register_event("end-file", function(e)
    loading_since = nil  -- also when a file fails to open
    eof_advance = e.reason == "eof"
end)

mp.register_event("playback-restart", function()
    loading_since = nil
    if loading then  -- start of a file, not a user seek
        loading = false
        if countdown_pending then
            countdown_pending = false
            if role == "host" and status == "hosting" then
                start_countdown()
                broadcast("countdown", nil, nil, true)
            end
        end
        return
    end
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

local remember_tick = 0
mp.add_periodic_timer(1, function()
    remember_tick = remember_tick + 1
    if remember_tick % 10 == 0 then remember() end
    if role == "host" and countdown_end then
        local left = math.ceil(countdown_end - mp.get_time())
        if status ~= "hosting" or left <= 0 then finish_countdown()
        elseif not holding then osd(T("countdown", left)) end
    end
    if role == "host" and status == "hosting" then
        update_hold()  -- timeouts and members that went silent
        if holding then osd(T("waiting", wait_text(wait_list))) end
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
            end_nudge()
            set_status("lost")
            osd(T("lost"))
        end
    end
    update_panel()
end)

mp.register_event("shutdown", stop)
publish()
