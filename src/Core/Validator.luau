--!strict
--!native
--!optimize 2
-- Spectre / Validator.luau
--
-- Server-authoritative hit validation using rollback lag compensation.
-- R15 pixel-perfect: tests 15 OBBs per character in anatomical priority order.

local Config = require(script.Parent.Parent.Config)
local SnapshotBuffer = require(script.Parent.SnapshotBuffer)
local Visualizer = require(script.Parent.Parent.Modules.Visualizer)

local Validator = {}

-- ─── Zero-allocation singletons ───────────────────────────────────────────────
-- Created once at module load, recycled on every call. No allocations in the hot path.

-- Shared RaycastParams for the forward ray (Exclude = shooter + target).
local _hitRayParams = RaycastParams.new()
_hitRayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Shared RaycastParams for the wallbang back-ray (Include = hit part only).
local _backRayParams = RaycastParams.new()
_backRayParams.FilterType = Enum.RaycastFilterType.Include

-- Shared exclude list, recycled via table.clear.
local _excludeList: { Instance } = table.create(32)

-- Shared include list for the back-ray.
local _sharedIncludeList: { Instance } = table.create(1)

-- Shared result table for AoE queries, recycled via table.clear.
local _explosionResults: any = setmetatable({}, { __mode = "k" })

-- Dirty flags: avoid redundant C-bridge calls when FilterDescendantsInstances hasn't changed.
local _lastHitFilterLen: number = 0
local _lastHitExclude1: any = nil
local _lastHitExclude2: any = nil
local _lastBackFilterPart: Instance? = nil

-- ─── Ray-OBB intersection ─────────────────────────────────────────────────────

local function rayOBBIntersect(
	rayOrigin: Vector3,
	rayDir: Vector3,
	obbCFrame: CFrame,
	obbSize: Vector3
): number?
	local localOrigin = obbCFrame:PointToObjectSpace(rayOrigin)
	local localDir = obbCFrame:VectorToObjectSpace(rayDir)
	local half = obbSize * 0.5

	local ox, oy, oz = localOrigin.X, localOrigin.Y, localOrigin.Z
	local dx, dy, dz = localDir.X, localDir.Y, localDir.Z
	local hx, hy, hz = half.X, half.Y, half.Z

	local tMin = -math.huge
	local tMax = math.huge

	-- X slab
	if math.abs(dx) < 1e-8 then
		if ox < -hx or ox > hx then return nil end
	else
		local t1 = (-hx - ox) / dx
		local t2 = (hx - ox) / dx
		if t1 > t2 then t1, t2 = t2, t1 end
		tMin = math.max(tMin, t1)
		tMax = math.min(tMax, t2)
		if tMin > tMax then return nil end
	end

	-- Y slab
	if math.abs(dy) < 1e-8 then
		if oy < -hy or oy > hy then return nil end
	else
		local t1 = (-hy - oy) / dy
		local t2 = (hy - oy) / dy
		if t1 > t2 then t1, t2 = t2, t1 end
		tMin = math.max(tMin, t1)
		tMax = math.min(tMax, t2)
		if tMin > tMax then return nil end
	end

	-- Z slab
	if math.abs(dz) < 1e-8 then
		if oz < -hz or oz > hz then return nil end
	else
		local t1 = (-hz - oz) / dz
		local t2 = (hz - oz) / dz
		if t1 > t2 then t1, t2 = t2, t1 end
		tMin = math.max(tMin, t1)
		tMax = math.min(tMax, t2)
		if tMin > tMax then return nil end
	end

	if tMin < 0 then
		if tMax < 0 then return nil end
		return 0
	end
	return tMin
end


-- ─── Public API ───────────────────────────────────────────────────────────────

function Validator.ValidateHit(
	shooter: Player,
	targetCharacter: Model,
	shotOrigin: Vector3?,
	shotDirection: Vector3?,
	gunRange: number,
	muzzleOffset: Vector3,
	clientTimestamp: number?,
	projectileSpeed: number?,
	weaponPenetration: number?,
	projectileRadius: number?,
	clientAimDirection: Vector3?,
	maxSpreadAngle: number?
): (boolean, string?, number?, number?, string?)
	if not shotOrigin or not shotDirection then return false, nil, nil, nil, "Missing origin/direction" end
	-- Guard: zero-magnitude direction produces NaN in Unit, silently crashing all Ray-OBB tests.
	if shotDirection.Magnitude < 1e-6 then return false, nil, nil, nil, "Zero magnitude direction" end

	local shooterChar = shooter.Character
	if not shooterChar then return false, nil, nil, nil, "No shooter character" end
	local shooterRoot = shooterChar.PrimaryPart :: BasePart?
	if not shooterRoot then return false, nil, nil, nil, "No shooter root" end

	-- 1. Compute rewind time (ping + interpolation buffer + projectile travel time).
	local serverNow = workspace:GetServerTimeNow()

	local travelTime = 0
	if projectileSpeed and projectileSpeed > 0 then
		local targetRoot = targetCharacter.PrimaryPart :: BasePart?
		if not targetRoot then return false, nil, nil, nil, "Target destroyed/unloaded" end
		local distance = (shotOrigin - targetRoot.Position).Magnitude
		travelTime = distance / projectileSpeed
	end

	local latencyRewind = 0
	if clientTimestamp then
		local outbound = math.max(0, serverNow - clientTimestamp)
		local inbound = 0
		if typeof(shooter) == "Instance" and shooter:IsA("Player") then
			inbound = shooter:GetNetworkPing() / 2
		end
		latencyRewind = outbound + inbound + Config.INTERPOLATION_BUFFER
	end

	local rewindAmount = math.clamp(latencyRewind + travelTime, 0, Config.MAX_REWIND_SECONDS)
	local rewindTime = serverNow - rewindAmount

	-- 2. Origin validation (anti-teleport).
	local shooterSnap = SnapshotBuffer.GetInterpolatedSnapshot(shooterChar, rewindTime)
	local shooterCheckPos = if shooterSnap then shooterSnap.rootCFrame.Position else shooterRoot.Position
	local originDist = (shotOrigin - shooterCheckPos).Magnitude
	local maxOriginDist = Config.MAX_ORIGIN_DISTANCE + muzzleOffset.Magnitude + (rewindAmount * Config.MAX_PLAYER_SPEED)

	if originDist > maxOriginDist then return false, nil, nil, nil, "Origin offset too large (Teleport?)" end

	-- 2.5. Anti-spread: reject trajectories outside the weapon's physical cone.
	if clientAimDirection and maxSpreadAngle and shotDirection then
		local aimUnit = clientAimDirection.Unit
		local shotUnit = shotDirection.Unit
		local angle = math.acos(math.clamp(aimUnit:Dot(shotUnit), -1, 1))
		if angle > math.rad(maxSpreadAngle) then
			return false, nil, nil, nil, "Anti-Spread triggered"
		end
	end

	-- 3. Retrieve the full R15 snapshot at rewind time.
	local snap = SnapshotBuffer.GetInterpolatedSnapshot(targetCharacter, rewindTime)
	if not snap then
		return false, nil, nil, nil, "Target not in snapshot buffer"
	end

	-- 3.5. I-Frame check (dash invincibility).
	local lastDashTime = targetCharacter:GetAttribute("LastDashTime")
	if type(lastDashTime) == "number" then
		if rewindTime >= lastDashTime and rewindTime <= (lastDashTime + Config.DASH_INVINCIBILITY_DURATION) then
			return false, nil, nil, nil, "Target is invincible (I-Frame)"
		end
	end

	-- 4. Ray-OBB intersection across 15 anatomical segments.
	local rayLength = gunRange + muzzleOffset.Magnitude + 3
	local dirUnit = shotDirection.Unit
	local forgiveness = Config.ROLLBACK_FORGIVENESS

	-- Bullet drop offset.
	local bulletDrop = 0
	if projectileSpeed and projectileSpeed > 0 then
		bulletDrop = 0.5 * Config.PROJECTILE_GRAVITY * (travelTime * travelTime)
	end
	local dropOffset = Vector3.new(0, bulletDrop, 0)

	-- 4.0. Broad-phase: skip all 15 OBB tests if the ray misses the character AABB.
	local broadSize = Config.CHARACTER_BOUNDING_BOX_SIZE + forgiveness
	local broadCF = snap.rootCFrame + dropOffset
	if not rayOBBIntersect(shotOrigin, dirUnit, broadCF, broadSize) then
		return false, nil, nil, nil, "Missed broadly (Broad-Phase)"
	end

	-- Minkowski sum: projectile radius expands each hitbox uniformly at zero cost.
	local radiusVec = Vector3.new(projectileRadius or 0, projectileRadius or 0, projectileRadius or 0)

	local headSize  = Config.HEAD_SIZE + forgiveness + radiusVec
	local uTorsoSize = if snap.isCrouching then Config.CROUCH_UPPER_TORSO_SIZE + forgiveness + radiusVec else Config.UPPER_TORSO_SIZE + forgiveness + radiusVec
	local lTorsoSize = Config.LOWER_TORSO_SIZE + forgiveness + radiusVec
	local uArmSize  = Config.UPPER_ARM_SIZE + forgiveness + radiusVec
	local lArmSize  = Config.LOWER_ARM_SIZE + forgiveness + radiusVec
	local handSize  = Config.HAND_SIZE + forgiveness + radiusVec
	local uLegSize  = Config.UPPER_LEG_SIZE + forgiveness + radiusVec
	local lLegSize  = Config.LOWER_LEG_SIZE + forgiveness + radiusVec
	local footSize  = Config.FOOT_SIZE + forgiveness + radiusVec

	-- Nearest-first priority: the closest segment hit wins (pixel-perfect).
	local bestDist = math.huge
	local hitZone: string? = nil

	-- Head
	local d = rayOBBIntersect(shotOrigin, dirUnit, snap.headCFrame + dropOffset, headSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "Head" end

	-- Upper torso
	d = rayOBBIntersect(shotOrigin, dirUnit, snap.upperTorsoCFrame + dropOffset, uTorsoSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "UpperTorso" end

	-- Lower torso
	d = rayOBBIntersect(shotOrigin, dirUnit, snap.lowerTorsoCFrame + dropOffset, lTorsoSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "LowerTorso" end

	-- Left arm (3 segments)
	d = rayOBBIntersect(shotOrigin, dirUnit, snap.leftUpperArmCFrame + dropOffset, uArmSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "LeftUpperArm" end

	d = rayOBBIntersect(shotOrigin, dirUnit, snap.leftLowerArmCFrame + dropOffset, lArmSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "LeftLowerArm" end

	d = rayOBBIntersect(shotOrigin, dirUnit, snap.leftHandCFrame + dropOffset, handSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "LeftHand" end

	-- Right arm (3 segments)
	d = rayOBBIntersect(shotOrigin, dirUnit, snap.rightUpperArmCFrame + dropOffset, uArmSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "RightUpperArm" end

	d = rayOBBIntersect(shotOrigin, dirUnit, snap.rightLowerArmCFrame + dropOffset, lArmSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "RightLowerArm" end

	d = rayOBBIntersect(shotOrigin, dirUnit, snap.rightHandCFrame + dropOffset, handSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "RightHand" end

	-- Left leg (3 segments)
	d = rayOBBIntersect(shotOrigin, dirUnit, snap.leftUpperLegCFrame + dropOffset, uLegSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "LeftUpperLeg" end

	d = rayOBBIntersect(shotOrigin, dirUnit, snap.leftLowerLegCFrame + dropOffset, lLegSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "LeftLowerLeg" end

	d = rayOBBIntersect(shotOrigin, dirUnit, snap.leftFootCFrame + dropOffset, footSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "LeftFoot" end

	-- Right leg (3 segments)
	d = rayOBBIntersect(shotOrigin, dirUnit, snap.rightUpperLegCFrame + dropOffset, uLegSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "RightUpperLeg" end

	d = rayOBBIntersect(shotOrigin, dirUnit, snap.rightLowerLegCFrame + dropOffset, lLegSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "RightLowerLeg" end

	d = rayOBBIntersect(shotOrigin, dirUnit, snap.rightFootCFrame + dropOffset, footSize)
	if d and d <= rayLength and d < bestDist then bestDist = d; hitZone = "RightFoot" end

	local hitDistance: number? = if hitZone then bestDist else nil
	local hitAny = (hitZone ~= nil)

	-- 5. Line-of-sight and wallbang (material penetration).
	local damageMultiplier = 1.0

	if hitAny and hitDistance then
		local hitPoint = shotOrigin + (dirUnit * hitDistance)
		local currentOrigin = shotOrigin

		-- Recycle shared tables — no heap allocations.
		table.clear(_excludeList)
		_excludeList[1] = shooterChar
		_excludeList[2] = targetCharacter
		local excludeCount = 2

		-- Dirty-flag: only call the C-bridge setter when the content actually changed.
		if excludeCount ~= _lastHitFilterLen or _lastHitExclude1 ~= shooterChar or _lastHitExclude2 ~= targetCharacter then
			_hitRayParams.FilterDescendantsInstances = _excludeList
			_lastHitFilterLen = excludeCount
			_lastHitExclude1 = shooterChar
			_lastHitExclude2 = targetCharacter
		end

		local initialPenetration = weaponPenetration or 0
		local remainingPenetration = initialPenetration

		local isBlocked = false
		local maxLoops = Config.MAX_LOS_ITERATIONS
		local loopCount = 0

		while loopCount < maxLoops do
			loopCount += 1
			local obstruction = workspace:Raycast(currentOrigin, hitPoint - currentOrigin, _hitRayParams)

			if not obstruction then
				break -- Clear path.
			end

			local hitPart = obstruction.Instance

			-- Case A: unanchored physics object — skip it.
			if Config.IGNORE_UNANCHORED_PARTS and not hitPart.Anchored then
				excludeCount += 1
				_excludeList[excludeCount] = hitPart
				_hitRayParams.FilterDescendantsInstances = _excludeList
				_lastHitFilterLen = excludeCount
				currentOrigin = obstruction.Position + (dirUnit * 0.01)

			-- Case B: static wall — attempt penetration.
			elseif initialPenetration > 0 then
				local material = obstruction.Material
				local resistance = Config.MATERIAL_RESISTANCE[material] or Config.DEFAULT_MATERIAL_RESISTANCE

				local probeDistance = Config.MAX_WALLBANG_PROBE_DISTANCE
				local probeOrigin = obstruction.Position + (dirUnit * probeDistance)

				-- Dirty-flag: only update back-ray filter when the part has changed.
				if hitPart ~= _lastBackFilterPart then
					_sharedIncludeList[1] = hitPart
					_backRayParams.FilterDescendantsInstances = _sharedIncludeList
					_lastBackFilterPart = hitPart
				end
				local backResult = workspace:Raycast(probeOrigin, -dirUnit * probeDistance, _backRayParams)

				if backResult then
					local thickness = (backResult.Position - obstruction.Position).Magnitude
					local energyCost = thickness * resistance

					if remainingPenetration >= energyCost then
						remainingPenetration -= energyCost
						damageMultiplier *= math.clamp(1 - (energyCost / initialPenetration), 0, 1)
						currentOrigin = backResult.Position + (dirUnit * 0.01)
					else
						isBlocked = true
						break
					end
				else
					isBlocked = true
					break
				end
			else
				isBlocked = true
				break
			end
		end

		if isBlocked then
			hitAny = false
			hitZone = nil
			damageMultiplier = 0
		end
	end

	-- 6. Debug visuals (full R15 ghost boxes + ray).
	if Config.DEBUG_MODE and snap then
		local rayColor = if hitAny then Color3.new(0, 1, 0):Lerp(Color3.new(1, 0.5, 0), 1 - damageMultiplier) else Color3.new(1, 0, 0)
		Visualizer.ShowRay(shotOrigin, dirUnit, rayLength, rayColor)

		local headCol   = Color3.new(1, 1, 0)    -- Yellow
		local torsoCol  = Color3.new(0, 0.8, 1)  -- Cyan
		local armCol    = Color3.new(1, 0, 1)    -- Magenta
		local legCol    = Color3.new(0, 0.5, 1)  -- Blue
		local extremCol = Color3.new(1, 0.5, 0)  -- Orange

		Visualizer.ShowBox(snap.headCFrame + dropOffset,          headSize,   headCol)
		Visualizer.ShowBox(snap.upperTorsoCFrame + dropOffset,    uTorsoSize, torsoCol)
		Visualizer.ShowBox(snap.lowerTorsoCFrame + dropOffset,    lTorsoSize, torsoCol)
		Visualizer.ShowBox(snap.leftUpperArmCFrame + dropOffset,  uArmSize,   armCol)
		Visualizer.ShowBox(snap.leftLowerArmCFrame + dropOffset,  lArmSize,   armCol)
		Visualizer.ShowBox(snap.leftHandCFrame + dropOffset,      handSize,   extremCol)
		Visualizer.ShowBox(snap.rightUpperArmCFrame + dropOffset, uArmSize,   armCol)
		Visualizer.ShowBox(snap.rightLowerArmCFrame + dropOffset, lArmSize,   armCol)
		Visualizer.ShowBox(snap.rightHandCFrame + dropOffset,     handSize,   extremCol)
		Visualizer.ShowBox(snap.leftUpperLegCFrame + dropOffset,  uLegSize,   legCol)
		Visualizer.ShowBox(snap.leftLowerLegCFrame + dropOffset,  lLegSize,   legCol)
		Visualizer.ShowBox(snap.leftFootCFrame + dropOffset,      footSize,   extremCol)
		Visualizer.ShowBox(snap.rightUpperLegCFrame + dropOffset, uLegSize,   legCol)
		Visualizer.ShowBox(snap.rightLowerLegCFrame + dropOffset, lLegSize,   legCol)
		Visualizer.ShowBox(snap.rightFootCFrame + dropOffset,     footSize,   extremCol)
	end

	local reason = nil
	if not hitAny then
		reason = if (damageMultiplier == 0 and bestDist ~= math.huge) then "Blocked by environment (Wallbang)" else "Missed character hitboxes"
	end

	-- Release strong references to prevent memory leaks.
	table.clear(_excludeList)
	table.clear(_sharedIncludeList)

	return hitAny, hitZone, hitDistance, damageMultiplier, reason
end

-- ─── AoE Validation ──────────────────────────────────────────────────────────

--- Validates an explosion from `shooter` and returns a damage multiplier per
--- affected character. Handles rollback, line-of-sight, wallbang, and distance falloff.
---
--- Returns: { [Model]: number } — damage multipliers [0..1] per visible character.
function Validator.ValidateExplosion(
	shooter: Player,
	explosionOrigin: Vector3,
	explosionRadius: number,
	clientTimestamp: number?,
	penetration: number?
): { [Model]: number }
	-- Recycle the shared result table.
	table.clear(_explosionResults)

	local shooterChar = shooter.Character

	-- 1. Rewind time (same logic as ValidateHit).
	local serverNow = workspace:GetServerTimeNow()
	local latencyRewind = if clientTimestamp
		then (serverNow - clientTimestamp) + Config.INTERPOLATION_BUFFER
		else 0
	local rewindAmount = math.clamp(latencyRewind, 0, Config.MAX_REWIND_SECONDS)
	local rewindTime = serverNow - rewindAmount

	local initialPenetration = penetration or 0
	local broadRadius = explosionRadius + 5  -- Safety margin for snapshot interpolation.

	-- Build the exclude list once for all characters (avoids N C-bridge copies in the loop).
	table.clear(_excludeList)
	local excludeCount = 0
	if shooterChar then
		excludeCount += 1
		_excludeList[excludeCount] = shooterChar
	end
	for character, _ in SnapshotBuffer.GetRegistry() do
		if character ~= shooterChar then
			excludeCount += 1
			_excludeList[excludeCount] = character
		end
	end
	_hitRayParams.FilterDescendantsInstances = _excludeList

	-- 2. Iterate directly over the internal registry (zero-allocation).
	for character, _ in SnapshotBuffer.GetRegistry() do
		if character == shooterChar then continue end

		local snap = SnapshotBuffer.GetInterpolatedSnapshot(character, rewindTime)
		if not snap then continue end

		-- 3. Broad-phase distance check (skip raycast if out of range).
		local targetPos = snap.upperTorsoCFrame.Position
		local distance = (explosionOrigin - targetPos).Magnitude
		if distance > broadRadius then continue end

		-- 4. I-Frame check — explosions also respect dash invincibility.
		local lastDashTime = character:GetAttribute("LastDashTime")
		if type(lastDashTime) == "number" then
			if rewindTime >= lastDashTime and rewindTime <= (lastDashTime + Config.DASH_INVINCIBILITY_DURATION) then
				continue
			end
		end

		-- 5. Line-of-sight and wallbang from explosion origin to upper torso.
		local dirToTarget = (targetPos - explosionOrigin)
		local dirUnit = if dirToTarget.Magnitude > 0 then dirToTarget.Unit else Vector3.yAxis

		local remainingPenetration = initialPenetration
		local wallMultiplier = 1.0
		local isBlocked = false
		local loopCount = 0

		local currentOrigin = explosionOrigin
		local hitPoint = targetPos

		while loopCount < Config.MAX_LOS_ITERATIONS do
			loopCount += 1
			local obstruction = workspace:Raycast(currentOrigin, hitPoint - currentOrigin, _hitRayParams)
			if not obstruction then break end

			local hitPart = obstruction.Instance
			if Config.IGNORE_UNANCHORED_PARTS and not hitPart.Anchored then
				excludeCount += 1
				_excludeList[excludeCount] = hitPart
				_hitRayParams.FilterDescendantsInstances = _excludeList
				currentOrigin = obstruction.Position + (dirUnit * 0.01)
			elseif initialPenetration > 0 then
				local resistance = Config.MATERIAL_RESISTANCE[obstruction.Material] or Config.DEFAULT_MATERIAL_RESISTANCE
				local probeOrigin = obstruction.Position + (dirUnit * Config.MAX_WALLBANG_PROBE_DISTANCE)
				_sharedIncludeList[1] = hitPart
				_backRayParams.FilterDescendantsInstances = _sharedIncludeList
				local backResult = workspace:Raycast(probeOrigin, -dirUnit * Config.MAX_WALLBANG_PROBE_DISTANCE, _backRayParams)
				if backResult then
					local thickness = (backResult.Position - obstruction.Position).Magnitude
					local energyCost = thickness * resistance
					if remainingPenetration >= energyCost then
						remainingPenetration -= energyCost
						wallMultiplier *= math.clamp(1 - (energyCost / initialPenetration), 0, 1)
						currentOrigin = backResult.Position + (dirUnit * 0.01)
					else
						isBlocked = true
						break
					end
				else
					isBlocked = true
					break
				end
			else
				isBlocked = true
				break
			end
		end

		if isBlocked then continue end

		-- 6. Linear distance falloff combined with wall penetration loss.
		local falloff = math.clamp(1 - (distance / explosionRadius), 0, 1)
		local finalMultiplier = falloff * wallMultiplier

		if finalMultiplier > 0 then
			_explosionResults[character] = finalMultiplier
		end
	end

	-- Release strong references.
	table.clear(_excludeList)
	table.clear(_sharedIncludeList)

	return _explosionResults :: { [Model]: number }
end

return Validator