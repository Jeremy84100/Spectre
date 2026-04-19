--!strict
-- Spectre / Tests / TestGunClient.client.luau
-- Client-side test gun: local hit prediction + server-side validation handoff.

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer

local camera = workspace.CurrentCamera

local FireWeaponEvent    = ReplicatedStorage:WaitForChild("FireWeaponEvent") :: RemoteEvent
local FireExplosionEvent = ReplicatedStorage:WaitForChild("FireExplosionEvent") :: RemoteEvent

-- ─── Local hit prediction ─────────────────────────────────────────────────────
-- The client runs an immediate local raycast exclusively for visual feedback
-- (hitmarker). The server performs the authoritative rollback check independently.
-- This is standard FPS practice (CS2, Valorant, CoD).

local function spawnHitmarker(position: Vector3)
	local marker = Instance.new("Part")
	marker.Name = "Hitmarker"
	marker.Shape = Enum.PartType.Ball
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.fromRGB(255, 50, 50)
	marker.Size = Vector3.new(0.3, 0.3, 0.3)
	marker.CFrame = CFrame.new(position)
	marker.Anchored = true
	marker.CanCollide = false
	marker.CastShadow = false
	marker.Parent = workspace

	Debris:AddItem(marker, 0.1)
end

-- ─── Weapon fire ──────────────────────────────────────────────────────────────

local function fire()
	local localChar = localPlayer.Character
	if not localChar then return end

	local mousePos = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mousePos.X, mousePos.Y)

	local head = localChar:FindFirstChild("Head") :: BasePart?
	local startOrigin = if head then head.Position else unitRay.Origin

	-- True shot direction: head position towards camera aim point.
	local targetPoint = unitRay.Origin + (unitRay.Direction * 1000)
	local trueDirection = (targetPoint - startOrigin).Unit

	-- Local raycast for the hitmarker (excludes the local character).
	local raycastParams = RaycastParams.new()
	local ignoreList = { localChar }
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = ignoreList

	local result = workspace:Raycast(startOrigin, trueDirection * 500, raycastParams)

	-- Skip accessories (hats, hair) — use CollisionGroups in a real project.
	while result do
		local hit = result.Instance
		if hit:FindFirstAncestorOfClass("Accessory") then
			table.insert(ignoreList, hit)
			raycastParams.FilterDescendantsInstances = ignoreList
			result = workspace:Raycast(startOrigin, trueDirection * 500, raycastParams)
		else
			break
		end
	end

	if result then
		local hitInstance = result.Instance
		local parentModel = hitInstance:FindFirstAncestorOfClass("Model")
		if parentModel and parentModel:FindFirstChildOfClass("Humanoid") and parentModel ~= localChar then
			spawnHitmarker(result.Position)
		end
	end

	-- Send to server for authoritative rollback validation.
	local timestamp = workspace:GetServerTimeNow()
	FireWeaponEvent:FireServer(timestamp, startOrigin, trueDirection)

	print("[CLIENT] Shot sent to server.")
end

-- ─── Grenade throw (AoE test) ─────────────────────────────────────────────────

local function throwGrenade()
	local mousePos = UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(mousePos.X, mousePos.Y)

	-- Simulates a grenade landing 30 studs in front of the camera.
	local explosionOrigin = unitRay.Origin + unitRay.Direction * 30
	local explosionRadius = 15

	-- Immediate local visual feedback (orange sphere).
	local marker = Instance.new("Part")
	marker.Shape = Enum.PartType.Ball
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.fromRGB(255, 140, 0)
	marker.Size = Vector3.new(explosionRadius * 2, explosionRadius * 2, explosionRadius * 2)
	marker.CFrame = CFrame.new(explosionOrigin)
	marker.Anchored = true
	marker.CanCollide = false
	marker.Transparency = 0.8
	marker.Parent = workspace
	Debris:AddItem(marker, 0.3)

	local timestamp = workspace:GetServerTimeNow()
	FireExplosionEvent:FireServer(timestamp, explosionOrigin, explosionRadius)

	print("[CLIENT] Grenade thrown at", explosionOrigin)
end

-- ─── Input bindings ───────────────────────────────────────────────────────────

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		fire()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		throwGrenade()
	end
end)

print("[Spectre] TestGunClient ready. LMB = Shoot | RMB = Grenade")
