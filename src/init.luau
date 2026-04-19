--!strict
--!optimize 2
--[[
    @title Spectre V1.0.1
    @author @Jeremy84100
    @license MIT

    Server-authoritative rollback hit validation for Roblox.
    R15 full-body tracking with zero-allocation hot paths.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local SnapshotBuffer = require(script.Core.SnapshotBuffer)
local Validator = require(script.Core.Validator)

local Spectre = {}
local _isStarted = false

-- Registers all current and future player characters, then starts the Heartbeat recording loop.
-- Call once on the server to activate the entire system.
function Spectre.AutoStart()
	if _isStarted then return end
	_isStarted = true

	local function onCharacterAdded(character: Model)
		SnapshotBuffer.Register(character)
	end

	local function onPlayerAdded(player: Player)
		player.CharacterAdded:Connect(onCharacterAdded)
		player.CharacterRemoving:Connect(function(character: Model)
			SnapshotBuffer.Unregister(character)
		end)
		if player.Character then onCharacterAdded(player.Character) end
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		if player.Character then SnapshotBuffer.Unregister(player.Character) end
	end)

	RunService.Heartbeat:Connect(function()
		SnapshotBuffer.RecordAll(workspace:GetServerTimeNow())
	end)
end

-- Direct function references — no wrapper call frames at runtime.
Spectre.RegisterCharacter   = SnapshotBuffer.Register
Spectre.UnregisterCharacter = SnapshotBuffer.Unregister
Spectre.RecordAll           = SnapshotBuffer.RecordAll

Spectre.ValidateHit       = Validator.ValidateHit
Spectre.ValidateExplosion = Validator.ValidateExplosion

return Spectre