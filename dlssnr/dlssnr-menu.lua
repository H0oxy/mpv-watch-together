-- Context menu, keys and OSD messages for the dlssnr C plugin (dlssnr.dll), which does the work.
-- It publishes user-data/dlssnr/{enabled,style,intensity,status,info} and takes script-messages
-- dlssnr-toggle | dlssnr-style <n> | dlssnr-intensity <0..1>.
local mp = require "mp"
local utils = require "mp.utils"

local STRINGS = {
    ru = {
        enabled = "Включён",
        strength = "Сила: %d%%",
        style = "Стиль (эксперимент): %d",
        starting = "Запускается…",
        on = "вкл", off = "выкл",
        summary = "DLSS NR: %s · сила %d%% · стиль %d",
        cost = " · %s мс на кадр при %s",
        ready = "DLSS NR включён. Управление: правый клик → DLSS NR, Ctrl+N",
        ["error-init"] = "DLSS NR не запустился, подробности в %%TEMP%%\\dlssnr.log",
        ["error-process"] = "DLSS NR остановлен из-за ошибки, подробности в %%TEMP%%\\dlssnr.log",
        ["error-format"] = "DLSS NR: нужен 8-битный вывод (--d3d11-output-format=rgba8)",
        ["error-device"] = "DLSS NR: mpv пересоздал вывод видео, перезапусти mpv",
        ["error-hook"] = "DLSS NR: не удалось подключиться к выводу видео",
    },
    en = {
        enabled = "Enabled",
        strength = "Strength: %d%%",
        style = "Style (experimental): %d",
        starting = "Starting…",
        on = "on", off = "off",
        summary = "DLSS NR: %s · strength %d%% · style %d",
        cost = " · %s ms per frame at %s",
        ready = "DLSS NR is on. Controls: right click → DLSS NR, Ctrl+N",
        ["error-init"] = "DLSS NR did not start, details in %%TEMP%%\\dlssnr.log",
        ["error-process"] = "DLSS NR stopped after an error, details in %%TEMP%%\\dlssnr.log",
        ["error-format"] = "DLSS NR needs 8-bit output (--d3d11-output-format=rgba8)",
        ["error-device"] = "DLSS NR: mpv recreated its video output, restart mpv",
        ["error-hook"] = "DLSS NR could not attach to the video output",
    },
}
local lang = "ru"
local function T(key, ...) return string.format(STRINGS[lang][key] or STRINGS.en[key] or key, ...) end

-- Native: as a string, user-data comes back JSON-quoted ("yes" with the quotes).
local function get(name) return mp.get_property_native("user-data/dlssnr/" .. name) end
local function enabled() return get("enabled") == "yes" end
local function intensity() return tonumber(get("intensity")) or 1 end
local function style() return tonumber(get("style")) or 0 end
local function status() return (get("status") or ""):match("^(%S+)") or "" end

local function menu_item()
    local items = {}
    local st = status()
    if st:match("^error") then
        items[#items + 1] = { title = T(st), state = { "disabled" } }
        return { type = "submenu", title = "DLSS NR", submenu = items }
    end
    if st == "starting" and enabled() then items[#items + 1] = { title = T("starting"), state = { "disabled" } } end
    items[#items + 1] = { title = T("enabled"), cmd = "script-message dlssnr-toggle", state = enabled() and { "checked" } or {} }
    local strength = {}
    for _, v in ipairs({ 0.25, 0.5, 0.75, 1 }) do
        strength[#strength + 1] = { title = string.format("%d%%", v * 100), cmd = "script-message dlssnr-intensity " .. v,
            state = math.abs(v - intensity()) < 0.01 and { "checked" } or {} }
    end
    items[#items + 1] = { type = "submenu", title = T("strength", math.floor(intensity() * 100 + 0.5)), submenu = strength }
    local styles = {}
    for v = 0, 2 do
        styles[#styles + 1] = { title = tostring(v), cmd = "script-message dlssnr-style " .. v, state = v == style() and { "checked" } or {} }
    end
    items[#items + 1] = { type = "submenu", title = T("style", style()), submenu = styles }
    return { type = "submenu", title = "DLSS NR", submenu = items }
end

local function has_cmd(item, prefix)
    for _, sub in ipairs(item.submenu or {}) do
        if type(sub.cmd) == "string" and sub.cmd:sub(1, #prefix) == prefix then return true end
        if sub.type == "submenu" and has_cmd(sub, prefix) then return true end
    end
    return false
end
-- Ours is found by its title: in the error state it has no commands.
local function is_ours(item) return item.type == "submenu" and item.title == "DLSS NR" end

-- select.lua (and watch-together) rewrite menu-data, so put ours back each time; right after the
-- watch-together submenu when there is one.
local function refresh_menu()
    if not get("status") then return end -- dlssnr.dll is not loaded
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
    local at = 1
    for i, item in ipairs(data) do
        if has_cmd(item, "script-message watch-together-") then at = i + 1 break end
    end
    table.insert(data, at, mine)
    mp.set_property_native("menu-data", data)
end

local function summary()
    local text = T("summary", enabled() and T("on") or T("off"), math.floor(intensity() * 100 + 0.5), style())
    local size, ms = (get("info") or ""):match("^(%S+) (%S+)$")
    if enabled() and ms and tonumber(ms) and tonumber(ms) > 0 then text = text .. T("cost", ms, (size:gsub("x", "×"))) end
    return text
end

-- The first value of each property comes from startup, later ones from the user.
local seen = {}
local function on_setting(name)
    if seen[name] then mp.osd_message(summary(), 3) end
    seen[name] = true
    refresh_menu()
end
for _, name in ipairs({ "enabled", "style", "intensity" }) do
    mp.observe_property("user-data/dlssnr/" .. name, "native", function(n, v) if v then on_setting(n) end end)
end
mp.observe_property("user-data/dlssnr/status", "native", function(_, v)
    if type(v) ~= "string" then return end
    local st = v:match("^(%S+)")
    if st == "on" then mp.osd_message(T("ready"), 4)
    elseif st:match("^error") then mp.osd_message(T(st), 8) end
    refresh_menu()
end)
mp.observe_property("menu-data", "native", refresh_menu)
mp.observe_property("user-data/watch-together/lang", "native", function(_, v)
    if v == "ru" or v == "en" then lang = v; refresh_menu() end
end)

-- Both layouts: with the Russian one mpv reports Ctrl+N as Ctrl+т.
local function toggle() mp.commandv("script-message", "dlssnr-toggle") end
local function next_style() mp.commandv("script-message", "dlssnr-style", tostring((style() + 1) % 3)) end
mp.add_key_binding("Ctrl+n", "toggle", toggle)
mp.add_key_binding("Ctrl+т", "toggle-ru", toggle)
mp.add_key_binding("Ctrl+N", "next-style", next_style)
mp.add_key_binding("Ctrl+Т", "next-style-ru", next_style)
