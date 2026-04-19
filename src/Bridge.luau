--!strict
-- Spectre / Bridge.luau
-- Pre-configured network bridge connecting Blink buffers to the Validator.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Use ReplicatedStorage to ensure we point to the shared network definitions.
local SpectreShared = ReplicatedStorage:WaitForChild("SpectreShared")
local ServerNetwork = require(SpectreShared:WaitForChild("Network"):WaitForChild("Server"))

local Validator = require(script.Parent.Core.Validator)

local Bridge = {}

function Bridge.Init(gunRange: number, onHitVerified: (shooter: Player, target: Model, zone: string, mult: number) -> ())
	ServerNetwork.PlayerShoot.On(function(player, data)
		local target = data.Target
		if not target or not target:IsA("Model") then return end
		
		local success, zone, _dist, mult, reason = Validator.ValidateHit(
			player,
			target,
			data.Origin,
			data.Direction,
			gunRange,
			Vector3.zero,
			data.ShotTick
		)
		
		if success and zone and mult then
			onHitVerified(player, target, zone, mult)
		else
			if reason then
				warn(string.format("[Spectre/AC] Rejected shot from %s: %s", player.Name, reason))
			end
		end
	end)
end

return Bridge
