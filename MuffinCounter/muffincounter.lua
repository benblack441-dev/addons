--[[

Copyright © 2026, DTR, Dabidobido
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of this addon nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

]]

_addon.version = '1.1.1'
_addon.name = 'MuffinCounter'
_addon.author = 'DTR'
_addon.commands = {'mc', 'muffincounter'}

texts = require('texts')
packets = require('packets')
require('luau')

-- Display settings
displaySettings = {pos={x=12,y=-3},text={font='YDGothic 110 Pro',size=11},bg={visible=false}}
displayBox = texts.new(displaySettings)
displayBox:show()

-- Track gallimaufry counts
count = {
	['muffins'] = 0,
	['gained_muffins'] = 0,
}

-- Create display template
function makeDisplay()
	local properties = L{}
    properties:append('${muffins}')
    displayBox:clear()
    displayBox:append(properties:concat('\n'))
end

-- Format number with comma separators
function formatNumber(num)
    local formatted = tostring(num)
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

-- Update display with current counts
function updateDisplay()
    local info = {}
    local total = formatNumber(count.muffins+count.gained_muffins)
    local gained = formatNumber(count.gained_muffins)
	info.muffins = "\\cs(255,255,255) Gallimaufry ["..total.." (\\cs(0,255,0)+"..gained.."\\cs(255,255,255)\\)]"
    displayBox:update(info)
    displayBox:show()
end

makeDisplay()
updateDisplay()

-- Register event to get total muffin count from packet
windower.register_event('incoming chunk',function(id,original,modified,injected,blocked)
	if id == 0x118 then
        count.muffins = original:byte(145)+256*original:byte(146)+(256*256*original:byte(147))
        updateDisplay()
	end
end)

-- Register event to track gallimaufry gains from incoming text
windower.register_event('incoming text', function(original, modified, mode)
	if string.find(original,"received %d+ gallimaufry for a total of") then
		local gained = tonumber(original:match("%d+"))
		count.gained_muffins = count.gained_muffins + gained
		updateDisplay()
	end
end)

-- Register addon commands for reporting
windower.register_event('addon command',function(...)
    local args = T{...}
    local command
    if args[1] then command = string.lower(args[1]) end
	if command == 'report' then
		windower.add_to_chat(201,"[MuffinCounter] You gained "..count.gained_muffins..' muffins your last run! Tasty.')
	elseif command == 'party' then
		windower.send_command("input /p We gained "..count.gained_muffins..' muffins! Tasty.')
	elseif command == 'reset' then
		windower.send_command('lua r muffincounter')
	end
end)

-- Request muffin count on load
packets.inject(packets.new('outgoing', 0x115))


