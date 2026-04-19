--!strict
-- Spectre / Tests / ServerIntegration.server.luau
-- Server script: routes FireWeapon and FireExplosion remote events through the validation pipeline.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Spectre = require(script.Parent.Parent)

local Visualizer = require(script.Parent.Parent.Modules.Visualizer)
Visualizer.SetEnabled(true)

-- ─── Remote setup ─────────────────────────────────────────────────────────────

local function getRemoteEvent(name: string): RemoteEvent
	local event = ReplicatedStorage:FindFirstChild(name)
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = name
		event.Parent = ReplicatedStorage
	end
	return event :: RemoteEvent
end

local FireWeaponEvent    = getRemoteEvent("FireWeaponEvent")
local FireExplosionEvent = getRemoteEvent("FireExplosionEvent")

-- ─── Simple server-side rate limiting ────────────────────────────────────────

local _lastShotTimes: { [Player]: number }      = {}
local _lastExplosionTimes: { [Player]: number } = {}

local WEAPON_FIRE_RATE    = 0.1  -- Min seconds between shots (~600 RPM).
local EXPLOSION_FIRE_RATE = 2.0  -- Min seconds between thrown grenades.

-- ─── Player management ────────────────────────────────────────────────────────

local function onCharacterAdded(character: Model)
	Spectre.RegisterCharacter(character)
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	_lastShotTimes[player] = nil
	_lastExplosionTimes[player] = nil
	if player.Character then
		Spectre.UnregisterCharacter(player.Character)
	end
end)

-- ─── Heartbeat recording ──────────────────────────────────────────────────────

RunService.Heartbeat:Connect(function()
	Spectre.RecordAll(workspace:GetServerTimeNow())
end)

-- ─── Hit validation ───────────────────────────────────────────────────────────

FireWeaponEvent.OnServerEvent:Connect(function(shooter: Player, clientTimestamp: number, origin: Vector3, direction: Vector3)

	local serverNow = workspace:GetServerTimeNow()
	local lastShot = _lastShotTimes[shooter] or 0
	if serverNow - lastShot < WEAPON_FIRE_RATE then
		warn(string.format("[ANTI-SPAM] Shot from %s rejected (too fast).", shooter.Name))
		return
	end
	_lastShotTimes[shooter] = serverNow

	print(string.format("[SERVER] Shot received from %s.", shooter.Name))
	local hasHitSomething = false
	local missReasons = {}

	for _, player in Players:GetPlayers() do
		if player == shooter then continue end
		local targetChar = player.Character
		if not targetChar then continue end

		local isHit, zone, distance, damageMultiplier, reason = Spectre.ValidateHit(
			shooter,
			targetChar,
			origin,
			direction,
			500,
			Vector3.zero,
			clientTimestamp
		)

		if isHit then
			hasHitSomething = true
			print(string.format(
				"[HIT] %s -> %s | Zone: %s | Dist: %.1f | Multiplier: %.2fx",
				shooter.Name,
				player.Name,
				zone or "?",
				distance or 0,
				damageMultiplier or 1
			))
		else
			table.insert(missReasons, string.format("%s (%s)", player.Name, reason or "Unknown"))
		end
	end

	if not hasHitSomething then
		local rtt = shooter:GetNetworkPing()
		local outbound = math.max(0, serverNow - clientTimestamp)
		local totalRewind = outbound + (rtt / 2)
		print(string.format("[MISS] %s hit nobody.", shooter.Name))
		print(string.format("   Reasons : %s", table.concat(missReasons, " | ")))
		print(string.format("   Network  : RTT=%.1fms | Outbound=%.1fms | Rewind=%.1fms", rtt * 1000, outbound * 1000, totalRewind * 1000))
	end
end)

-- ─── Explosion validation ─────────────────────────────────────────────────────

FireExplosionEvent.OnServerEvent:Connect(function(shooter: Player, clientTimestamp: number, explosionOrigin: Vector3, radius: number)

	local serverNow = workspace:GetServerTimeNow()
	local lastExplosion = _lastExplosionTimes[shooter] or 0
	if serverNow - lastExplosion < EXPLOSION_FIRE_RATE then
		return
	end
	_lastExplosionTimes[shooter] = serverNow

	local hitMap = Spectre.ValidateExplosion(
		shooter,
		explosionOrigin,
		radius,
		clientTimestamp,
		5  -- Low penetration: blast passes through light partitions only.
	)

	for character, mult in hitMap do
		local baseDamage = 80
		local finalDamage = math.round(baseDamage * mult)

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid:TakeDamage(finalDamage)
		end

		print(string.format(
			"[EXPLOSION] %s hit | Mult: %.2f | Damage: %d",
			character.Name,
			mult,
			finalDamage
		))
	end
end)

print("[Spectre] Server integration ready.")
