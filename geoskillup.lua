_addon = {}
_addon.name    = 'GeoSkillup'
_addon.author  = 'Aurievaryn'
_addon.version = '1.0'
_addon.commands = {'geoskillup', 'geosu'}

local res = require('resources')

--------------------------------------------------------------------------
-- Config (change these, or use the // commands below to change at runtime)
--------------------------------------------------------------------------

local config = {
    enabled       = false,      -- //geoskillup start | stop
    geo_spell     = 'Refresh',  -- built into "Geo-Refresh"; the ground Luopan, kept up on cooldown; //geoskillup geo <name>
    indi_alt      = {'Precision', 'Voidance'}, -- strictly alternated, one per cast, on the Indi (self/party) Luopan
    auto_engage   = false,      -- if true, /attack the target so Handbell can skill up too
    mp_reserve    = 50,         -- never cast if it would drop current MP below this
    check_period  = 3,          -- seconds between recast checks
    cast_buffer   = 6,          -- seconds to wait after issuing a cast before trying again
}

-- NOTE: Geo- spells plant a stationary Luopan on the ground, independent of the Indi
-- Luopan that follows you - so the Geo- spell below and the Indi- rotation don't
-- compete for the same slot; both stay active simultaneously. The Geo- spell is just
-- recast on cooldown to keep its Luopan up; the two Indi- spells strictly alternate,
-- each on its own independent recast timer.

--------------------------------------------------------------------------
-- Spell resource lookup (build a name -> resource cache once)
--------------------------------------------------------------------------

local spells_by_name = {}
for id, spell in pairs(res.spells) do
    if spell.en then
        spells_by_name[spell.en:lower()] = spell
    end
end

local function find_spell(name)
    return spells_by_name[name:lower()]
end

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

local last_check    = 0
local busy_until    = 0
local alt_index     = 1
local last_warning  = { geo = 0, alt = 0, mp = 0 }

local function notify(msg)
    windower.add_to_chat(207, '[GeoSkillup] ' .. msg)
end

local function warn_throttled(key, msg)
    local now = os.clock()
    if now - (last_warning[key] or 0) > 15 then
        last_warning[key] = now
        notify(msg)
    end
end

--------------------------------------------------------------------------
-- Core logic
--------------------------------------------------------------------------

local function spell_ready(spell)
    local recasts = windower.ffxi.get_spell_recasts()
    return recasts[spell.id] == 0
end

local function have_enough_mp(spell, player)
    return (player.vitals.mp - (spell.mp_cost or 0)) >= config.mp_reserve
end

local function try_cast_indi_spell(player, spell_base_name, warn_key)
    local full_name = 'Indi-' .. spell_base_name
    local spell = find_spell(full_name)
    if not spell then
        warn_throttled(warn_key, 'Unknown spell "' .. full_name .. '" - check your config.')
        return false
    end
    if not spell_ready(spell) then return false end
    if not have_enough_mp(spell, player) then
        warn_throttled('mp', 'Skipping ' .. full_name .. ' - not enough MP.')
        return false
    end
    windower.chat.input('/ma "' .. full_name .. '" <me>')
    return true
end

-- Strictly alternates through config.indi_alt (e.g. Precision, then Voidance, then
-- back to Precision), casting whichever is next in line as soon as it's off cooldown.
local function try_cast_alt_indi(player)
    if #config.indi_alt == 0 then return false end

    local alt_name = config.indi_alt[alt_index]
    if try_cast_indi_spell(player, alt_name, 'alt') then
        alt_index = (alt_index % #config.indi_alt) + 1
        return true
    end
    return false
end

local function try_cast_geo(player)
    local full_name = 'Geo-' .. config.geo_spell
    local spell = find_spell(full_name)
    if not spell then
        warn_throttled('geo', 'Unknown spell "' .. full_name .. '" - check config.geo_spell.')
        return false
    end
    if not spell_ready(spell) then return false end

    local target = windower.ffxi.get_mob_by_target('t')
    if not target or not target.valid_target or target.spawn_type ~= 16 or not target.hpp or target.hpp <= 0 then
        warn_throttled('geo', 'No valid enemy target selected for ' .. full_name .. '.')
        return false
    end
    if not have_enough_mp(spell, player) then
        warn_throttled('mp', 'Skipping ' .. full_name .. ' - not enough MP.')
        return false
    end

    windower.chat.input('/ma "' .. full_name .. '" <t>')

    if config.auto_engage and player.status ~= 1 then
        windower.chat.input('/attack <t>')
    end

    return true
end

local function tick()
    local now = os.clock()
    if now < busy_until then return end
    if now - last_check < config.check_period then return end
    last_check = now

    local player = windower.ffxi.get_player()
    if not player or not player.vitals or player.vitals.hp <= 0 then return end

    if try_cast_alt_indi(player) then
        busy_until = now + config.cast_buffer
        return
    end

    local cast_geo = try_cast_geo(player)
    if cast_geo then
        busy_until = now + config.cast_buffer
        return
    end

    if config.auto_engage then
        local target = windower.ffxi.get_mob_by_target('t')
        if target and target.valid_target and target.spawn_type == 16 and target.hpp and target.hpp > 0 and player.status ~= 1 then
            windower.chat.input('/attack <t>')
        end
    end
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

windower.register_event('prerender', function()
    if config.enabled then tick() end
end)

windower.register_event('addon command', function(cmd, ...)
    cmd = cmd and cmd:lower() or ''
    local args = {...}

    if cmd == 'start' then
        config.enabled = true
        notify('Started. Keeping Geo-' .. config.geo_spell .. ' up and alternating ' ..
            table.concat(config.indi_alt, '/') .. ' on the Indi Luopan. Auto-engage is ' ..
            (config.auto_engage and 'ON' or 'OFF') .. '.')

    elseif cmd == 'stop' then
        config.enabled = false
        notify('Stopped.')

    elseif cmd == 'status' then
        notify('Enabled=' .. tostring(config.enabled) ..
            ' Geo=Geo-' .. config.geo_spell ..
            ' Alt=' .. table.concat(config.indi_alt, ',') ..
            ' AutoEngage=' .. tostring(config.auto_engage) ..
            ' MPReserve=' .. config.mp_reserve)

    elseif cmd == 'geo' and args[1] then
        config.geo_spell = args[1]
        notify('Geo Luopan spell set to Geo-' .. config.geo_spell)

    elseif cmd == 'alt1' and args[1] then
        config.indi_alt[1] = args[1]
        notify('Alt slot 1 set to Indi-' .. args[1])

    elseif cmd == 'alt2' and args[1] then
        config.indi_alt[2] = args[1]
        notify('Alt slot 2 set to Indi-' .. args[1])

    elseif cmd == 'engage' and args[1] then
        config.auto_engage = (args[1]:lower() == 'on')
        notify('Auto-engage set to ' .. tostring(config.auto_engage))

    elseif cmd == 'mp' and args[1] and tonumber(args[1]) then
        config.mp_reserve = tonumber(args[1])
        notify('MP reserve set to ' .. config.mp_reserve)

    else
        notify('Commands: start | stop | status | geo <name> | alt1 <name> | alt2 <name> | engage on|off | mp <n>')
    end
end)

notify('Loaded. //geoskillup start to begin (default: Geo-' .. config.geo_spell .. ' + alternating ' ..
    table.concat(config.indi_alt, '/') .. ').')
