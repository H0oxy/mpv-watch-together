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

local VERSION = "1.7.1"
local PROTOCOL = 2

-- The torrent engine (TorrServer, GPL-3.0) is downloaded on first use of a magnet or .torrent, never
-- shipped. Only a file with this hash runs; a new engine version comes with a plugin release.
-- MatriX, not the newer Silo line: Silo takes only a YAML config (-c) and has no -p/-i/-d (see bugs.md).
local ENGINE = {
    url = "https://github.com/YouROK/TorrServer/releases/download/MatriX.150/TorrServer-windows-amd64.exe",
    sha256 = "3a96b97a24d86a90c0712a6ec47d4ed52edc7eabac1bce6a0d9bbc8fd30de5bb",
}

local o = {
    port = 47800,
    bind = "127.0.0.1",     -- host listens here; Porthole forwards to localhost
    address = "127.0.0.1",  -- where "join" connects; with Porthole the host's port appears locally
    threshold = 0.5,        -- seconds of drift before a correcting seek; less is caught up by speed
    soft_sync = true,       -- guest: catch up small drift by playing up to 5 % faster or slower; no = seek over 0.3 s
    lang = "auto",          -- auto (Windows display language) | ru | en
    control = "all",        -- host default: all | host (only the host controls playback)
    name = "",              -- shown to others; empty means the Steam name, else the Windows user name
    auto_update = true,     -- check GitHub releases at every start and offer a newer one
    max_guests = 50,        -- host: connections beyond this are refused
    wait_for_others = true, -- host: pause the room while someone is buffering or loading a file
    wait_timeout = 30,      -- host: seconds to wait for one member before playing on without them
    countdown = 0,          -- host: seconds of "next episode in ..." after an episode ends; 0 = off (the next starts
                            -- at once; the menu can turn a 10 s count on)
    resume_memory = true,   -- remember episode and time per folder, offer them when hosting again
    share_files = true,     -- host: let guests download episodes from the host's playlist
    share_port = 47801,     -- host: port for those downloads (share it in Porthole next to port)
    download_dir = "",      -- guest: where downloads go; empty = next to the current file, else Downloads
    stream_cache = 1536,    -- MB of mpv's buffer for a stream (torrent or host), 3/4 ahead, 1/4 behind; 0 = mpv's own.
                            -- The menu choice (Settings) overrides it.
    ram_guard = true,       -- shrink that buffer while free RAM runs low
    torrent_port = 0,       -- local port of the torrent engine (127.0.0.1 only); 0 = a free one at each start
    torrent_cache = 256,    -- MB of RAM the torrent engine keeps; nothing is written to disk
    torrent_url = "",       -- a TorrServer that already runs, e.g. http://127.0.0.1:8090; empty = the plugin's own
    torrent_check = 20,     -- seconds of swarm-speed check when an episode is picked from a torrent; 0 = off
    torrent_preload = 120,  -- seconds before a torrent episode ends to fetch the start of the next one; 0 = off
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

-- Through a .tmp file: mpv killed in the middle of a write must not leave an empty file behind.
-- Windows' rename does not replace, so the old file goes first; reading falls back to the .tmp.
local function write_state(path, text)
    local f = io.open(path .. ".tmp", "w")
    if not f then return end
    f:write(text)
    f:close()
    os.remove(path)
    os.rename(path .. ".tmp", path)
end

local function read_state(path)
    local f = io.open(path, "r") or io.open(path .. ".tmp", "r")
    if not f then return nil end
    local data = utils.parse_json(f:read("*a") or "")
    f:close()
    return type(data) == "table" and data or nil
end

-- Toggles from the Settings menu override the conf file and survive restarts.
local SETTINGS_FILE = state_file("watch_together_settings.json")
local settings = {
    wait_for_others = o.wait_for_others,
    countdown_on = o.countdown > 0,  -- a new name: the old "countdown" was saved as on by everyone, now the default is off
    resume_memory = o.resume_memory,
    share_files = o.share_files,
    soft_sync = o.soft_sync,
    buffer_mb = o.stream_cache,  -- mpv's buffer for streams, chosen in the menu
    ram_guard = o.ram_guard,
    download_to = "video",  -- guest: "video" (the open video's folder) | "downloads"
    cid = "",               -- this player's id in rooms: a guest who comes back replaces its old connection
}
for k, v in pairs(SETTINGS_FILE and read_state(SETTINGS_FILE) or {}) do
    if type(settings[k]) == type(v) then settings[k] = v end
end
if settings.download_to ~= "downloads" then settings.download_to = "video" end
settings.buffer_mb = math.max(0, math.min(16384, math.floor(settings.buffer_mb)))

local function save_settings()
    if SETTINGS_FILE then write_state(SETTINGS_FILE, utils.format_json(settings)) end
end

-- Without a config folder (tests) every player gets a new id, so several on one PC stay apart.
if not settings.cid:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
    -- Kept under 2^31: Lua 5.1 turns the seed into a C int.
    math.randomseed((os.time() + (mp.get_property_number("pid") or 0) * 7919 + math.floor(mp.get_time() * 1e6)) % 2147483647)
    settings.cid = string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
    save_settings()
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
        members = "Участники",
        host_tag = "хост",
        stale_tag = "не отвечает",
        paused_tag = "пауза",
        show_times = "Время друзей на экране",
        control = "Настройки комнаты",
        control_all = "Управляют все",
        control_host = "Управляет только хост",
        copy_invite = "Скопировать приглашение",
        invite_copied = "Скопировано: %s\nДрузья выбирают «Подключиться по скопированному адресу»",
        no_address = "Не удалось узнать адрес этого компьютера",
        control_is = "Управляет просмотром: %s",
        control_all_short = "все участники",
        control_host_short = "только хост",
        host = "Создать комнату",
        join = "Подключиться к другу",
        join_clipboard = "Подключиться по скопированному адресу",
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
        settings = "Настройки",
        set_soft = "Плавная подгонка",
        when_host = "Хост:",
        set_wait = "Ждать загрузку гостей",
        set_countdown = "Перед следующей серией ждать %d с",
        set_resume = "Предлагать продолжить просмотр",
        set_share = "Раздавать серии гостям",
        setting_on = "Включено: %s",
        setting_off = "Выключено: %s",
        countdown = "Следующая серия через %d с\nПробел: подождать",
        countdown_wait = "Отсчёт остановлен (%s). Пробел: начать серию",
        you_self = "ты",
        go = "Поехали!",
        resume_prompt = "Продолжить с %s, %s?",
        download_menu = "Скачать серии",
        download_all = "Все недостающие",
        download_none = "Все серии хоста у тебя уже есть",
        downloading = "Скачивается: %s",
        download_cancel = "Отменить загрузку",
        dl_progress = "Загрузка %s: %d%% (%s из %s)",
        dl_done = "Скачано: %s",
        dl_failed = "Не удалось скачать %s: %s",
        dl_hint = "Проверь, что хост добавил порт %d в лобби Porthole",
        share_sending = "%s скачивает %s",
        share_watching = "%s смотрит у тебя %s",
        stream_menu = "Смотреть онлайн",
        stream_on = "Серии хоста, которых у тебя нет, добавлены в плейлист и будут играть с хоста",
        stream_off = "Просмотр с хоста выключен",
        stream_failed = "Просмотр с хоста: %s",
        mb = "%.0f МБ",
        save_to = "Куда сохранять",
        save_video = "Рядом с этим видео",
        save_downloads = "В папку «Загрузки»",
        save_to_set = "Серии будут сохраняться: %s",
        more = "…и ещё %d",
        buffer_menu = "Буфер онлайн-просмотра: %s",
        buffer_now = "(сейчас %s, мало памяти)",
        buffer_set = "Буфер онлайн-просмотра: %s",
        buffer_guard = "Уменьшать, если мало памяти",
        buffer_reduced = "Мало свободной памяти: буфер уменьшен до %s",
        buffer_restored = "Память освободилась: буфер снова %s",
        gb = "%s ГБ",
        open_torrent = "Открыть торрент из буфера обмена",
        bad_torrent_clipboard = "В буфере обмена нет magnet-ссылки или пути к .torrent",
        torrent_opening = "Торрент: получаю список файлов…",
        torrent_choose = "С какой серии начать?",
        torrent_back = "..  Назад",
        torrent_resuming = "Продолжаю: %s с %s",
        torrent_empty = "В торренте нет файлов",
        torrent_failed = "Торрент: %s",
        torrent_room = "Комната смотрит торрент, подключаюсь к раздаче…",
        torrent_ready = "Серии торрента добавлены в плейлист",
        engine_progress = "Загрузка торрент-движка: %d%% (%s из %s)",
        engine_died = "торрент-движок остановился",
        old_torrent = "У участника %s старая версия плагина: торрент он не увидит",
        check_menu = "Проверить раздачу",
        check_title = "Проверка раздачи: ещё %d с. Пробел — начать",
        check_done = "Проверка раздачи готова. Пробел — начать",
        check_line = "%s %s — %.1f из ~%.1f Мбит/с, пиров %d",
        check_measuring = "… %s — меряем",
        check_local = "✓ %s — свой файл",
        check_buffered = "✓ %s — в запасе %d с видео",
        check_away = "… %s — ещё не на этой серии",
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
        members = "Members",
        host_tag = "host",
        stale_tag = "not responding",
        paused_tag = "paused",
        show_times = "Friends' time on screen",
        control = "Room settings",
        control_all = "Everyone controls",
        control_host = "Only the host controls",
        copy_invite = "Copy invite",
        invite_copied = "Copied: %s\nFriends choose Join by copied address",
        no_address = "Could not find this PC's address",
        control_is = "Controls playback: %s",
        control_all_short = "everyone",
        control_host_short = "host only",
        host = "Create room",
        join = "Join a friend",
        join_clipboard = "Join by copied address",
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
        settings = "Settings",
        set_soft = "Smooth catch-up",
        when_host = "Host:",
        set_wait = "Wait for guests to load",
        set_countdown = "Wait %d s before the next episode",
        set_resume = "Offer to continue watching",
        set_share = "Share episodes with guests",
        setting_on = "On: %s",
        setting_off = "Off: %s",
        countdown = "Next episode in %d s\nSpace: wait",
        countdown_wait = "Countdown stopped (%s). Space: start the episode",
        you_self = "you",
        go = "Here we go!",
        resume_prompt = "Continue from %s, %s?",
        download_menu = "Download episodes",
        download_all = "All missing",
        download_none = "You already have all the host's episodes",
        downloading = "Downloading: %s",
        download_cancel = "Cancel download",
        dl_progress = "Downloading %s: %d%% (%s of %s)",
        dl_done = "Downloaded: %s",
        dl_failed = "Could not download %s: %s",
        dl_hint = "Check that the host shared port %d in the Porthole lobby",
        share_sending = "%s is downloading %s",
        share_watching = "%s is watching %s from you",
        stream_menu = "Watch online",
        stream_on = "Host episodes you lack are in the playlist and play from the host",
        stream_off = "Watching from host is off",
        stream_failed = "Watching from host: %s",
        mb = "%.0f MB",
        save_to = "Where to save",
        save_video = "Next to this video",
        save_downloads = "Downloads folder",
        save_to_set = "Episodes will be saved to: %s",
        more = "…and %d more",
        buffer_menu = "Online buffer: %s",
        buffer_now = "(now %s, low memory)",
        buffer_set = "Online buffer: %s",
        buffer_guard = "Shrink when memory is low",
        buffer_reduced = "Low on free memory: buffer cut to %s",
        buffer_restored = "Memory is free again: buffer back to %s",
        gb = "%s GB",
        open_torrent = "Open torrent from clipboard",
        bad_torrent_clipboard = "No magnet link or .torrent path in the clipboard",
        torrent_opening = "Torrent: getting the file list…",
        torrent_choose = "Start from which episode?",
        torrent_back = "..  Back",
        torrent_resuming = "Resuming %s at %s",
        torrent_empty = "The torrent has no files",
        torrent_failed = "Torrent: %s",
        torrent_room = "The room watches a torrent, joining the swarm…",
        torrent_ready = "The torrent's episodes are in the playlist",
        engine_progress = "Downloading the torrent engine: %d%% (%s of %s)",
        engine_died = "the torrent engine stopped",
        old_torrent = "%s has an old plugin version and won't see the torrent",
        check_menu = "Check the torrent",
        check_title = "Checking the swarm: %d s left. Space: start",
        check_done = "Swarm check done. Space: start",
        check_line = "%s %s — %.1f of ~%.1f Mbit/s, %d peers",
        check_measuring = "… %s — measuring",
        check_local = "✓ %s — own file",
        check_buffered = "✓ %s — %d s of video buffered",
        check_away = "… %s — not on this episode yet",
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
local members = {}          -- bridge id -> {name, file, dur, pos, pos_at, paused, rtt, at, v, wait, wait_since, gave_up}
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
local dl_finished           -- guest: name of the last download whose process has exited
local share_helper          -- host: async handle of share.ps1
local streaming = false     -- guest: host episodes this guest lacks play from the host through stream.ps1
local stream_helper         -- guest: async handle of stream.ps1
local stream_port           -- guest: its local HTTP port, once it is ready
local remember, start_share, stop_share, send_files, cancel_downloads, offer_resume  -- defined further down
local add_streams, stop_stream

-- torrents: every player streams from its own engine, the host only tells guests which torrent
-- Our engine's address comes from torrent.ps1 once it runs (a free port by default); torrent_url is the user's.
local engine_base = o.torrent_url ~= "" and (o.torrent_url:gsub("/+$", "")) or nil
-- hash -> {hash, magnet, tfile, files = {{i, name, path, length}}, extras = {video i -> tracks}, fonts_dir}
local torrents = {}
local room_torrent          -- guest: {hash} the host's room watches
local sent_torrent          -- host: hash last told to the guests ("" = none)
local check                 -- this player's swarm-speed measurement: {hash, length, started, ends, sum, n, peers}
local check_wanted = false  -- guest: the host runs a check, measure as soon as we are on the episode
local check_room            -- guest: {left} of the host's check, from the room info
local last_missing          -- guest: the room's file last logged as missing here
local send_torrent, on_room_torrent, drop_room_torrent, start_check, stop_check, check_result  -- defined further down
local preload_next          -- defined in the torrent section; the 1 s timer calls it
local report_wait           -- defined with the waiting code; the host's first answer calls it

local show_panel = false
local PANEL_LINES = 20
local panel = mp.create_osd_overlay("ass-events")

local function osd(text) mp.osd_message(text, 3) end

-- Torrent mode depends on a swarm and an engine we can't see from here, so it keeps its own log next to the
-- settings (also mpv's log at info). A new one starts past 1 MB; the previous one stays as .old.
local TORRENT_LOG = state_file("watch_together_torrent.log")
if TORRENT_LOG then
    local f = io.open(TORRENT_LOG, "r")
    if f then
        local size = f:seek("end")
        f:close()
        if size and size > 1048576 then
            os.remove(TORRENT_LOG .. ".old")
            os.rename(TORRENT_LOG, TORRENT_LOG .. ".old")
        end
    end
end

local function tlog(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    local line = os.date("%Y-%m-%d %H:%M:%S ") .. (ok and text or fmt)
    mp.msg.info(line)
    local f = TORRENT_LOG and io.open(TORRENT_LOG, "a")
    if f then
        f:write(line, "\n")
        f:close()
    end
end

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

local function is_url(path) return path:find("^%a[%w+.-]*://") ~= nil end

-- A stream from the host (stream.ps1) or the torrent engine carries the file name percent-encoded at the
-- end of its URL path; the engine's query (?link=...) is not part of the name.
local function basename(path)
    local url = is_url(path)
    if url then path = path:gsub("[?#].*$", "") end
    local name = path:match("[^/\\]+$") or path
    if url then name = name:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end) end
    return name
end

-- The current file's name as the room knows it. mpv's "filename" keeps the query of a torrent stream.
local function media_name()
    local path = mp.get_property("path")
    return path and basename(path) or nil
end

local function pct(s) return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end

local function engine_url(hash, f)
    return engine_base .. "/stream/" .. pct(f.name) .. "?link=" .. hash .. "&index=" .. f.i .. "&play"
end

-- Hash and file index of a torrent stream from our engine, else nil. Any local port counts: an entry made
-- before our engine moved to another port is still a torrent stream.
local function engine_hash(path)
    if type(path) ~= "string" then return nil end
    if o.torrent_url ~= "" then
        if path:sub(1, #engine_base + 8) ~= engine_base .. "/stream/" then return nil end
    elseif not path:match("^http://127%.0%.0%.1:%d+/stream/") then
        return nil
    end
    local hash = path:match("[?&]link=(%x+)")
    return hash and #hash == 40 and hash:lower() or nil, tonumber(path:match("[?&]index=(%d+)"))
end

local function in_room() return status == "connected" or status == "lost" or status == "hosting" end

------------------------------------------------------------------ room info

local function local_member()
    return { name = my_name, file = media_name(), pos = mp.get_property_number("time-pos"),
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
    me.check = check and check_result() or nil
    local list = { me }
    local speed = mp.get_property_number("speed", 1)
    local ids = {}
    for id in pairs(members) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local m = members[id]
        -- Every guest gets the whole list each second, so keep entries small.
        local e = { name = m.name, file = m.file and short(m.file, 80), paused = m.paused,
                    stale = now - m.at > 6, wait = m.wait, check = check and m.check or nil }
        if m.pos then
            -- Moved on to now: the guest reported up to a second ago, and the panel shows its time
            -- next to the host's own time-pos read just above.
            e.pos = m.pos + (m.paused and 0 or (now - m.pos_at + (m.rtt or 0) / 2) * speed)
            if me.pos and m.file == me.file then e.off = e.pos - me.pos end
        end
        list[#list + 1] = e
    end
    local c = check and { left = math.max(0, math.ceil(check.ends - now)) } or nil
    return { t = "room", control = control, members = list, check = c }
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

local CHECK_BUFFER_OK = 60  -- seconds of video already buffered that count as "fine" without a speed

-- One member's swarm check: can its download keep up with the episode's bitrate (with a 1.5x margin)?
local function check_label(name, c)
    if type(c) ~= "table" then return nil end
    if c["local"] then return T("check_local", short(name, 20)) end
    if c.away then return T("check_away", short(name, 20)) end
    -- No download while the player already holds a minute: the engine has nothing to fetch, not a slow swarm.
    if (c.speed or 0) == 0 and (c.buf or 0) >= CHECK_BUFFER_OK then return T("check_buffered", short(name, 20), math.floor(c.buf)) end
    if not c.need or not c.speed then return T("check_measuring", short(name, 20)) end
    local ratio = c.speed / c.need
    local mark = ratio >= 1.5 and "✓" or ratio >= 1 and "⚠" or "✗"
    return T("check_line", mark, short(name, 20), c.speed / 1e6, c.need / 1e6, math.floor(c.peers or 0))
end

-- The running check as panel lines, or nil. The host's room info carries everyone's results.
local function check_lines()
    local left, list
    if role == "join" then
        if not check_room then return nil end
        left, list = check_room.left, room and room.members or {}
    else
        if not check then return nil end
        left = math.max(0, math.ceil(check.ends - mp.get_time()))
        list = role == "host" and room_info().members or { { name = my_name, check = check_result() } }
    end
    local lines = { left > 0 and T("check_title", left) or T("check_done") }
    for i = 1, math.min(#list, PANEL_LINES) do lines[#lines + 1] = check_label(list[i].name, list[i].check) end
    return lines
end

local function update_panel()
    local r = current_room()
    local lines = {}
    for _, l in ipairs(check_lines() or {}) do lines[#lines + 1] = ass_escape(l) end
    if #lines == 0 and show_panel and r and in_room() then
        local list = r.members or {}
        for i = 1, math.min(#list, PANEL_LINES) do lines[#lines + 1] = ass_escape(member_label(list[i], true)) end
        if #list > PANEL_LINES then lines[#lines + 1] = T("more", #list - PANEL_LINES) end
    end
    mp.set_property_native("user-data/watch-together/panel", lines)  -- for tests
    if #lines == 0 then
        panel:remove()
        return
    end
    -- Top right, below where fullscreen window buttons appear: the top left belongs to mpv's own
    -- messages (our notices, volume, seek time, stats), which would overlap the panel.
    local w, h = mp.get_osd_size()
    panel.res_y = 720
    panel.res_x = (w and h and w > 0 and h > 0) and math.floor(720 * w / h) or 1280
    panel.data = string.format("{\\an9\\pos(%d,%d)\\fs18\\bord1.5}", panel.res_x - 20, 50) .. table.concat(lines, "\\N")
    panel:update()
end

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

-- Host episodes this guest has neither in the playlist nor in the download folder. One that only
-- plays from the host still counts as missing: it can be downloaded.
local function missing_files()
    if not host_files then return {} end
    local have = {}
    for _, e in ipairs(mp.get_property_native("playlist") or {}) do
        if not is_url(e.filename) then have[basename(e.filename)] = true end
    end
    local dir, list = download_dir(), {}
    for _, name in ipairs(host_files.names) do
        if not have[name] and not utils.file_info(utils.join_path(dir, name)) then list[#list + 1] = name end
    end
    return list
end

------------------------------------------------------------------ stream buffer

-- mpv's buffer for streams (torrent episodes, episodes watched from the host). TorrServer itself fetches only
-- 16 MB ahead of what mpv reads, so this buffer is what gets downloaded ahead.
-- One table, not six locals: main.lua is at LuaJIT's limit of 200 locals in the main chunk.
local buffer = {
    CHOICES = { 256, 512, 1024, 1536, 2048, 3072, 4096 },
    ram_limit = nil,        -- MB the RAM guard allows the buffer now; nil = no limit
}

function buffer.mb()
    local b = settings.buffer_mb
    if b > 0 and settings.ram_guard and buffer.ram_limit then b = math.min(b, buffer.ram_limit) end
    return b
end

function buffer.text(m)
    if m < 1024 then return T("mb", m) end
    local s = string.format("%g", math.floor(m / 1024 * 10 + 0.5) / 10)
    if lang == "ru" then s = s:gsub("%.", ",") end
    return T("gb", s)
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
    local items = {}
    -- First, so a guest sees it before anything else.
    if role == "join" and host_files and #host_files.names > 0 then
        items[#items + 1] = { title = T("stream_menu"), cmd = "script-message watch-together-stream-toggle", state = st(false, streaming) }
        items[#items + 1] = { type = "separator" }
    end
    items[#items + 1] = { title = T("status", status_text), state = { "disabled" } }
    items[#items + 1] = { title = T("you", menu_name(media_name())), state = { "disabled" } }
    -- A guest follows the host's files, so only the host or someone alone opens a torrent.
    if role ~= "join" then
        items[#items + 1] = { title = T("open_torrent"), cmd = "script-message watch-together-open-torrent" }
        if engine_hash(mp.get_property("path")) then
            items[#items + 1] = { title = T("check_menu"), cmd = "script-message watch-together-check" }
        end
    end
    local r = current_room()
    if in_room() and r and r.members then
        local sub = {}
        for _, m in ipairs(r.members) do sub[#sub + 1] = { title = menu_name(member_label(m, false)), state = { "disabled" } } end
        items[#items + 1] = { type = "submenu", title = T("members"), submenu = sub }
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
            sub[#sub + 1] = { title = T("download_all"), cmd = "script-message watch-together-dl-all" }
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
    local buf = {}
    for _, v in ipairs(buffer.CHOICES) do
        buf[#buf + 1] = { title = buffer.text(v), cmd = "script-message watch-together-buffer " .. v, state = st(false, settings.buffer_mb == v) }
    end
    buf[#buf + 1] = { type = "separator" }
    buf[#buf + 1] = { title = T("buffer_guard"), cmd = "script-message watch-together-setting ram_guard", state = st(false, settings.ram_guard) }
    local buf_title = T("buffer_menu", buffer.text(settings.buffer_mb))
    if buffer.mb() < settings.buffer_mb then buf_title = buf_title .. " " .. T("buffer_now", buffer.text(buffer.mb())) end
    items[#items + 1] = { type = "submenu", title = T("settings"), submenu = {
        { title = T("set_soft"), cmd = "script-message watch-together-setting soft_sync", state = st(false, settings.soft_sync) },
        { type = "submenu", title = buf_title, submenu = buf },
        { type = "separator" },
        { title = T("when_host"), state = { "disabled" } },
        { title = T("set_wait"), cmd = "script-message watch-together-setting wait_for_others", state = st(false, settings.wait_for_others) },
        { title = T("set_countdown", COUNTDOWN_SECONDS), cmd = "script-message watch-together-setting countdown_on", state = st(false, settings.countdown_on) },
        { title = T("set_resume"), cmd = "script-message watch-together-setting resume_memory", state = st(false, settings.resume_memory) },
        { title = T("set_share", o.share_port), cmd = "script-message watch-together-setting share_files", state = st(false, settings.share_files) },
    } }
    -- Only what can be pressed now: no room yet means create or join, in a room only leave.
    items[#items + 1] = { type = "separator" }
    if active then
        items[#items + 1] = { title = T("leave"), cmd = "script-message watch-together-leave" }
    else
        items[#items + 1] = { title = T("host"), cmd = "script-message watch-together-host" }
        items[#items + 1] = { title = T("join"), cmd = "script-message watch-together-join" }
        items[#items + 1] = { title = T("join_clipboard"), cmd = "script-message watch-together-join-clipboard" }
    end
    items[#items + 1] = { type = "separator" }
    items[#items + 1] = { title = T("version", VERSION), state = { "disabled" } }
    if update_available then
        items[#items + 1] = { title = T("install_update", update_available), cmd = "script-message watch-together-install" }
    else
        items[#items + 1] = { title = T("check_update"), cmd = "script-message watch-together-update" }
    end
    return { type = "submenu", title = T("menu"), submenu = items }
end

-- Found by its commands, not its title: the title changes when the language is detected. The
-- update entry is the one command that is always there (the others come and go with the room).
local function is_ours(item)
    for _, sub in ipairs(item.submenu or {}) do
        if sub.cmd == "script-message watch-together-update" or sub.cmd == "script-message watch-together-install" then return true end
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
    local mine, name = mp.get_property_number("duration"), media_name()
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

-- Same file name in my playlist first, a local copy before a stream from the host; different
-- releases fall back to the same playlist position.
local function follow_file(m)
    if type(m.file) ~= "string" or m.file == media_name() then return false end
    -- We just moved on to the next episode by ourselves; the host gets there a moment later.
    if role == "join" and mp.get_time() < keep_file_until then return false end
    local playlist = mp.get_property_native("playlist") or {}
    local index, stream_index
    for i, entry in ipairs(playlist) do
        if basename(entry.filename) == m.file then
            if not is_url(entry.filename) then index = i - 1 break end
            stream_index = stream_index or i - 1
        end
    end
    index = index or stream_index
    -- In a torrent room names are exact; a missing one is still being added, not another release.
    if not index and not room_torrent and type(m.pl) == "number" and m.pl >= 0 and m.pl < #playlist then index = m.pl end
    if not index and room_torrent and m.file ~= last_missing then
        last_missing = m.file
        tlog("follow: %s is not in the playlist (yet)", m.file)
    end
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
    -- Without soft sync every correction is a seek, so it starts earlier, as before 1.4.2.
    local limit = paused and math.max(0.1, 1.5 / math.max(fps, 1))
                  or (settings.soft_sync and o.threshold or math.min(o.threshold, 0.3))
    local drift = cur and target - cur or 0
    -- A guest a little off while playing catches up by playing slightly faster or slower, halving the
    -- drift about every tick. The host is the reference and never nudges.
    nudge = 1
    if settings.soft_sync and role == "join" and not paused and math.abs(drift) > NUDGE_DEAD and math.abs(drift) <= limit then
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
             dur = mp.get_property_number("duration"), file = media_name(),
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
        -- The same player again: its old connection is dead but not closed yet (a tunnel can keep it
        -- for a while). Drop it silently, or this guest would come back as "name (p2)".
        g.cid = type(m.cid) == "string" and m.cid:match("^%x+$") and m.cid:sub(1, 32) or nil
        for other_id, other in pairs(members) do
            if g.cid and other_id ~= id and other.cid == g.cid then
                members[other_id] = nil
                mp.commandv("script-message", "watch-together-close", other_id)
            end
        end
        local name = type(m.name) == "string" and m.name:sub(1, 32) or id
        for other_id, other in pairs(members) do
            if other_id ~= id and other.name == name then name = name .. " (" .. id .. ")" end
        end
        if name == my_name then name = name .. " (" .. id .. ")" end
        g.name, g.v, g.torrent = name, m.v, m.torrent == true
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
        send_torrent(id)
        if check then send(id, { t = "check", on = true }) end
        set_status("hosting")
    elseif m.t == "ping" then
        send(id, { t = "pong", id = m.id })
    elseif m.t == "status" then
        g.file = type(m.file) == "string" and m.file:sub(1, 512) or nil
        g.pos = type(m.pos) == "number" and m.pos or nil
        g.pos_at = mp.get_time()  -- not g.at: any message refreshes that, and a ping comes just before this
        g.paused = m.paused == true
        g.rtt = type(m.rtt) == "number" and m.rtt or nil
    elseif m.t == "check" and type(m.r) == "table" then
        local function num(v) return type(v) == "number" and v >= 0 and v < 1e12 and v or nil end
        g.check = { speed = num(m.r.speed), need = num(m.r.need), peers = num(m.r.peers), buf = num(m.r.buf),
                    ["local"] = m.r["local"] == true, away = m.r.away == true }
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
    if status == "connecting" then  -- the host's first answer on this link
        set_status("connected")
        osd(T("in_room"))
        if my_wait then report_wait() end
    elseif status == "lost" then
        set_status("connected")
    end

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
        add_streams()
        refresh_menu()
    elseif m.t == "torrent" then
        on_room_torrent(m)
    elseif m.t == "check" then
        check_wanted = m.on == true
        if check_wanted then start_check() else stop_check() end
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
        local function check_of(c)
            if type(c) ~= "table" then return nil end
            return { speed = num(c.speed), need = num(c.need), peers = num(c.peers), buf = num(c.buf),
                     ["local"] = c["local"] == true, away = c.away == true }
        end
        for _, e in ipairs(m.members) do
            if type(e) == "table" and type(e.name) == "string" and #list < 500 then
                list[#list + 1] = { name = e.name, file = type(e.file) == "string" and e.file or nil,
                                    pos = num(e.pos), off = num(e.off), paused = e.paused == true,
                                    host = e.host == true, stale = e.stale == true,
                                    wait = type(e.wait) == "string" and e.wait or nil, check = check_of(e.check) }
            end
        end
        room = { control = m.control == "host" and "host" or "all", members = list }
        check_room = type(m.check) == "table" and num(m.check.left) and { left = math.max(0, m.check.left) } or nil
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
                file = media_name(), pl = mp.get_property_number("playlist-pos") }
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

function report_wait()
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
    stop_stream()
    drop_room_torrent()
    if role == "join" then
        check_wanted, check_room = false, nil
        stop_check()
    end
    sent_torrent = nil
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
            -- Only a link so far, not the room: Porthole accepts on the guest's PC even before the host has
            -- opened the room, then drops the link. The host's first answer makes us "in the room".
            last_rx = mp.get_time()
            send("host", { t = "hello", v = PROTOCOL, name = my_name, cid = settings.cid, torrent = true })
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
            local was_in = status ~= "connecting"  -- dropped before the host ever answered: just retry quietly
            host_state, room, pending = nil, nil, nil
            end_nudge()
            set_status("connecting")
            if was_in then osd(T("host_dropped")) end
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

-- Per folder of episodes, or per torrent: which file and where we were, while watching in a room
-- (torrents also alone, so the episode chooser can offer it).
local function history_key()
    local hash = engine_hash(mp.get_property("path"))
    if hash then return "btih:" .. hash end
    local full = current_path()
    local dir = full and utils.split_path(full)
    return dir and dir:lower()
end

local function load_history()
    if not HISTORY_FILE then return history_mem end
    return read_state(HISTORY_FILE) or {}
end

function remember()
    if not settings.resume_memory or not (role or engine_hash(mp.get_property("path"))) then return end
    local key, pos, name = history_key(), mp.get_property_number("time-pos"), media_name()
    if not key or not pos or not name then return end
    local h = load_history()
    h[key] = { file = name, pos = pos, t = os.time() }
    -- Keep the 50 most recent folders.
    local keys = {}
    for k, v in pairs(h) do if type(v) == "table" and type(v.t) == "number" then keys[#keys + 1] = k else h[k] = nil end end
    table.sort(keys, function(x, y) return h[x].t > h[y].t end)
    for i = 51, #keys do h[keys[i]] = nil end
    if not HISTORY_FILE then history_mem = h return end
    write_state(HISTORY_FILE, utils.format_json(h))
end

-- Also when a file is left (another episode or torrent opened), or its last seconds would be lost.
mp.add_hook("on_unload", 50, function() remember() end)

local function resume_to(e)
    if e.file == media_name() then
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
    if e.file == media_name() and math.abs(e.pos - (mp.get_property_number("time-pos") or 0)) < 30 then return end
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
    elseif kind == "watching" and type(a) == "string" and type(b) == "string" then
        osd(T("share_watching", short(a, 24), short(b, 60)))
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
            dl_finished = name  -- its "done" message can arrive after the process has exited
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
    if not (dl_current and name == dl_current.name) and not (kind == "done" and name == dl_finished) then return end
    if kind == "done" then dl_finished = nil end
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

------------------------------------------------------------------ watching from the host

local function stream_prefix() return stream_port and ("http://127.0.0.1:" .. stream_port .. "/") end

function buffer.is_stream(url)
    local prefix = stream_prefix()
    return type(url) == "string" and (engine_hash(url) ~= nil or (prefix ~= nil and url:sub(1, #prefix) == prefix))
end

-- The chosen size goes 3/4 ahead, 1/4 behind, for the file playing now. When the RAM guard allows less, 3/4
-- of the cut comes off the part already watched and 1/4 off the far end of the part ahead, so a short rewind
-- still plays from memory. The watched part keeps at least 32 MB (about 15 s of 4K); a cut too big for that
-- takes the rest from ahead (down to 96 MB). Also while it plays: mpv drops watched data over a smaller
-- limit at once, while it still reads (not once the whole file is read); data ahead over a smaller limit
-- stays until it has played, mpv only stops reading.
function buffer.apply()
    local chosen, b = settings.buffer_mb, buffer.mb()
    if b <= 0 then return end
    local ahead = math.floor(chosen * 3 / 4)
    local back = chosen - ahead
    if b < chosen then
        local cut = chosen - b
        local from_back = math.min(math.floor(cut * 3 / 4), math.max(0, back - 32))
        back = back - from_back
        ahead = math.max(96, ahead - (cut - from_back))
    end
    mp.set_property("file-local-options/demuxer-max-bytes", ahead .. "MiB")
    mp.set_property("file-local-options/demuxer-max-back-bytes", back .. "MiB")
end

-- mpv keeps 150 MB ahead and 50 behind by default: about a minute of 4K. Only streams from the host or
-- from the torrent engine get the stream buffer. A torrent stream's title is its file name, not the URL's tail.
mp.add_hook("on_load", 50, function()
    local url = mp.get_property("stream-open-filename", "")
    if engine_hash(url) then mp.set_property("file-local-options/force-media-title", basename(url)) end
    if buffer.is_stream(url) then buffer.apply() end
end)

-- Free and total physical memory in MB, every 5 s from torrent.ps1 or stream.ps1 (whichever runs). The buffer
-- may use what is free beyond a reserve of max(1 GB, 15 % of RAM) for everything else on the PC.
mp.register_script_message("watch-together-ram", function(free, total)
    free, total = tonumber(free), tonumber(total)
    if not free or not total or total <= 0 or settings.buffer_mb <= 0 then return end
    local reserve = math.max(1024, total * 0.15)
    local state = mp.get_property_native("demuxer-cache-state")
    local used = (type(state) == "table" and tonumber(state["total-bytes"]) or 0) / 1048576
    local allowed = used + free - reserve
    local limit = allowed < settings.buffer_mb and math.max(128, math.floor(allowed / 64) * 64) or nil
    -- Growing back needs room to spare, or a buffer near the line would shrink and grow every 5 s.
    if buffer.ram_limit and (not limit or limit > buffer.ram_limit) and free < reserve + 256 then return end
    if limit == buffer.ram_limit then return end
    local was = buffer.ram_limit
    buffer.ram_limit = limit
    tlog("ram: %d of %d MB free, buffer %s", free, total, limit and (limit .. " MB") or "as chosen")
    if not settings.ram_guard then return end
    if buffer.is_stream(mp.get_property("path")) then buffer.apply() end
    if limit and not was then osd(T("buffer_reduced", buffer.text(limit)))
    elseif not limit then osd(T("buffer_restored", buffer.text(settings.buffer_mb))) end
    refresh_menu()
end)

mp.register_script_message("watch-together-buffer", function(v)
    v = tonumber(v)
    local known = false
    for _, c in ipairs(buffer.CHOICES) do if c == v then known = true end end
    if not known then return end
    settings.buffer_mb = v
    save_settings()
    if buffer.is_stream(mp.get_property("path")) then buffer.apply() end
    osd(T("buffer_set", buffer.text(v)) .. (buffer.mb() < v and (" " .. T("buffer_now", buffer.text(buffer.mb()))) or ""))
    refresh_menu()
end)

-- Every host episode not in the playlist yet goes in as a stream, so follow_file finds it by name.
function add_streams()
    local prefix = stream_prefix()
    if not prefix or not host_files then return end
    local have = {}
    for _, e in ipairs(mp.get_property_native("playlist") or {}) do have[basename(e.filename)] = true end
    for _, name in ipairs(host_files.names) do
        if not have[name] then mp.commandv("loadfile", prefix .. pct(name), "append") end
    end
end

local function start_stream()
    if stream_helper or role ~= "join" or not host_files or not joined_address then return end
    streaming = true
    local h
    h = mp.command_native_async({ name = "subprocess", playback_only = false, capture_stderr = true,
        args = ps_args("stream.ps1", "-Pipe", ipc_pipe_name(), "-Script", mp.get_script_name(), "-Address", joined_address,
                       "-Port", tostring(host_files.port), "-Who", room_name or my_name),
    }, function(_, res)
        if stream_helper ~= h then return end
        mp.msg.warn("stream.ps1 exited: " .. utils.format_json(res))
        stop_stream()
        refresh_menu()
    end)
    stream_helper = h
end

-- The streams leave the playlist with stream.ps1: nothing would answer them.
function stop_stream()
    streaming = false
    if stream_helper then
        local h = stream_helper
        stream_helper = nil
        mp.abort_async_command(h)
    end
    local prefix = stream_prefix()
    stream_port = nil
    if not prefix then return end
    local playlist = mp.get_property_native("playlist") or {}
    for i = #playlist, 1, -1 do
        if playlist[i].filename:sub(1, #prefix) == prefix then mp.commandv("playlist-remove", i - 1) end
    end
end

mp.register_script_message("watch-together-stream-toggle", function()
    if streaming then
        stop_stream()
        osd(T("stream_off"))
    else
        start_stream()
    end
    refresh_menu()
end)

-- From stream.ps1: ready <port> | error <text>
mp.register_script_message("watch-together-stream", function(kind, a)
    if kind == "ready" and stream_helper and tonumber(a) then
        stream_port = tonumber(a)
        add_streams()
        osd(T("stream_on"))
        -- The room may be on an episode only the host has.
        if host_state then mp.add_timeout(0.5, apply_host_state) end
    elseif kind == "error" then
        osd(T("stream_failed", tostring(a)) .. "\n" .. T("dl_hint", host_files and host_files.port or o.share_port))
    end
end)

------------------------------------------------------------------ torrents

local check_after_pick      -- {hash, i}: the swarm check starts once this episode has loaded
local replaced = {}         -- playlist names of opened magnets/.torrents; their entries go at the next start-file

-- The rest of this section stays inside do ... end, so its locals end here: main.lua is at LuaJIT's limit of
-- 200 locals in the main chunk.
do
local engine                -- torrent.ps1: {handle, ready, queue of commands sent once it is ready}
local engine_jobs = {}      -- add job id -> {ok(hash, files), fail(text)}
local job_seq = 0
local pending_pick          -- finishes the episode chooser that is open now
local tfile_job             -- guest: {hash, ok, fail, handle} while the host's .torrent downloads

local tracks = require("tracks")  -- which subtitle and audio files go with which video

-- In mpv's config folder; %TEMP% without one.
local function engine_exe()
    local dir = state_file("watch_together_engine") or utils.join_path(os.getenv("TEMP") or ".", "watch-together-engine")
    return utils.join_path(dir, "TorrServer.exe")
end

local function start_engine()
    local args = ps_args("torrent.ps1", "-Pipe", ipc_pipe_name(), "-Script", mp.get_script_name(),
                         "-CacheMB", tostring(o.torrent_cache))
    local more = o.torrent_url ~= "" and { "-Base", engine_base }
                 or { "-Exe", engine_exe(), "-Download", ENGINE.url, "-Sha256", ENGINE.sha256, "-Port", tostring(o.torrent_port) }
    for _, a in ipairs(more) do args[#args + 1] = a end
    tlog("engine: starting the helper (%s)", o.torrent_url ~= "" and engine_base or engine_exe())
    local h
    h = mp.command_native_async({ name = "subprocess", args = args, playback_only = false, capture_stderr = true },
        function(_, res)
            if not engine or engine.handle ~= h then return end
            local why = engine.last_error or T("engine_died")  -- the reason it gave before exiting, if any
            engine = nil
            tlog("engine: the helper exited: %s", utils.format_json(res))
            local jobs = engine_jobs
            engine_jobs = {}
            for _, job in pairs(jobs) do job.fail(why) end
        end)
    engine = { handle = h, ready = false, queue = {} }
end

-- The first command starts the engine (downloading it the first time); commands wait until it is up.
local function engine_cmd(...)
    if not engine then start_engine() end
    local args = { "script-message", "watch-together-torrent-cmd", ... }
    if engine.ready then mp.commandv(unpack(args)) else engine.queue[#engine.queue + 1] = args end
end

local function add_torrent(link, ok, fail)
    job_seq = job_seq + 1
    local id = tostring(job_seq)
    engine_jobs[id] = { ok = ok, fail = fail }
    tlog("add #%s: %s", id, link:sub(1, 300))
    engine_cmd("add", id, link)
end

-- TorrServer takes a local .torrent as a file:// link.
local function file_url(path)
    return "file:///" .. (path:gsub("\\", "/"):gsub("[^%w%-%._~/:]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- "S1E2" before "S1E10".
local function natural_key(s)
    return (s:lower():gsub("%d+", function(d) return string.rep("0", 12 - #d) .. d end))
end

-- The engine's file list: the videos become the playlist (all files if there are none), in natural order;
-- subtitle and audio files go with their videos (tracks.lua), font files are fetched for ASS subtitles.
-- Names come from the torrent, so they only go into URLs (percent-encoded), comparisons, labels and track
-- titles (an argument of sub-add, never a command).
local function set_torrent_files(t, list)
    local all, videos = {}, {}
    for _, f in ipairs(list) do
        if type(f) == "table" and type(f.i) == "number" and f.i >= 1 and f.i == math.floor(f.i) and type(f.path) == "string"
           and #f.path <= 1024 and not f.path:find("%c") then
            local name = f.path:match("[^/\\]+$")
            if name and #name <= 255 then
                local e = { i = f.i, name = name, path = f.path, length = tonumber(f.length) or 0 }
                all[#all + 1] = e
                if tracks.kind(name) == "video" then videos[#videos + 1] = e end
            end
        end
    end
    local files = #videos > 0 and videos or all
    table.sort(files, function(x, y) return natural_key(x.path) < natural_key(y.path) end)
    t.files = files
    local fonts
    t.extras, fonts = tracks.attach(all)
    local n, ass = 0, false
    for _, l in pairs(t.extras) do
        for _, e in ipairs(l) do
            n = n + 1
            if e.kind == "sub" and (tracks.ext(e.name) == "ass" or tracks.ext(e.name) == "ssa") then ass = true end
        end
    end
    tlog("extra tracks: %d for %d videos; %d font files", n, #videos, #fonts)
    -- In %TEMP%, by torrent.ps1; they apply from the next episode that loads after they are in.
    if ass and #fonts > 0 and not t.fonts_asked then
        t.fonts_asked = true
        local spec = {}
        for _, f in ipairs(fonts) do spec[#spec + 1] = f.i .. ":" .. tracks.ext(f.name) .. ":" .. math.floor(f.length) end
        engine_cmd("fonts", t.hash, table.concat(spec, ";"))
    end
    return files
end

-- Which episode to start from. A torrent watched before goes on at once from the episode and time it
-- stopped at (another episode is in the playlist); a new one asks. Esc starts the first: the file being opened
-- waits for this answer.
local function choose_episode(t, cb)
    local h = load_history()["btih:" .. t.hash]
    if type(h) ~= "table" or type(h.file) ~= "string" or type(h.pos) ~= "number" then h = nil end
    local default, known = 1, false
    for k, f in ipairs(t.files) do
        if h and f.name == h.file then default, known = k, true end
    end
    local picked = false
    local function finish(k)
        if picked then return end
        picked, pending_pick = true, nil
        k = (type(k) == "number" and t.files[k]) and k or default
        cb(k, (h and t.files[k].name == h.file) and h.pos or nil)
    end
    if known then
        osd(T("torrent_resuming", short(t.files[default].name, 60), fmt_time(h.pos)))
        finish(default)
        return
    end
    local ok, input = pcall(require, "mp.input")
    if #t.files == 1 or not ok then finish(default) return end
    pending_pick = finish
    -- One folder at a time (tracks.folder); Back and Esc go up a level, Esc at the top starts the first.
    -- The next folder opens once the console has closed the current one: closed comes after submit.
    local stack, root = {}, nil
    local function show(dir, focus)
        if picked then return end
        if pending_pick ~= finish then finish(default) return end
        local entries
        entries, dir = tracks.folder(t.files, dir)
        root = root or dir
        local names = { files = {}, dirs = {} }
        for _, e in ipairs(entries) do table.insert(e.dir and names.dirs or names.files, e.name) end
        local files, dirs = tracks.short_names(names.files, 70), tracks.short_names(names.dirs, 50)
        local back = #stack > 0
        local items, at, fi, di = {}, {}, 0, 0
        if back then items[1] = T("torrent_back") end
        local item = back and 2 or 1
        for _, e in ipairs(entries) do
            if e.dir then
                di = di + 1
                items[#items + 1] = dirs[di] .. "/  (" .. e.count .. ") — " .. mb(e.size)
                if focus and focus:sub(1, #e.dir) == e.dir then item = #items end
            else
                fi = fi + 1
                items[#items + 1] = files[fi] .. " — " .. mb(e.size)
                if focus and t.files[e.k].path == focus then item = #items end
            end
            at[#items] = e
        end
        local prompt = T("torrent_choose")
        if dir ~= root then prompt = prompt .. "  " .. tracks.short_names({ dir:sub(#root + 1, -2) }, 50)[1] end
        local nav
        input.select({ prompt = prompt, items = items, default_item = item,
            submit = function(i)
                if back and i == 1 then
                    nav = { dir = table.remove(stack), focus = dir }
                elseif at[i] and at[i].dir then
                    stack[#stack + 1] = dir
                    nav = { dir = at[i].dir }
                elseif at[i] then
                    finish(at[i].k)
                end
            end,
            closed = function()
                if picked then return end
                if not nav and back and pending_pick == finish then nav = { dir = table.remove(stack), focus = dir } end
                if nav then mp.add_timeout(0, function() show(nav.dir, nav.focus) end) else finish(default) end
            end })
    end
    show("", t.files[default].path)
end

-- A magnet or .torrent becomes the torrent's files in the playlist and the chosen episode plays.
-- index: the playlist position of the link's own entry when mpv opened it (the files go right after it, the
-- entry goes when the episode starts); nil from the menu, where the torrent replaces the playlist.
local function open_torrent(link, index, done)
    if mp.get_property_native("platform") ~= "windows" then osd(T("windows_only")) done() return end
    mp.osd_message(T("torrent_opening"), 90)
    local tfile = not link:match("^magnet:") and link or nil
    add_torrent(tfile and file_url(tfile) or link, function(hash, list)
        local t = torrents[hash] or {}
        t.hash, t.magnet, t.tfile = hash, not tfile and link or nil, tfile
        local files = set_torrent_files(t, list)
        mp.osd_message("", 0)
        if #files == 0 then osd(T("torrent_empty")) done() return end
        torrents[hash] = t
        if index then
            for k, f in ipairs(files) do mp.commandv("loadfile", engine_url(hash, f), "insert-at", tostring(index + k)) end
        end
        choose_episode(t, function(k, resume_pos)
            tlog("open: %s videos, picked %s, resume at %s", #files, files[k].path, tostring(resume_pos))
            pending_resume = resume_pos
            if o.torrent_check > 0 then
                -- Everyone opens it paused and measures the swarm until someone presses play.
                check_after_pick = { hash = hash, i = files[k].i }
                mp.set_property_native("pause", true)
            end
            if index then
                mp.commandv("playlist-play-index", tostring(index + k))
            else
                mp.commandv("loadfile", engine_url(hash, files[k]), "replace")
                for j, f in ipairs(files) do
                    if j < k then mp.commandv("loadfile", engine_url(hash, f), "insert-at", tostring(j - 1))
                    elseif j > k then mp.commandv("loadfile", engine_url(hash, f), "append") end
                end
            end
            done()
        end)
    end, function(err)
        tlog("open failed: %s", tostring(err))
        osd(T("torrent_failed", err))
        done()
    end)
end

-- Magnets and .torrent files from the command line, drag and drop or a playlist. mpv takes a magnet for a
-- relative path: it puts the working folder in front and turns its slashes into backslashes ("udp://x"
-- becomes "udp:\x"). A magnet holds no backslashes of its own, so they are undone here.
mp.add_hook("on_load", 9, function(hook)
    local link = mp.get_property("stream-open-filename", "")
    local magnet = link:match("(magnet:%?.*)$")
    if magnet then
        link = magnet:gsub("\\", "/"):gsub("=(%a[%w+.-]*):/(%w)", "=%1://%2")
    else
        if is_url(link) or not link:lower():match("%.torrent$") then return end
        link = utils.join_path(mp.get_property("working-directory", ""), link)
        if not utils.file_info(link) then return end
    end
    local index = mp.get_property_number("playlist-pos", 0)
    replaced[mp.get_property("playlist/" .. index .. "/filename") or link] = true
    hook:defer()
    -- mpv waits for a held load even when told to quit, so the window's close button did nothing while the
    -- file list came or the chooser was open. While it is held, closing lets it go and quits.
    local held = true
    local function release()
        if not held then return false end
        held = false
        mp.remove_key_binding("watch-together-close-while-opening")
        hook:cont()
        return true
    end
    mp.add_forced_key_binding("CLOSE_WIN", "watch-together-close-while-opening", function()
        tlog("open: the window was closed while the torrent was opening")
        local ok, input = pcall(require, "mp.input")
        if pending_pick and ok and input.terminate then input.terminate() end
        pending_pick = nil
        release()
        mp.command("quit")
    end)
    open_torrent(link, index, release)
end)

mp.register_script_message("watch-together-open-torrent", function()
    if role == "join" then return end
    mp.commandv("update-clipboard", "text")
    local text = (mp.get_property("clipboard/text") or ""):match("^%s*(.-)%s*$")
    text = text:gsub('^"(.*)"$', "%1")  -- Explorer's "Copy as path" adds quotes
    if text:match("^magnet:%?") or (text:lower():match("%.torrent$") and utils.file_info(text)) then
        open_torrent(text, nil, function() end)  -- what plays now keeps playing until an episode is picked
    else
        osd(T("bad_torrent_clipboard"))
    end
end)

-- Answers the open episode chooser: for tests, or an input.conf binding.
mp.register_script_message("watch-together-pick", function(k)
    if not pending_pick then return end
    local ok, input = pcall(require, "mp.input")
    if ok and input.terminate then input.terminate() end
    if pending_pick then pending_pick(tonumber(k)) end
end)

-- From torrent.ps1: engine <bytes> <total> | ready | files <id> <hash> <json> | stat <hash> <B/s> <peers> <seeders> |
-- fonts <hash> <failed> | error <id> <text>
mp.register_script_message("watch-together-torrent", function(kind, a, b, c, d)
    if not engine then return end
    if kind == "engine" then
        local done, total = tonumber(a) or 0, tonumber(b) or 0
        if not engine.downloading then
            engine.downloading = true
            tlog("engine: downloading %s", ENGINE.url)
        end
        if total > 0 then mp.osd_message(T("engine_progress", math.floor(done * 100 / total), mb(done), mb(total)), 2) end
    elseif kind == "ready" then
        -- Our engine on 127.0.0.1 at the port torrent.ps1 chose; a torrent_url engine keeps its address.
        if o.torrent_url == "" then
            if type(a) ~= "string" or not a:match("^http://127%.0%.0%.1:%d+$") then return end
            engine_base = a
        end
        tlog("engine: ready at %s", engine_base)
        if engine.ready then return end  -- moved after a restart: only the address changes
        engine.ready = true
        for _, args in ipairs(engine.queue) do mp.commandv(unpack(args)) end
        engine.queue = {}
    elseif kind == "fonts" then
        local t = torrents[a or ""]
        if not t then return end
        t.fonts_dir = (os.getenv("TEMP") or ".") .. "\\watch-together\\fonts\\" .. t.hash  -- where torrent.ps1 puts them
        tlog("fonts of %s are in (%s failed)", t.hash, tostring(b))
    elseif kind == "preloaded" or kind == "preload-failed" then
        tlog("preload of #%s in %s: %s", tostring(b), tostring(a), kind == "preloaded" and "done" or tostring(c))
    elseif kind == "restarted" then
        tlog("engine: it had stopped and runs again")
    elseif kind == "files" then
        local job = engine_jobs[a]
        engine_jobs[a] = nil
        local list = utils.parse_json(c or "")
        tlog("add #%s: hash %s, %s files", tostring(a), tostring(b), type(list) == "table" and #list or "?")
        if not job then return end
        if type(b) == "string" and #b == 40 and b:match("^%x+$") and type(list) == "table" then job.ok(b:lower(), list)
        else job.fail("bad answer from the engine") end
    elseif kind == "stat" then
        if not check or check.hash ~= a then return end
        check.peers = tonumber(c) or check.peers
        -- The first seconds only find and connect peers, and a second without download means the engine
        -- had nothing to fetch (its cache or the player is full) or nothing came: both would understate
        -- the speed. check_result tells them apart by the player's buffer.
        local bps = (tonumber(b) or 0) * 8
        tlog("stat: %.1f Mbit/s, %s peers, %s seeders, %.0f s buffered", bps / 1e6, tostring(c), tostring(d),
             mp.get_property_number("demuxer-cache-duration") or 0)
        if mp.get_time() - check.started >= 5 and bps > 0 then
            check.sum = check.sum + bps
            check.n = check.n + 1
        end
    elseif kind == "error" then
        tlog("engine error #%s: %s", tostring(a), tostring(b))
        local job = a and engine_jobs[a]
        engine_jobs[a or ""] = nil
        if job then job.fail(tostring(b))
        else
            engine.last_error = tostring(b)  -- the helper exits next; its callers get this, not "stopped"
            osd(T("torrent_failed", tostring(b)))
        end
    end
end)

-- Host: which torrent the room watches (none when the host plays something else). A .torrent goes to
-- the guests through the share port, a magnet as it is.
function send_torrent(target)
    if role ~= "host" then return end
    local t = torrents[engine_hash(mp.get_property("path")) or ""]
    local msg = { t = "torrent" }
    if t then msg.hash, msg.magnet, msg.tfile = t.hash, t.magnet, (t.tfile and settings.share_files) or nil end
    mp.set_property("user-data/watch-together/torrent-file", t and t.tfile or "")
    mp.set_property("user-data/watch-together/torrent-name", t and t.tfile and (t.hash .. ".torrent") or "")
    sent_torrent = t and t.hash or ""
    send(target, msg)
    if not t then return end
    for id, g in pairs(members) do
        if (target == "*" or target == id) and g.v == PROTOCOL and not g.torrent then osd(T("old_torrent", g.name)) end
    end
end

-- Guest: the room's torrent episodes leave the playlist; the one playing now goes at the next file.
function drop_room_torrent()
    if not room_torrent then return end
    local hash = room_torrent.hash
    room_torrent = nil
    local pos = mp.get_property_number("playlist-pos", -1)
    local list = mp.get_property_native("playlist") or {}
    for i = #list, 1, -1 do
        if engine_hash(list[i].filename) == hash then
            if i - 1 == pos then replaced[list[i].filename] = true else mp.commandv("playlist-remove", tostring(i - 1)) end
        end
    end
end

-- Episodes this guest has neither as a file nor as a stream go in as streams from its own engine;
-- follow_file then finds them by name like any other file, and a local copy still wins.
local function add_torrent_entries(t)
    local have = {}
    for _, e in ipairs(mp.get_property_native("playlist") or {}) do
        have[basename(e.filename)] = true
        if engine_hash(e.filename) == t.hash then replaced[e.filename] = nil end  -- wanted again
    end
    for _, f in ipairs(t.files) do
        if not have[f.name] then mp.commandv("loadfile", engine_url(t.hash, f), "append") end
    end
end

-- The host's .torrent, from its share port into %TEMP%\watch-together. The name carries our pid, so two
-- players on one PC never share the file; it is deleted once the engine has read it.
local function fetch_tfile(hash, ok, fail)
    local name, dir = hash .. ".torrent", utils.join_path(os.getenv("TEMP") or ".", "watch-together")
    local save_as = hash .. "-" .. (mp.get_property_number("pid") or 0) .. ".torrent"
    os.remove(utils.join_path(dir, save_as))  -- fetch.ps1 never replaces a file
    local h
    h = mp.command_native_async({ name = "subprocess", playback_only = false, capture_stderr = true,
        args = ps_args("fetch.ps1", "-Pipe", ipc_pipe_name(), "-Script", mp.get_script_name(), "-Address", joined_address,
                       "-Port", tostring(host_files.port), "-Name", name, "-Dir", dir, "-Who", room_name or my_name,
                       "-Event", "watch-together-tfile", "-SaveAs", save_as),
    }, function()
        -- "done" can arrive just after the process has exited; no answer at all means it failed.
        mp.add_timeout(0.5, function()
            if tfile_job and tfile_job.handle == h then
                local j = tfile_job
                tfile_job = nil
                j.fail()
            end
        end)
    end)
    tfile_job = { hash = hash, ok = ok, fail = fail, handle = h }
end

-- From fetch.ps1: progress <name> <bytes> <total> | done <name> <path> | error <name> <text>
mp.register_script_message("watch-together-tfile", function(kind, name, a)
    local j = tfile_job
    if not j or name ~= j.hash .. ".torrent" then return end
    if kind == "done" and type(a) == "string" then
        tfile_job = nil
        j.ok(a)
    elseif kind == "error" then
        tfile_job = nil
        j.fail()
    end
end)

local last_room_torrent     -- guest: the host's last torrent message, for a retry

-- Guest: the host watches this torrent (or none). Peer data reaches the engine only as a link inside
-- JSON, never as an mpv command, and the engine's hash must be the one the host announced. If it fails (no
-- file list from the swarm in time, a network or proxy problem), it is tried again every 30 s while the host
-- still watches it: the host only sends it on hello and on a change.
function on_room_torrent(m)
    last_room_torrent = m
    local hash = type(m.hash) == "string" and m.hash:lower() or nil
    if hash and not (#hash == 40 and hash:match("^%x+$")) then return end
    if room_torrent and room_torrent.hash == hash then return end
    drop_room_torrent()
    tlog("room torrent: %s, magnet %s, .torrent %s", hash or "none", type(m.magnet) == "string" and "yes" or "no", tostring(m.tfile))
    if not hash or mp.get_property_native("platform") ~= "windows" then return end
    room_torrent = { hash = hash }
    local magnet = type(m.magnet) == "string" and #m.magnet <= 8192 and m.magnet:match("^magnet:%?[^%s%c]*$")
                   or ("magnet:?xt=urn:btih:" .. hash)
    osd(T("torrent_room"))
    local function failed(err)
        osd(T("torrent_failed", err))
        room_torrent = nil
        mp.add_timeout(30, function()
            if role == "join" and not room_torrent and last_room_torrent == m then
                tlog("room torrent: trying again")
                on_room_torrent(m)
            end
        end)
    end
    local function add(link, fallback, tmp)
        add_torrent(link, function(h, list)
            if tmp then os.remove(tmp) end
            if not room_torrent or room_torrent.hash ~= hash then return end
            if h ~= hash then
                tlog("room torrent: the engine has %s, not %s", h, hash)
                if fallback then add(fallback) else failed("wrong torrent") end
                return
            end
            local t = torrents[h] or { hash = h }
            set_torrent_files(t, list)
            torrents[h] = t
            add_torrent_entries(t)
            tlog("room torrent: %s episodes known", #t.files)
            osd(T("torrent_ready"))
            if host_state then mp.add_timeout(0.5, apply_host_state) end
        end, function(err)
            if tmp then os.remove(tmp) end
            tlog("room torrent: adding failed: %s", tostring(err))
            if not room_torrent or room_torrent.hash ~= hash then return end
            if fallback then add(fallback) else failed(err) end
        end)
    end
    if m.tfile == true and host_files and joined_address then
        fetch_tfile(hash, function(path) add(file_url(path), magnet, path) end, function()
            tlog("room torrent: no .torrent from the host's share port, using the magnet")
            add(magnet)
        end)
    else
        add(magnet)
    end
end

local preloaded_path         -- the episode whose next one was asked for, so it is asked for once

-- Near the end of a torrent episode, the engine fetches the start (and the last 8 MB, where an index often
-- is) of the next playlist entry, so it starts at once: for everyone in a room, each from its own engine,
-- and alone too. TorrServer fetches half its cache (128 MB), the preloadCache share torrent.ps1 sets. A next
-- entry that is a local file or a host stream needs nothing.
function preload_next()
    if o.torrent_preload <= 0 then return end
    local path = mp.get_property("path")
    if not engine_hash(path) or preloaded_path == path then return end
    local left = (mp.get_property_number("duration") or 0) - (mp.get_property_number("time-pos") or 0)
    if left <= 0 or left > o.torrent_preload then return end
    preloaded_path = path
    local hash, index = engine_hash(mp.get_property("playlist/" .. (mp.get_property_number("playlist-pos", -1) + 1) .. "/filename"))
    if not hash or not index then return end
    tlog("preload: index %d of %s, %d s before the end", index, hash, left)
    engine_cmd("preload", hash, tostring(index))
end

-- This player's part of the swarm check: the torrent's download speed against the episode's bitrate.
-- The host's check runs while the room stays paused; guests measure while the host says so.
function start_check()
    stop_check()
    if role == "join" and not check_wanted then return end
    local hash, i = engine_hash(mp.get_property("path"))
    local now = mp.get_time()
    check = { started = now, ends = now + math.max(o.torrent_check, 5), sum = 0, n = 0 }
    if hash then
        check.hash = hash
        for _, f in ipairs(torrents[hash] and torrents[hash].files or {}) do
            if f.i == i then check.length = f.length end
        end
        engine_cmd("probe", hash)
    else
        -- A guest on its own copy of the room's episode needs no swarm; one still on another file is "away".
        check["local"] = current_path() ~= nil and host_state ~= nil and media_name() == host_state.file
    end
    tlog("check start: hash %s, index %s, length %s, own file %s", tostring(check.hash), tostring(i), tostring(check.length),
         tostring(check["local"]))
    if role == "host" then send("*", { t = "check", on = true }) end
    update_panel()
end

function stop_check()
    if not check then return end
    tlog("check stop: %s", utils.format_json(check_result() or {}))
    local had = check
    check = nil
    if had.hash and engine then engine_cmd("probe-stop") end
    if role == "host" then send("*", { t = "check", on = false }) end
    update_panel()
end

-- Bits per second: what the episode needs on average, and what the swarm gave after the first seconds.
-- speed: the mean of the seconds in which the engine downloaded; 0 when it fetched nothing during the whole
-- check. buf: seconds of video the player holds, which tells "nothing left to fetch" from "nothing comes".
function check_result()
    if not check then return nil end
    if check["local"] then return { ["local"] = true } end
    if not check.hash then return { away = true } end
    local r = { peers = check.peers, buf = mp.get_property_number("demuxer-cache-duration") }
    local dur = mp.get_property_number("duration")
    if check.length and check.length > 0 and dur and dur > 0 then r.need = check.length * 8 / dur end
    if check.n > 0 then r.speed = check.sum / check.n
    elseif mp.get_time() >= check.ends then r.speed = 0 end
    return r
end

mp.register_script_message("watch-together-check", function()
    if role == "join" or not engine_hash(mp.get_property("path")) then return end
    if not mp.get_property_native("pause") then mp.set_property_native("pause", true) end
    start_check()
end)

-- Which audio a Russian player hears first, unless it set alang or aid itself: a Russian track (the video's
-- own first, then the release's in folder order), else the release's first voice-over of unknown language
-- (studios rarely say "rus", and a separate audio file is almost always a translation). Else mpv's choice.
-- mpv itself keeps no choice from one file to the next, so this runs for every episode.
local function pick_audio(list, urls)
    if lang ~= "ru" or mp.get_property("options/aid") ~= "auto" then return end
    local alang = mp.get_property_native("options/alang")
    if type(alang) == "table" and #alang > 0 then return end
    local ext, choice = {}, nil
    for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
        if tr.type == "audio" then
            if tr.external then ext[tr["external-filename"] or ""] = tr.id
            elseif not choice and ({ ru = true, rus = true, russian = true })[(tr.lang or ""):lower()] then choice = tr.id end
        end
    end
    for k, e in ipairs(list) do
        if not choice and e.kind == "audio" and e.lang == "ru" then choice = ext[urls[k]] end
    end
    for k, e in ipairs(list) do
        if not choice and e.kind == "audio" and not e.lang and e.voice then choice = ext[urls[k]] end
    end
    if not choice then return end
    tlog("audio: track %d first", choice)
    mp.set_property("file-local-options/aid", tostring(choice))
end

-- The episode's own subtitle and audio files from the torrent join its tracks before mpv picks among them.
-- They are added all at once, since each waits for its first pieces from the swarm, for at most 5 s; one
-- that takes longer is still added, only after the choice. Fonts fetched for the torrent apply from here.
mp.add_hook("on_preloaded", 50, function(hook)
    local path = mp.get_property("path")
    local hash, index = engine_hash(path)
    local t = hash and torrents[hash]
    if not t then return end
    if t.fonts_dir then mp.set_property("file-local-options/sub-fonts-dir", t.fonts_dir) end
    local list = t.extras and t.extras[index] or {}
    local urls, waiting = {}, true
    local function go_on()
        if not waiting then return end
        waiting = false
        if mp.get_property("path") == path then pick_audio(list, urls) end  -- not if another file was asked for meanwhile
        hook:cont()
    end
    if #list == 0 then pick_audio(list, urls) return end
    hook:defer()
    local left, names = #list, {}
    for k, e in ipairs(list) do
        urls[k] = engine_url(hash, e)
        names[k] = e.kind .. " " .. e.title .. (e.lang and (" [" .. e.lang .. "]") or "")
        mp.command_native_async({ e.kind == "sub" and "sub-add" or "audio-add", urls[k], "auto", e.title, e.lang or "" },
            function(ok, _, err)
                if not ok then tlog("track %s: %s", e.path, tostring(err)) end
                left = left - 1
                if left == 0 then go_on() end
            end)
    end
    tlog("tracks for #%d: %s", index, table.concat(names, ", "))
    mp.add_timeout(5, go_on)
end)

end  -- torrents

------------------------------------------------------------------ settings

local SETTING_LABELS = { wait_for_others = "set_wait", countdown_on = "set_countdown",
                         resume_memory = "set_resume", share_files = "set_share", soft_sync = "set_soft",
                         ram_guard = "buffer_guard" }

local function toggle_setting(key)
    if type(settings[key]) ~= "boolean" or not SETTING_LABELS[key] then return end
    settings[key] = not settings[key]
    save_settings()
    local arg = key == "countdown_on" and COUNTDOWN_SECONDS or o.share_port
    osd(T(settings[key] and "setting_on" or "setting_off", T(SETTING_LABELS[key], arg)))
    if key == "wait_for_others" then update_hold() end
    if key == "soft_sync" and not settings.soft_sync then end_nudge() end
    if key == "ram_guard" and buffer.is_stream(mp.get_property("path")) then buffer.apply() end
    if key == "countdown_on" and not settings.countdown_on and countdown_end then finish_countdown() end
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
    -- Playing ends the swarm check, whoever pressed play (a guest's play reaches the host as our own unpause).
    if paused == false and check and role ~= "join" then stop_check() end
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
        countdown_pending = ended_by_itself and settings.countdown_on and status == "hosting"
        -- The torrent first: guests must know the room's torrent before they look for its file.
        if (engine_hash(mp.get_property("path")) or "") ~= sent_torrent then send_torrent("*") end
        if status == "hosting" or status == "listening" then broadcast("file", by) end
        send_files("*")
    elseif role == "join" then
        if followed then apply_host_state()
        elseif ended_by_itself then keep_file_until = mp.get_time() + 3  -- the host moves on in a moment
        else local_action("file") end
        if check_wanted then start_check() end  -- measure the episode we are on now
    end
    -- The swarm check belongs to the episode it was started on.
    local hash, index = engine_hash(mp.get_property("path"))
    if hash or room_torrent then tlog("file loaded: %s (%s)", tostring(media_name()), hash and "torrent stream" or "not a torrent stream") end
    if role ~= "join" then
        if check and check.hash ~= hash then stop_check() end
        if check_after_pick and check_after_pick.hash == hash and check_after_pick.i == index then start_check() end
        check_after_pick = nil
    end
    refresh_menu()
end)

mp.register_event("start-file", function()
    loading_since = mp.get_time()
    -- An opened magnet or .torrent has turned into the torrent's files: its own entry goes.
    if not next(replaced) then return end
    local pos = mp.get_property_number("playlist-pos", -1)
    local list = mp.get_property_native("playlist") or {}
    for i = #list, 1, -1 do
        if replaced[list[i].filename] and i - 1 ~= pos then
            replaced[list[i].filename] = nil
            mp.commandv("playlist-remove", tostring(i - 1))
        end
    end
end)
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
        send("host", { t = "status", file = media_name(), pos = mp.get_property_number("time-pos"),
                       paused = mp.get_property_native("pause"), rtt = rtt })
        if check then send("host", { t = "check", r = check_result() }) end
        if status == "connected" and mp.get_time() - last_rx > 6 then
            end_nudge()
            set_status("lost")
            osd(T("lost"))
        end
    end
    preload_next()
    update_panel()
end)

mp.register_event("shutdown", stop)
publish()
