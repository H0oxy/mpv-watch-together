-- Which subtitle and audio files of a torrent belong to which video, whatever the release's layout:
-- names are compared by what tells files apart, not by fixed words (docs/torrent.md, Extra tracks).
-- Pure Lua, no mpv calls, so tests\tracks.lua can run it on file lists alone.
local M = {}

local function set(s)
    local t = {}
    for w in s:gmatch("%S+") do t[w] = true end
    return t
end

M.VIDEO = set("mkv mp4 avi webm m4v mov ts m2ts wmv flv mpg mpeg ogv 3gp")
local SUB = set("srt ass ssa vtt sup smi")
local AUDIO = set("mka aac ac3 eac3 dts dtshd flac mp3 mp2 opus ogg oga m4a wav thd truehd wma")
local FONT = set("ttf otf ttc")
M.FONT = FONT

function M.ext(name) return (name:match("%.([^./\\]+)$") or ""):lower() end

function M.kind(name)
    local e = M.ext(name)
    return M.VIDEO[e] and "video" or SUB[e] and "sub" or AUDIO[e] and "audio" or FONT[e] and "font" or nil
end

-- ASCII and Russian letters to lower case (string.lower knows bytes only).
local function lower(s)
    s = s:lower():gsub("\208([\144-\175])", function(c)
        local b = c:byte()
        if b < 160 then return "\208" .. string.char(b + 32) end
        return "\209" .. string.char(b - 32)
    end)
    return (s:gsub("\208\129", "\209\145"))  -- Ё
end

-- Runs of letters and digits (any non-ASCII byte counts as a letter), lower case. A CRC like "[A1B2C3D4]" is no
-- part of a name.
local function chunks(s)
    local out = {}
    for c in lower(s):gmatch("[%w\128-\255]+") do
        if not (#c == 8 and c:match("^%x+$") and c:match("%d") and c:match("%a")) then out[#out + 1] = c end
    end
    return out
end

-- Words and numbers in order: "S01E02" is s 1 e 2, "01" and "1" are the same number. A number right after
-- letters also gives a pair, "s:1" "e:2", which tells S01E02 from S02E01 (the same numbers otherwise).
local function tokens(s)
    local out = {}
    for _, c in ipairs(chunks(s)) do
        local pos, word = 1, nil
        while pos <= #c do
            local d = c:match("^%d+", pos)
            if d then
                local n = d:gsub("^0+(%d)", "%1")
                out[#out + 1] = n
                if word then out[#out + 1] = word .. ":" .. n end
                pos, word = pos + #d, nil
            else
                word = c:match("^[^%d]+", pos)
                out[#out + 1] = word
                pos = pos + #word
            end
        end
    end
    return out
end
M.tokens = tokens

local function is_num(t) return t:match("^%d+$") ~= nil end

local function bag(list)
    local b = {}
    for _, t in ipairs(list) do b[t] = (b[t] or 0) + 1 end
    return b
end

-- What every bag of the list has (the smallest count of each token).
local function common(bags)
    local c
    for _, b in ipairs(bags) do
        if not c then
            c = {}
            for t, n in pairs(b) do c[t] = n end
        else
            for t, n in pairs(c) do c[t] = math.min(n, b[t] or 0) end
        end
    end
    return c or {}
end

local function minus(a, b)
    local d = {}
    for t, n in pairs(a) do
        local left = n - (b[t] or 0)
        if left > 0 then d[t] = left end
    end
    return d
end

local function dir_of(path) return path:match("^(.*)/[^/]*$") or "" end
local function stem(name) return (name:gsub("%.[^.]*$", "")) end
local function under(path, dir) return dir == "" or path:sub(1, #dir + 1) == dir .. "/" end

-- Language words. Two-letter codes count only as the last part of a file name ("x.ru.srt"): elsewhere "it"
-- or "de" are ordinary words of a title.
local LANG = {
    rus = "ru", russian = "ru", ["рус"] = "ru", ["русский"] = "ru", ["русская"] = "ru", ["русские"] = "ru",
    eng = "en", english = "en", ["англ"] = "en", ["английский"] = "en",
    jpn = "ja", jap = "ja", japanese = "ja", ["яп"] = "ja", ["японский"] = "ja",
    ukr = "uk", ukrainian = "uk", ["укр"] = "uk", ["украинский"] = "uk",
    ger = "de", deu = "de", german = "de", fre = "fr", fra = "fr", french = "fr", spa = "es", spanish = "es",
    ita = "it", italian = "it", kor = "ko", korean = "ko", chi = "zh", chs = "zh", cht = "zh", zho = "zh",
    chinese = "zh", por = "pt", portuguese = "pt", pol = "pl", polish = "pl",
}
local LANG2 = set("ru en ja uk de fr es it ko zh pt pl")

local function lang_word(w)
    if LANG[w] then return LANG[w] end
    -- RusSub, EngSubs, RusSound, RusDub ...
    local p = w:match("^(%a%a%a)subs?$") or w:match("^(%a%a%a)sound$") or w:match("^(%a%a%a)dub$")
              or w:match("^(%a%a%a)audio$") or w:match("^(%a%a%a)voice$")
    return p and LANG[p]
end

-- Russian dubbing and voice-over studios, written in Latin letters (a Cyrillic name is Russian anyway).
-- shortcut: a fixed list, never complete; a track without a known name still comes first if it is external.
local STUDIOS = {
    "LostFilm", "NewStudio", "NovaFilm", "Novamedia", "AlexFilm", "Jaskier", "Good People", "BaibaKo", "Baibaco",
    "Amedia", "ColdFilm", "Kerob", "HDRezka", "Rezka", "Red Head Sound", "RedHead Sound", "IdeaFilm", "Gears Media",
    "SunShine Studio", "Profix Media", "AvePremier", "AveBrasil", "Kravec", "Kubik v Kube", "Kurazh Bambey",
    "Kirillica", "TVShows", "HamsterStudio", "Hamster Studio", "ViruseProject", "Ozz", "LE-Production",
    "Lizard Cinema", "LeDoyen", "Pazl Voice", "VideoFilm", "GeneralFilm", "Jetvis", "Pifagor", "Nevafilm",
    "Mosfilm Master", "SV-Dubl", "Selena International", "Goblin", "Puchkov", "Gavrilov", "Volodarsky", "Mikhalev",
    "Serbin", "Zhivov", "Yesarev", "Dohalov", "Kartsev", "Vizgunov", "Gorchakov", "Flarrow Films", "Kinopoisk",
    "Okko", "Wink", "KION", "ivi", "DubLik", "Kineko", "Sound Film", "SlothSound", "RuDub", "Riddle Space",
    "OnWave", "Light Breeze", "Light Fox", "KiraiMedia", "SoftBox", "STEPonee", "Green Tea", "JoyStudio",
    "HighHopes", "Ultradox",
    -- anime
    "AniLibria", "AniDub", "AnimeVost", "SHIZA Project", "SHIZA", "StudioBand", "Studio Band", "Reanimedia",
    "RuAnime", "DEEP", "Deep Studio", "SovetRomantica", "Sovet Romantica", "Dream Cast", "JAM Club", "AniStar",
    "AniMaunt", "AniRise", "Silver AniAge", "FreeDub", "Onibaku", "Kansai Studio", "Kansai", "AniMedia", "AniFilm",
    "AniBaza", "DubClub", "VoicePower", "Amazing Dubbing", "LightFamily", "FumoDub", "KoeKak", "AniCore",
    "Animakima", "DubNet", "AniVoice", "TOPSound", "DreamDub", "AnimeReactor", "Persona99", "Ancord", "AniPlay",
    "Mega-Anime",
}
local STUDIO_SEQ, STUDIO_JOINED = {}, {}
for _, s in ipairs(STUDIOS) do
    local t = tokens(s)
    STUDIO_SEQ[#STUDIO_SEQ + 1] = " " .. table.concat(t, " ") .. " "
    STUDIO_JOINED[table.concat(t)] = true
end

local function studio_in(text)
    local seq = " " .. table.concat(tokens(text), " ") .. " "
    for _, c in ipairs(chunks(text)) do if STUDIO_JOINED[c] then return true end end
    for _, s in ipairs(STUDIO_SEQ) do if seq:find(s, 1, true) then return true end end
    return false
end

local NOT_VOICE = set("commentary commentaries comments комментарии комментарий original оригинал")
local NOT_TRACK = set("ost soundtrack soundtracks саундтрек music музыка")  -- a soundtrack album, no track of the video

-- What a track shows in mpv and which language it is in, from its folders below the videos' folder (scope)
-- and the part of its name the video lacks.
local function describe(c, v, kind_dirs)
    local rel = c.dir:sub(#c.scope + 1):gsub("^/", "")
    local segs = {}
    for s in rel:gmatch("[^/]+") do segs[#segs + 1] = s end
    -- Folders every track of this kind sits in ("Rus Sound", "Озвучки", whatever the name) tell nothing apart.
    local parts = {}
    for _, s in ipairs(segs) do if not kind_dirs[s] then parts[#parts + 1] = s end end
    local vb, tail = bag(tokens(v.name)), {}
    for raw in stem(c.name):gmatch("[^%s%._%-%[%]%(%)]+") do
        -- A word of its own ("rus", "LostFilm"); "2x01" has only a letter and numbers.
        local own = false
        for _, t in ipairs(tokens(raw)) do
            if not vb[t] and not is_num(t) and #t > 1 and not t:find(":", 1, true) then own = true end
        end
        if own then tail[#tail + 1] = raw end
    end
    -- One studio's folder is shared by all its tracks, yet it is the best name they have.
    if #parts == 0 and #tail == 0 and #segs > 0 then parts = { segs[#segs] } end
    local title = table.concat(parts, " / ")
    if #tail > 0 then title = (title ~= "" and title .. " · " or "") .. table.concat(tail, " ") end
    if title == "" then title = stem(c.name) end
    if #title > 120 then title = title:sub(1, 120):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "…" end

    local text = table.concat(parts, " ") .. " " .. table.concat(tail, " ")
    local lang
    local words = chunks(stem(c.name))
    if LANG2[words[#words] or ""] then lang = words[#words] end
    -- The nearest language word wins: the name's own part, then folders from the nearest up.
    for _, w in ipairs(chunks(table.concat(tail, " "))) do lang = lang or lang_word(w) end
    local dirs = {}
    for s in c.dir:gmatch("[^/]+") do table.insert(dirs, 1, s) end
    for _, s in ipairs(dirs) do
        for _, w in ipairs(chunks(s)) do lang = lang or lang_word(w) end
    end
    if not lang and (studio_in(text) or text:find("[\208\209]")) then lang = "ru" end
    local voice = true
    for _, w in ipairs(chunks(text)) do if NOT_VOICE[w] then voice = false end end
    return title, lang, voice
end

-- files: {{i, path, name, length}}. Returns
--   extras: video file i -> {{i, name, path, length, kind, title, lang, voice}}
--   fonts: the font files, for ASS subtitles.
function M.attach(files)
    local videos, comps, fonts = {}, {}, {}
    for _, f in ipairs(files) do
        local path = f.path:gsub("\\", "/")
        local k = M.kind(f.name)
        local e = { i = f.i, name = f.name, path = path, length = f.length, kind = k, dir = dir_of(path) }
        e.bag = bag(tokens(path:gsub("%.[^./]*$", "")))
        if k == "video" then videos[#videos + 1] = e
        elseif k == "font" then fonts[#fonts + 1] = f
        elseif k then
            comps[#comps + 1] = e
        end
    end
    local extras = {}
    if #videos == 0 or #comps == 0 then return extras, fonts end
    -- An "OST" folder holds an album, not tracks of the video (unless the videos' own path says "Music").
    for k = #comps, 1, -1 do
        for _, w in ipairs(chunks(comps[k].dir)) do
            if NOT_TRACK[w] and not videos[1].bag[w] then table.remove(comps, k) break end
        end
    end
    if #comps == 0 then return extras, fonts end
    -- shortcut: a huge torrent would make this slow (every track against every video); such a torrent gets
    -- no extra tracks. Raise the limit if one ever matters.
    if #videos * #comps > 400000 then return extras, fonts end

    -- The nearest folder above a track that holds videos; only those videos can be its own.
    local scopes = {}
    local function scope_of(dir)
        while true do
            local s = scopes[dir]
            if s == nil then
                local vs = {}
                for _, v in ipairs(videos) do if under(v.path, dir) then vs[#vs + 1] = v end end
                if #vs > 0 then
                    local bags = {}
                    for k, v in ipairs(vs) do bags[k] = v.bag end
                    local cm = common(bags)
                    for _, v in ipairs(vs) do v.own = v.own or {}; v.own[dir] = minus(v.bag, cm) end
                    s = { dir = dir, videos = vs, common = cm }
                else
                    s = false
                end
                scopes[dir] = s
            end
            if s then return s end
            if dir == "" then return nil end
            dir = dir_of(dir)
        end
    end

    -- Tracks of one kind in one folder: what they share is no part of the episode.
    local groups = {}
    for _, c in ipairs(comps) do
        local key = c.kind .. "\0" .. c.dir
        groups[key] = groups[key] or {}
        table.insert(groups[key], c)
    end
    for _, g in pairs(groups) do
        if #g > 1 then
            local bags = {}
            for k, c in ipairs(g) do bags[k] = c.bag end
            local cm = common(bags)
            for _, c in ipairs(g) do c.own = minus(c.bag, cm) end
        end
    end
    local function numbers(b)
        local n = {}
        for t, k in pairs(b) do if is_num(t) then n[t] = k end end
        return n
    end

    local placed = {}
    for _, c in ipairs(comps) do
        local s = scope_of(c.dir)
        if s then
            c.scope = s.dir
            local best
            if #s.videos == 1 then
                best = s.videos[1]
            else
                -- A lone track, or a folder of tracks for one episode (rus + eng), has no neighbours to compare
                -- with: what all the videos share is taken off instead ("Show S01").
                local own = c.own
                local nums = own and numbers(own) or {}
                if not next(nums) then
                    own = minus(c.bag, s.common)
                    nums = numbers(own)
                end
                if next(nums) then
                    local top, tie = nil, false
                    -- Present or not, not how often: a season number is often in the folder and the name
                    -- of a video ("Season_02/s02e01") but once in a subtitle's ("S02E01.srt").
                    for _, v in ipairs(s.videos) do
                        local vown, fits = v.own[s.dir], true
                        for t in pairs(nums) do if not vown[t] then fits = false end end
                        if fits then
                            -- What sets the video apart should be in the track's name. Numbers first (season,
                            -- episode); words ("Sp", a title, the track's "rus") only decide between equals.
                            local nscore, wscore = 0, 0
                            for t in pairs(vown) do
                                local d = c.bag[t] and 1 or -1
                                if is_num(t) then nscore = nscore + d else wscore = wscore + d end
                            end
                            for t in pairs(own) do
                                if not is_num(t) then wscore = wscore + (v.bag[t] and 1 or -1) end
                            end
                            local score = nscore * 10000 + wscore
                            if not top or score > top then top, best, tie = score, v, false
                            elseif score == top then tie = true end
                        end
                    end
                    if tie then best = nil end
                end
            end
            if best then placed[#placed + 1] = { c = c, v = best } end
        end
    end

    -- Folder names every placed track of a kind shares, per scope.
    local seen = {}
    for _, p in ipairs(placed) do
        local key = p.c.kind .. "\0" .. p.c.scope
        local rel = p.c.dir:sub(#p.c.scope + 1)
        local names = {}
        for s in rel:gmatch("[^/]+") do names[s] = true end
        if not seen[key] then
            seen[key] = names
        else
            for s in pairs(seen[key]) do if not names[s] then seen[key][s] = nil end end
        end
    end
    for _, p in ipairs(placed) do
        local c = p.c
        local title, lang, voice = describe(c, p.v, seen[c.kind .. "\0" .. c.scope])
        extras[p.v.i] = extras[p.v.i] or {}
        table.insert(extras[p.v.i], { i = c.i, name = c.name, path = c.path, length = c.length, kind = c.kind,
                                      title = title, lang = lang, voice = voice })
    end
    for _, list in pairs(extras) do
        table.sort(list, function(x, y) return x.path < y.path end)
    end
    return extras, fonts
end

-- The episode chooser shows one folder of the torrent at a time: its subfolders (in the order of their first
-- file) and its own files. A folder holding nothing but one subfolder is skipped into.
-- files: the sorted playlist ({path, length}); dir: "" or "a/b/". Entries: {k = index in files, name, size}
-- or {dir, name, count, size}.
function M.folder(files, dir)
    local entries, seen = {}, {}
    for k, f in ipairs(files) do
        if f.path:sub(1, #dir) == dir then
            local rest = f.path:sub(#dir + 1)
            local sub = rest:match("^([^/]+)/")
            if sub then
                local e = seen[sub]
                if not e then
                    e = { dir = dir .. sub .. "/", name = sub, count = 0, size = 0 }
                    seen[sub] = e
                    entries[#entries + 1] = e
                end
                e.count, e.size = e.count + 1, e.size + (f.length or 0)
            else
                entries[#entries + 1] = { k = k, name = rest, size = f.length or 0 }
            end
        end
    end
    if #entries == 1 and entries[1].dir then return M.folder(files, entries[1].dir) end
    return entries, dir
end

-- Names as the chooser shows them, whatever their length: the start all of them share is dropped up to where
-- a word ends ("Show - 01", "Show - 02" -> "01", "02"), and a name still longer than max chars loses its
-- middle, so both its start and its end (where the episode number is when titles differ) stay in view.
function M.short_names(names, max)
    local p = #names > 1 and names[1] or ""
    for k = 2, #names do
        local n, i = names[k], 0
        while i < #p and p:byte(i + 1) == n:byte(i + 1) do i = i + 1 end
        p = p:sub(1, i)
    end
    while #p > 0 and (p:byte(#p) >= 128 or p:sub(-1):match("%w")) do p = p:sub(1, -2) end
    for _, n in ipairs(names) do if #n <= #p then p = "" end end
    local out = {}
    for k, n in ipairs(names) do
        local chars = {}
        for ch in n:sub(#p + 1):gmatch("[^\128-\191][\128-\191]*") do chars[#chars + 1] = ch end
        if #chars > max then
            local head = math.ceil((max - 1) / 2)
            out[k] = table.concat(chars, "", 1, head) .. "…" .. table.concat(chars, "", #chars - (max - 1 - head) + 1)
        else
            out[k] = table.concat(chars)
        end
    end
    return out
end

return M
