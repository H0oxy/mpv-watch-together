-- Self-check of watch-together/tracks.lua on real torrent layouts, run inside mpv by tests\tracks.ps1.
-- Each case is a torrent's file list; every extra file names the video it must go with (false: none),
-- and optionally its title and language.
package.path = debug.getinfo(1, "S").source:sub(2):gsub("[^/\\]+$", "") .. "../watch-together/?.lua;" .. package.path
local tracks = require("tracks")

local failures = 0
local function check(name, ok, detail)
    if not ok then failures = failures + 1 end
    print(string.format("[%s] %s %s", ok and "PASS" or "FAIL", name, detail or ""))
end

-- videos: list of paths; extras: {path, video path | false, title, lang}
local function case(name, videos, extras, fonts)
    local files = {}
    for _, p in ipairs(videos) do files[#files + 1] = p end
    for _, e in ipairs(extras) do files[#files + 1] = e[1] end
    for _, p in ipairs(fonts or {}) do files[#files + 1] = p end
    local list, by_i = {}, {}
    for i, p in ipairs(files) do
        list[i] = { i = i, path = p, name = p:match("[^/]+$"), length = 1 }
        by_i[i] = p
    end
    local got, got_fonts = tracks.attach(list)
    local placed = {}
    for vi, l in pairs(got) do
        for _, e in ipairs(l) do placed[e.path] = { video = by_i[vi], title = e.title, lang = e.lang, voice = e.voice } end
    end
    local bad = {}
    for _, e in ipairs(extras) do
        local p = placed[e[1]]
        local want = e[2]
        if want == false then
            if p then bad[#bad + 1] = e[1] .. " -> " .. p.video .. " (wanted none)" end
        elseif not p or p.video ~= want then
            bad[#bad + 1] = e[1] .. " -> " .. tostring(p and p.video) .. " (wanted " .. want .. ")"
        else
            if e[3] and p.title ~= e[3] then bad[#bad + 1] = e[1] .. ": title " .. tostring(p.title) .. " (wanted " .. e[3] .. ")" end
            if e[4] ~= nil and p.lang ~= (e[4] or nil) then
                bad[#bad + 1] = e[1] .. ": lang " .. tostring(p.lang) .. " (wanted " .. tostring(e[4]) .. ")"
            end
            if e[5] ~= nil and p.voice ~= e[5] then bad[#bad + 1] = e[1] .. ": voice " .. tostring(p.voice) end
        end
    end
    if fonts and #got_fonts ~= #fonts then bad[#bad + 1] = "fonts: " .. #got_fonts .. " (wanted " .. #fonts .. ")" end
    check(name, #bad == 0, table.concat(bad, "; "))
end

-- Ani Tore TV 2: one studio's voice-over and two kinds of subtitles in folders, files named like the videos;
-- specials "Sp 1" must not be taken for episode 1.
do
    local root, videos, extras = "Ani Tore TV 2/", {}, {}
    local eps = {}
    for n = 1, 12 do eps[#eps + 1] = string.format("Ani Tore TV 2 %02d серия", n) end
    for n = 1, 6 do eps[#eps + 1] = "Ani Tore TV 2 Sp " .. n .. " серия" end
    for _, s in ipairs(eps) do
        videos[#videos + 1] = root .. s .. ".mkv"
        extras[#extras + 1] = { root .. "Rus Sound/Anidub/" .. s .. ".mka", root .. s .. ".mkv", "Anidub", "ru" }
        extras[#extras + 1] = { root .. "Rus Subs/Надписи/" .. s .. ".ass", root .. s .. ".mkv", "Надписи", "ru" }
        extras[#extras + 1] = { root .. "Rus Subs/Полные/" .. s .. ".ass", root .. s .. ".mkv", "Полные", "ru" }
    end
    videos[#videos + 1] = root .. "Bonus/NCOP1.mkv"
    videos[#videos + 1] = root .. "Bonus/NCED1.mkv"
    case("Ani Tore TV 2: studio and subtitle folders, specials apart", videos, extras,
         { root .. "Rus Subs/Шрифты/Font A.ttf", root .. "Rus Subs/Шрифты/FONT-B.otf" })
end

-- Cyberpunk: subtitles next to the videos (".ru.srt"), voice-overs in studio folders named only by number,
-- or with "2x01". The constant "S02" and "DDP5.1" must not count as episode numbers.
do
    local root = "Cyberpunk.Edgerunners.S02.2160p.NF.WEB-DL.DDP5.1.DV.HDR.H.265-NTb/"
    local videos, extras = {}, {}
    for n = 1, 10 do
        local v = root .. string.format("Cyberpunk.Edgerunners.S02E%02d-NTb.mp4", n)
        videos[#videos + 1] = v
        extras[#extras + 1] = { root .. string.format("Cyberpunk.Edgerunners.S02E%02d-NTb.ru.srt", n), v, "ru", "ru" }
        extras[#extras + 1] = { root .. string.format("Audio/LostFilm/E%02d.mka", n), v, "LostFilm", "ru" }
        extras[#extras + 1] = { root .. string.format("Audio/Flarrow Films/Cyberpunk Edgerunners 2x%02d.ac3", n), v,
                                "Flarrow Films", "ru" }
    end
    case("Cyberpunk: flat subtitles, numbered studio tracks", videos, extras)
end

-- The Body: only videos and English and Russian subtitles in one "Subs" folder.
do
    local root = "The.Body.2026.S01.1080p/"
    local videos, extras = {}, {}
    for n = 1, 8 do
        local v = root .. string.format("The.Body.2026.S01E%02d.mkv", n)
        videos[#videos + 1] = v
        extras[#extras + 1] = { root .. string.format("Subs/The.Body.2026.S01E%02d.rus.srt", n), v, "rus", "ru" }
        extras[#extras + 1] = { root .. string.format("Subs/The.Body.2026.S01E%02d.eng.srt", n), v, "eng", "en" }
    end
    case("The Body: rus and eng subtitles in one folder", videos, extras)
end

-- The Mentalist: a folder per season, episode titles in the video names only, subtitles per season without
-- titles, and a shared "Subs" folder for season 2.
do
    local root = "The.Mentalist.2008-2015.web-dlrip_[teko]/"
    local s1 = { "Pilot", "Red.Hair.and.Silver.Tape", "Red.Tide", "Ladies.in.Red", "Redwood", "Red-Handed",
                 "Seeing.Red", "The.Thin.Red.Line", "Flame.Red", "Red.Brick.and.Ivy", "Red.John's.Friends" }
    local s2 = { "Redemption", "The.Scarlet.Letter", "Red.Badge", "Redline", "Red.Herring.2" }
    local videos, extras = {}, {}
    for n, t in ipairs(s1) do
        local v = root .. string.format("Season_01/s01e%02d_%s.avi", n, t)
        videos[#videos + 1] = v
        extras[#extras + 1] = { root .. string.format("Season_01/Subs/s01e%02d.srt", n), v }
    end
    for n, t in ipairs(s2) do
        local v = root .. string.format("Season_02/s02e%02d_%s.avi", n, t)
        videos[#videos + 1] = v
        extras[#extras + 1] = { root .. string.format("Subs/The.Mentalist.S02E%02d.rus.srt", n), v, nil, "ru" }
    end
    case("The Mentalist: season folders, titled episodes", videos, extras)
end

-- A film: every track of the release is its own, wherever it lies; an OST album is not.
do
    local root = "Movie.2020.1080p.BluRay/"
    local v = root .. "Movie.2020.1080p.BluRay.mkv"
    case("A film: all tracks belong to it, OST does not", { v }, {
        { root .. "Subs/English.srt", v, "English", "en" },
        { root .. "Subs/Russian.srt", v, "Russian", "ru" },
        { root .. "Audio/Movie.2020.1080p.BluRay.Commentary.ac3", v, "Commentary", false, false },
        { root .. "Audio/Movie.2020.1080p.BluRay.Rus.LostFilm.mka", v, "Rus LostFilm", "ru", true },
        { root .. "OST/01 Main Theme.mp3", false },
        { root .. "OST/02 End Credits.mp3", false },
    })
end

-- A folder per episode, the same file names in each.
do
    case("A folder per episode", { "Show/Ep01/video.mkv", "Show/Ep02/video.mkv" }, {
        { "Show/Ep01/rus.srt", "Show/Ep01/video.mkv", "rus", "ru" },
        { "Show/Ep02/rus.srt", "Show/Ep02/video.mkv", "rus", "ru" },
        { "Show/Ep02/Sound/Jaskier.mka", "Show/Ep02/video.mkv", "Jaskier", "ru" },
    })
end

-- Two studios side by side in one folder, told apart by a tag in the name.
do
    local v1, v2 = "Show/Show 01.mkv", "Show/Show 02.mkv"
    case("Two studios in one folder", { v1, v2 }, {
        { "Show/Audio/Show 01 [AniLibria].mka", v1, "AniLibria", "ru" },
        { "Show/Audio/Show 01 [Anidub].mka", v1, "Anidub", "ru" },
        { "Show/Audio/Show 02 [AniLibria].mka", v2, "AniLibria", "ru" },
        { "Show/Audio/Show 02 [Anidub].mka", v2, "Anidub", "ru" },
    })
end

-- A folder of voice-overs in many languages: the shared folder's Cyrillic name says nothing.
do
    local v1, v2 = "S/Show.S01E01.mkv", "S/Show.S01E02.mkv"
    case("Voice-overs of all languages under one Cyrillic folder", { v1, v2 }, {
        { "S/Озвучки/ENG/Show.S01E01.mka", v1, "ENG", "en" },
        { "S/Озвучки/ENG/Show.S01E02.mka", v2, "ENG", "en" },
        { "S/Озвучки/Кубик в Кубе/Show.S01E01.mka", v1, "Кубик в Кубе", "ru" },
        { "S/Озвучки/Кубик в Кубе/Show.S01E02.mka", v2, "Кубик в Кубе", "ru" },
        { "S/Озвучки/Netflix/Show.S01E01.mka", v1, "Netflix", false },
        { "S/Озвучки/Netflix/Show.S01E02.mka", v2, "Netflix", false },
    })
end

-- A lone subtitle file of one episode, and one for two episodes at once in a folder.
do
    local v = {}
    for n = 1, 6 do v[n] = string.format("Show.S01.1080p/Show.S01E%02d.1080p.mkv", n) end
    case("A lone subtitle of one episode", v, {
        { "Show.S01.1080p/Subs/Show.S01E05.rus.srt", v[5], "Subs · rus", "ru" },
        { "Show.S01.1080p/Extra/Show.S01E03.rus.srt", v[3] },
        { "Show.S01.1080p/Extra/Show.S01E03.eng.srt", v[3] },
    })
end

-- A fansub release: group tag, resolution and a CRC in the video names, subtitles named otherwise.
do
    local v, extras = {}, {}
    local crc = { "A1B2C3D4", "0F9E8D7C", "12AB34CD", "DEADBEEF" }
    for n = 1, 4 do
        v[n] = string.format("[SubsPlease] Frieren - %02d (1080p) [%s].mkv", n, crc[n])
        extras[#extras + 1] = { string.format("Subs/Frieren_%02d.ass", n), v[n], "Subs", nil }
    end
    case("A fansub release with CRCs, subtitles named otherwise", v, extras)
end

-- Two seasons in one folder: episode 5 of season 2 is not episode 5 of season 1.
do
    local v, extras = {}, {}
    for s = 1, 2 do
        for e = 1, 6 do
            v[#v + 1] = string.format("Show/Show.S%02dE%02d.mkv", s, e)
            extras[#extras + 1] = { string.format("Show/Rus/Show.S%02dE%02d.ac3", s, e), v[#v], "Rus", "ru" }
        end
    end
    case("Two seasons in one folder", v, extras)
end

-- What cannot be told: no number at all, or numbers the videos do not have. Nothing is attached.
do
    local v1, v2 = "Show/Show 13.mkv", "Show/Show 14.mkv"
    case("Unknowable: no number, or other numbering", { v1, v2 }, {
        { "Show/Subs/Full.ass", false },
        { "Show/Subs2/Show 01.ass", false },
        { "Show/Subs2/Show 02.ass", false },
    })
end

-- No videos, no extras; a torrent with no extra files.
do
    local list = { { i = 1, path = "Album/01.flac", name = "01.flac", length = 1 } }
    local got = tracks.attach(list)
    check("no videos: nothing attached", next(got) == nil)
end

-- The episode chooser: folders one at a time, names that keep the episode in view.
do
    local files = {}
    for _, p in ipairs({ "Big Show [BD]/Season 1/Big Show - S01E01 - A Very Long Episode Title That Goes On.mkv",
                         "Big Show [BD]/Season 1/Big Show - S01E02 - Another Long Title.mkv",
                         "Big Show [BD]/Season 2/Big Show - S02E01.mkv",
                         "Big Show [BD]/Movie.mkv" }) do
        files[#files + 1] = { path = p, length = 10 }
    end
    local e, dir = tracks.folder(files, "")
    check("chooser: the single top folder is skipped into", dir == "Big Show [BD]/" and #e == 3, dir)
    check("chooser: subfolders with counts, then the loose file",
          e[1].dir == "Big Show [BD]/Season 1/" and e[1].count == 2 and e[1].size == 20 and e[2].name == "Season 2" and e[3].k == 4)
    local s1 = tracks.folder(files, e[1].dir)
    check("chooser: a season's files", #s1 == 2 and s1[1].k == 1 and s1[2].k == 2)
    local function names(list, max, is_file)
        local out = tracks.short_names(list, max or 70, is_file ~= false)
        return out, table.concat(out, " | ")
    end
    local n, d = names({ s1[1].name, s1[2].name }, 20)
    check("chooser: shared start dropped, long middle cut", n[1] == "S01E01 - A…t Goes On" and n[2] == "S01E02 - A…ong Title", d)
    -- The user's release: quality tags in brackets, the same everywhere.
    local rel = {}
    for i = 1, 20 do rel[i] = string.format("%02d [WEB-DL CR 1080p AVC AAC].mkv", i) end
    n, d = names(rel)
    check("chooser: bracketed quality tags go, the number stays", n[1] == "01" and n[10] == "10" and n[20] == "20", d)
    n, d = names({ "[Group] Show - 01 [BDRip 1080p HEVC FLAC] [A1B2C3D4].mkv", "[Group] Show - 02 [BDRip 1080p HEVC FLAC] [0F9E8D7C].mkv" })
    check("chooser: group, tags and a per-file CRC go", n[1] == "01" and n[2] == "02", d)
    n, d = names({ "Show - 01 - The Start 1080p WEB-DL x265.mkv", "Show - 02 - A Sequel 1080p WEB-DL x265.mkv" })
    check("chooser: tags without brackets go when shared, episode titles stay", n[1] == "01 - The Start" and n[2] == "02 - A Sequel", d)
    n, d = names({ "Show.S01E01.1080p.WEB-DL.mkv", "Show.S01E02.1080p.WEB-DL.mkv", "Show.S01E10.1080p.WEB-DL.mkv" })
    check("chooser: dotted names", n[1] == "S01E01" and n[3] == "S01E10", d)
    n, d = names({ "Show [01].mkv", "Show [02].mkv" })
    check("chooser: a number in brackets stays", n[1] == "01" and n[2] == "02", d)
    n, d = names({ "【Group】Show 01 【1080p】.mkv", "【Group】Show 02 【1080p】.mkv" })
    check("chooser: full-width brackets go", n[1] == "01" and n[2] == "02", d)
    n, d = names({ "Серия 1.mkv", "Серия 2.mkv" })
    check("chooser: Cyrillic names", n[1] == "1" and n[2] == "2", d)
    n, d = names({ "Show [1080p].mkv", "Show [720p].mkv" })
    check("chooser: only tags differ: the names as they are, not two empty labels", n[1] == "Show [1080p]" and n[2] == "Show [720p]", d)
    n, d = names({ "Ep 1.mkv", "Ep 10.mkv" })
    check("chooser: a name that is the others' start keeps its number", n[1] == "1" and n[2] == "10", d)
    n, d = names({ "Season 1", "Season 2" }, 50, false)
    check("chooser: folders", n[1] == "1" and n[2] == "2", d)
    n, d = names({ "Only one long name here.mkv" }, 10)
    check("chooser: a single name is only cut", n[1] == "Only …here" or n[1] == "Only…here", d)
end

print(failures == 0 and "all checks passed" or (failures .. " check(s) failed"))
mp.commandv("quit", failures == 0 and "0" or "1")
