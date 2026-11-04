-- Switch Input: tells the Switch runtime (lx_glfw.c) which controller player 1 is on, in Zomboid/Lua/switch_input.txt:
-- "<controller> <count>", controller -1 = mouse and keyboard, n = controller n (GLFW joystick n). Written when it
-- changes and every second; the count tells the runtime this mod is running.

local FILE = "switch_input.txt"
local last, lastMs, count = nil, 0, 0

-- the controller player 1 is on: in game the player's binding, in the main menu the controller that has player 1's UI
local function player1Controller()
    local player = getSpecificPlayer(0)
    if player then return player:getJoypadBind() end
    local joypad = JoypadState.joypads[1]
    if joypad and joypad.isActive and joypad.controller then return joypad.id end
    return -1
end

local function report()
    local controller = player1Controller()
    local now = getTimestampMs()
    if controller == last and now - lastMs < 1000 then return end
    last, lastMs, count = controller, now, count + 1
    local writer = getFileWriter(FILE, true, false)
    if writer then
        writer:write(tostring(controller) .. " " .. tostring(count) .. "\n")
        writer:close()
    end
end

Events.OnFETick.Add(report)
Events.OnTickEvenPaused.Add(report)
