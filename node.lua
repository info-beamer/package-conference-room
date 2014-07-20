gl.setup(1280, 720)

sys.set_flag("slow_gc")

local json = require "json"
local schedule
local current_room

util.resource_loader{
    "progress.frag",
}

local white = resource.create_colored_texture(1,1,1)

util.file_watch("schedule.json", function(content)
    print("reloading schedule")
    schedule = json.decode(content)
end)

local rooms
local spacer = white

node.event("config_update", function(config)
    rooms = {}
    for idx, room in ipairs(config.rooms) do
        if room.serial == sys.get_env("SERIAL") then
            print("found my room")
            current_room = room
        end
        rooms[room.name] = room
    end
    spacer = resource.create_colored_texture(CONFIG.foreground_color.rgba())
end)

hosted_init()

local base_time = N.base_time or 0
local current_talk
local all_talks = {}
local day = 0

function get_now()
    return base_time + sys.now()
end

function check_next_talk()
    local now = get_now()
    local room_next = {}
    for idx, talk in ipairs(schedule) do
        if rooms[talk.place] and not room_next[talk.place] and talk.start_unix + 25 * 60 > now then 
            room_next[talk.place] = talk
        end
    end

    for room, talk in pairs(room_next) do
        talk.slide_lines = wrap(talk.title, 30)

        if #talk.title > 25 then
            talk.lines = wrap(talk.title, 60)
            if #talk.lines == 1 then
                talk.lines[2] = table.concat(talk.speakers, ", ")
            end
        end
    end

    if room_next[current_room.name] then
        current_talk = room_next[current_room.name]
    else
        current_talk = nil
    end

    all_talks = {}
    for room, talk in pairs(room_next) do
        if current_talk and room ~= current_talk.place then
            all_talks[#all_talks + 1] = talk
        end
    end
    table.sort(all_talks, function(a, b) 
        if a.start_unix < b.start_unix then
            return true
        elseif a.start_unix > b.start_unix then
            return false
        else
            return a.place < b.place
        end
    end)
end

function wrap(str, limit, indent, indent1)
    limit = limit or 72
    local here = 1
    local wrapped = str:gsub("(%s+)()(%S+)()", function(sp, st, word, fi)
        if fi-here > limit then
            here = st
            return "\n"..word
        end
    end)
    local splitted = {}
    for token in string.gmatch(wrapped, "[^\n]+") do
        splitted[#splitted + 1] = token
    end
    return splitted
end

local clock = (function()
    local base_time = N.base_time or 0

    local function set(time)
        base_time = tonumber(time) - sys.now()
    end

    util.data_mapper{
        ["clock/midnight"] = function(since_midnight)
            print("NEW midnight", since_midnight)
            set(since_midnight)
        end;
    }

    local function get()
        local time = (base_time + sys.now()) % 86400
        return string.format("%d:%02d", math.floor(time / 3600), math.floor(time % 3600 / 60))
    end

    return {
        get = get;
        set = set;
    }
end)()

util.data_mapper{
    ["clock/set"] = function(time)
        base_time = tonumber(time) - sys.now()
        N.base_time = base_time
        check_next_talk()
        print("UPDATED TIME", base_time)
    end;
    ["clock/day"] = function(new_day)
        day = new_day
        print("UPDATED DAY", new_day)
    end;
}

function switcher(get_screens)
    local current_idx = 0
    local current
    local current_state

    local switch = sys.now()
    local switched = sys.now()

    local blend = 0.8
    local mode = "switch"

    local old_screen
    local current_screen
    
    local screens = get_screens()

    local function prepare()
        local now = sys.now()
        if now > switch and mode == "show" then
            mode = "switch"
            switched = now

            -- snapshot old screen
            gl.clear(CONFIG.background_color.rgb_with_a(0.0))
            if current then
                current.draw(current_state)
            end
            old_screen = resource.create_snapshot()

            -- find next screen
            current_idx = current_idx + 1
            if current_idx > #screens then
                screens = get_screens()
                current_idx = 1
            end
            current = screens[current_idx]
            switch = now + current.time
            current_state = current.prepare()

            -- snapshot next screen
            gl.clear(CONFIG.background_color.rgb_with_a(0.0))
            current.draw(current_state)
            current_screen = resource.create_snapshot()
        elseif now - switched > blend and mode == "switch" then
            if current_screen then
                current_screen:dispose()
            end
            if old_screen then
                old_screen:dispose()
            end
            current_screen = nil
            old_screen = nil
            mode = "show"
        end
    end
    
    local function draw()
        local now = sys.now()

        local percent = ((now - switched) / (switch - switched)) * 3.14129 * 2 - 3.14129
        progress:use{percent = percent}
        white:draw(WIDTH-50, HEIGHT-50, WIDTH-10, HEIGHT-10)
        progress:deactivate()

        if mode == "switch" then
            local progress = (now - switched) / blend
            gl.pushMatrix()
            gl.translate(WIDTH/2, 0)
            if progress < 0.5 then
                gl.rotate(180 * progress, 0, 1, 0)
                gl.translate(-WIDTH/2, 0)
                old_screen:draw(0, 0, WIDTH, HEIGHT)
            else
                gl.rotate(180 + 180 * progress, 0, 1, 0)
                gl.translate(-WIDTH/2, 0)
                current_screen:draw(0, 0, WIDTH, HEIGHT)
            end
            gl.popMatrix()
        else 
            current.draw(current_state)
        end
    end
    return {
        prepare = prepare;
        draw = draw;
    }
end

local content = switcher(function() 
    return {{
        time = CONFIG.other_rooms,
        prepare = function()
            local content = {}

            local function add_content(func)
                content[#content+1] = func
            end

            local function mk_spacer(y)
                return function()
                    spacer:draw(0, y, WIDTH, y+2, 0.6)
                end
            end

            local function mk_talkmulti(y, talk, is_running)
                local alpha
                if is_running then
                    alpha = 0.5
                else
                    alpha = 1.0
                end

                local line_idx = 999999
                local top_line
                local bottom_line
                local function next_line()
                    line_idx = line_idx + 1
                    if line_idx > #talk.lines then
                        line_idx = 2
                        top_line = talk.lines[1]
                        bottom_line = talk.lines[2] or ""
                    else
                        top_line = bottom_line
                        bottom_line = talk.lines[line_idx]
                    end
                end

                next_line()

                local switch = sys.now() + 3

                return function()
                    CONFIG.font:write(30, y, talk.start_str, 50, CONFIG.foreground_color.rgb_with_a(alpha))
                    CONFIG.font:write(190, y, rooms[talk.place].name_short, 50, CONFIG.foreground_color.rgb_with_a(alpha))
                    CONFIG.font:write(400, y, top_line, 30, CONFIG.foreground_color.rgb_with_a(alpha))
                    CONFIG.font:write(400, y+28, bottom_line, 30, CONFIG.foreground_color.rgb_with_a(alpha*0.6))

                    if sys.now() > switch then
                        next_line()
                        switch = sys.now() + 1
                    end
                end
            end

            local function mk_talk(y, talk, is_running)
                local alpha
                if is_running then
                    alpha = 0.5
                else
                    alpha = 1.0
                end

                return function()
                    CONFIG.font:write(30, y, talk.start_str, 50, CONFIG.foreground_color.rgb_with_a(alpha))
                    CONFIG.font:write(190, y, rooms[talk.place].name_short, 50, CONFIG.foreground_color.rgb_with_a(alpha))
                    CONFIG.font:write(400, y, talk.title, 50, CONFIG.foreground_color.rgb_with_a(alpha))
                end
            end

            local y = 300
            local time_sep = false
            if #all_talks > 0 then
                for idx, talk in ipairs(all_talks) do
                    if not time_sep and talk.start_unix > get_now() then
                        if idx > 1 then
                            y = y + 5
                            add_content(mk_spacer(y))
                            y = y + 20
                        end
                        time_sep = true
                    end
                    if talk.lines then
                        add_content(mk_talkmulti(y, talk, not time_sep))
                    else
                        add_content(mk_talk(y, talk, not time_sep))
                    end
                    y = y + 62
                end
            else
                CONFIG.font:write(400, 330, "No other talks.", 50, CONFIG.foreground_color.rgba())
            end

            return content
        end;
        draw = function(content)
            CONFIG.font:write(400, 180, "Other talks", 80, CONFIG.foreground_color.rgba())
            spacer:draw(0, 280, WIDTH, 282, 0.6)
            for _, func in ipairs(content) do
                func()
            end
        end
    }, {
        time = CONFIG.current_room,
        prepare = function()
        end;
        draw = function()
            if not current_talk then
                CONFIG.font:write(400, 180, "Next talk", 80, CONFIG.foreground_color.rgba())
                spacer:draw(0, 300, WIDTH, 302, 0.6)
                CONFIG.font:write(400, 310, "Nope. That's it.", 50, CONFIG.foreground_color.rgba())
            else
                local delta = current_talk.start_unix - get_now()
                if delta > 0 then
                    CONFIG.font:write(400, 180, "Next talk", 80, CONFIG.foreground_color.rgba())
                else
                    CONFIG.font:write(400, 180, "This talk", 80, CONFIG.foreground_color.rgba())
                end
                spacer:draw(0, 280, WIDTH, 282, 0.6)

                CONFIG.font:write(130, 310, current_talk.start_str, 50, CONFIG.foreground_color.rgba())
                if delta > 180*60 then
                    CONFIG.font:write(130, 310 + 60, string.format("in %d h", math.floor(delta/3660)+1), 50, CONFIG.foreground_color.rgb_with_a(0.6))
                elseif delta > 0 then
                    CONFIG.font:write(130, 310 + 60, string.format("in %d min", math.floor(delta/60)+1), 50, CONFIG.foreground_color.rgb_with_a(0.6))
                end
                for idx, line in ipairs(current_talk.slide_lines) do
                    if idx >= 5 then
                        break
                    end
                    CONFIG.font:write(400, 310 - 60 + 60 * idx, line, 50, CONFIG.foreground_color.rgba())
                end
                for i, speaker in ipairs(current_talk.speakers) do
                    CONFIG.font:write(400, 490 + 50 * i, speaker, 50, CONFIG.foreground_color.rgb_with_a(0.6))
                end
            end
        end
    }, {
        time = CONFIG.room_info,
        prepare = function()
        end;
        draw = function(t)
            CONFIG.font:write(400, 180, "Room information", 80, CONFIG.foreground_color.rgba())
            spacer:draw(0, 280, WIDTH, 282, 0.6)
            CONFIG.font:write(30, 300, "Audio", 50, CONFIG.foreground_color.rgba())
            CONFIG.font:write(400, 300, "Dial " .. current_room.dect, 50, CONFIG.foreground_color.rgba())

            CONFIG.font:write(30, 360, "Translation", 50, CONFIG.foreground_color.rgba())
            CONFIG.font:write(400, 360, "Dial " .. current_room.translation, 50, CONFIG.foreground_color.rgba())

            CONFIG.font:write(30, 460, "IRC", 50, CONFIG.foreground_color.rgba())
            CONFIG.font:write(400, 460, current_room.irc, 50, CONFIG.foreground_color.rgba())

            CONFIG.font:write(30, 520, "Hashtag", 50, CONFIG.foreground_color.rgba())
            CONFIG.font:write(400, 520, current_room.hashtag, 50, CONFIG.foreground_color.rgba())
        end
    }}
end)

function node.render()
    if base_time == 0 then
        return
    end

    content.prepare()

    CONFIG.background_color.clear()
    CONFIG.background.ensure_loaded():draw(0, 0, WIDTH, HEIGHT)

    util.draw_correct(CONFIG.logo.ensure_loaded(), 20, 20, 300, 120)
    CONFIG.font:write(400, 20, current_room.name_short, 100, CONFIG.foreground_color.rgba())
    CONFIG.font:write(850, 20, clock.get(), 100, CONFIG.foreground_color.rgba())
    -- font:write(WIDTH-300, 20, string.format("Day %d", day), 100, CONFIG.foreground_color.rgba())

    local fov = math.atan2(HEIGHT, WIDTH*2) * 360 / math.pi
    gl.perspective(fov, WIDTH/2, HEIGHT/2, -WIDTH,
                        WIDTH/2, HEIGHT/2, 0)
    content.draw()
end
