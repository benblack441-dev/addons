_addon = {}
_addon.name    = 'GeoSkillup'
_addon.author  = 'Aurievaryn'
_addon.version = '1.0'
_addon.commands = {'geoskillup', 'gsu'}

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
    food_enabled  = true,       -- //geoskillup foodcheck on|off
    food_name     = 'B.E.W. Pitaru', -- //geoskillup food <name>
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

local items_by_name = {}
for id, item in pairs(res.items) do
    if item.en then
        items_by_name[item.en:lower()] = item
    end
end

local function find_item(name)
    return items_by_name[name:lower()]
end

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

local last_check    = 0
local busy_until    = 0
local alt_index     = 1
local last_warning  = { geo = 0, alt = 0, mp = 0, food = 0 }

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

-- res/buffs.lua id 251 = "Food". Windower reports player.buffs as a flat array of
-- currently active buff ids.
local FOOD_BUFF_ID = 251

local function has_food_buff(player)
    if not player.buffs then return false end
    for _, buff_id in ipairs(player.buffs) do
        if buff_id == FOOD_BUFF_ID then return true end
    end
    return false
end

local function inventory_count(item_id)
    local items = windower.ffxi.get_items()
    local inv = items and items.inventory
    if not inv then return 0 end
    local count = 0
    for i = 1, items.max_inventory do
        local slot = inv[i]
        if slot and slot.id == item_id then
            count = count + slot.count
        end
    end
    return count
end

-- Keeps config.food_name active at all times: if the Food buff isn't up, eats one
-- from inventory. Runs ahead of the skill-up casting each tick since staying fed
-- matters regardless of what else is on cooldown.
local function try_use_food(player)
    if not config.food_enabled then return false end
    if has_food_buff(player) then return false end

    local item = find_item(config.food_name)
    if not item then
        warn_throttled('food', 'Unknown item "' .. config.food_name .. '" - check config.food_name.')
        return false
    end

    if inventory_count(item.id) <= 0 then
        warn_throttled('food', 'Out of ' .. config.food_name .. ' - restock to keep the food buff up.')
        return false
    end

    windower.chat.input('/item "' .. config.food_name .. '" <me>')
    return true
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

-- Windower's resources lib decodes the raw "targets" bitmask (1=Self, 2=Player,
-- 4=Party, 8=Ally, 16=NPC, 32=Enemy) from res/spells.lua into a Set of name strings
-- (e.g. S{'Self','Party'} or S{'Enemy'}) - it's not a plain number, so check it with
-- the Set's own :contains(), not bit.band(). Geo- spells split into two groups:
-- debuffs like Geo-Frailty/Geo-Poison are Enemy-only, but beneficial ones like
-- Geo-Refresh/Geo-Regen/Geo-Haste/Geo-STR etc. are Self+Party - they plant the
-- stationary Luopan at YOUR location to buff the party, same as Indi- spells do, and
-- are never castable on an enemy at all.

-- Whether a Luopan (Geo- or Indi-, either one) is currently deployed. GEO's Luopan
-- occupies the game's "pet" slot, same as a BST pet or SMN avatar.
local function has_luopan()
    return windower.ffxi.get_mob_by_target('pet') ~= nil
end

-- Only recasts Geo- when there's no Luopan out at all - NOT on the spell's own recast
-- timer, which comes back long before the Luopan itself expires/dies and would
-- otherwise cause pointless re-casting of a bubble that's already up.
local function try_cast_geo(player)
    if has_luopan() then return false end

    local full_name = 'Geo-' .. config.geo_spell
    local spell = find_spell(full_name)
    if not spell then
        warn_throttled('geo', 'Unknown spell "' .. full_name .. '" - check config.geo_spell.')
        return false
    end
    if not spell_ready(spell) then return false end
    if not have_enough_mp(spell, player) then
        warn_throttled('mp', 'Skipping ' .. full_name .. ' - not enough MP.')
        return false
    end

    local targets_enemy = spell.targets and spell.targets:contains('Enemy')
    local target = windower.ffxi.get_mob_by_target('t')
    local has_valid_enemy = target and target.valid_target and target.spawn_type == 16 and target.hpp and target.hpp > 0

    if targets_enemy and has_valid_enemy then
        windower.chat.input('/ma "' .. full_name .. '" <t>')
        if config.auto_engage and player.status ~= 1 then
            windower.chat.input('/attack <t>')
        end
    else
        -- No enemy targeted (or the spell doesn't take one) - cast on self instead.
        windower.chat.input('/ma "' .. full_name .. '" <me>')
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

    if try_use_food(player) then
        busy_until = now + config.cast_buffer
        return
    end

    if try_cast_geo(player) then
        busy_until = now + config.cast_buffer
        return
    end

    if try_cast_alt_indi(player) then
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
        notify('Started. Keeping Geo-' .. config.geo_spell .. ' up, alternating ' ..
            table.concat(config.indi_alt, '/') .. ' on the Indi Luopan, and ' ..
            (config.food_enabled and ('maintaining ' .. config.food_name .. ' food') or 'food check OFF') ..
            '. Auto-engage is ' .. (config.auto_engage and 'ON' or 'OFF') .. '.')

    elseif cmd == 'stop' then
        config.enabled = false
        notify('Stopped.')

    elseif cmd == 'status' then
        notify('Enabled=' .. tostring(config.enabled) ..
            ' Geo=Geo-' .. config.geo_spell ..
            ' Alt=' .. table.concat(config.indi_alt, ',') ..
            ' Food=' .. config.food_name .. ' (' .. (config.food_enabled and 'ON' or 'OFF') .. ')' ..
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

    elseif cmd == 'food' and args[1] then
        config.food_name = table.concat(args, ' ')
        notify('Food item set to "' .. config.food_name .. '"')

    elseif cmd == 'foodcheck' and args[1] then
        config.food_enabled = (args[1]:lower() == 'on')
        notify('Food check set to ' .. tostring(config.food_enabled))

    elseif cmd == 'engage' and args[1] then
        config.auto_engage = (args[1]:lower() == 'on')
        notify('Auto-engage set to ' .. tostring(config.auto_engage))

    elseif cmd == 'mp' and args[1] and tonumber(args[1]) then
        config.mp_reserve = tonumber(args[1])
        notify('MP reserve set to ' .. config.mp_reserve)

    else
        notify('Commands: start | stop | status | geo <name> | alt1 <name> | alt2 <name> | food <name> | foodcheck on|off | engage on|off | mp <n>')
    end
end)

notify('Loaded. //geoskillup start to begin (default: Geo-' .. config.geo_spell .. ' + alternating ' ..
    table.concat(config.indi_alt, '/') .. ' + ' .. config.food_name .. ' food upkeep).')
