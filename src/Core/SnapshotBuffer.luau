--!strict
--!native
--!optimize 2
-- Spectre / SnapshotBuffer.luau
-- Zero-allocation circular ring buffer for R15 full-body pose history (15 segments per frame).

local Config = require(script.Parent.Parent.Config)
local Types = require(script.Parent.Parent.Types)

type HitboxSnapshot = Types.HitboxSnapshot
type HistoryBuffer = Types.HistoryBuffer

local SnapshotBuffer = {}

-- Internal registry: [Model] -> HistoryBuffer (weak keys, GC-safe)
local _registry: any = setmetatable({}, { __mode = "k" })

-- R15 parts cache: [Model] -> { [string]: BasePart } (weak keys, GC-safe)
local _partsCache: any = setmetatable({}, { __mode = "k" })

-- Singleton read result — allocated once, reused on every interpolation call.
-- IMPORTANT: Never store this table. Extract CFrames immediately after use.
local _interpolatedResult: HitboxSnapshot = {
	timestamp = 0,
	rootCFrame = CFrame.identity,
	upperTorsoCFrame = CFrame.identity,
	lowerTorsoCFrame = CFrame.identity,
	headCFrame = CFrame.identity,
	leftUpperArmCFrame = CFrame.identity,
	leftLowerArmCFrame = CFrame.identity,
	leftHandCFrame = CFrame.identity,
	rightUpperArmCFrame = CFrame.identity,
	rightLowerArmCFrame = CFrame.identity,
	rightHandCFrame = CFrame.identity,
	leftUpperLegCFrame = CFrame.identity,
	leftLowerLegCFrame = CFrame.identity,
	leftFootCFrame = CFrame.identity,
	rightUpperLegCFrame = CFrame.identity,
	rightLowerLegCFrame = CFrame.identity,
	rightFootCFrame = CFrame.identity,
	isCrouching = false,
	velocity = Vector3.zero,
}

-- ─── Private ──────────────────────────────────────────────────────────────────

local function resolveR15Parts(character: Model): { [string]: BasePart }
	local parts: { [string]: BasePart } = {}
	for _, name in Config.R15_PART_NAMES do
		local part = character:FindFirstChild(name) :: BasePart?
		if part then parts[name] = part end
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then parts["HumanoidRootPart"] = root end
	return parts
end

-- ─── Public API ───────────────────────────────────────────────────────────────

function SnapshotBuffer.Register(character: Model)
	if _registry[character] then return end

	local capacity = Config.BUFFER_CAPACITY
	local snapshots = table.create(capacity)

	for i = 1, capacity do
		snapshots[i] = {
			timestamp = 0,
			rootCFrame = CFrame.identity,
			upperTorsoCFrame = CFrame.identity,
			lowerTorsoCFrame = CFrame.identity,
			headCFrame = CFrame.identity,
			leftUpperArmCFrame = CFrame.identity,
			leftLowerArmCFrame = CFrame.identity,
			leftHandCFrame = CFrame.identity,
			rightUpperArmCFrame = CFrame.identity,
			rightLowerArmCFrame = CFrame.identity,
			rightHandCFrame = CFrame.identity,
			leftUpperLegCFrame = CFrame.identity,
			leftLowerLegCFrame = CFrame.identity,
			leftFootCFrame = CFrame.identity,
			rightUpperLegCFrame = CFrame.identity,
			rightLowerLegCFrame = CFrame.identity,
			rightFootCFrame = CFrame.identity,
			isCrouching = false,
			velocity = Vector3.zero,
		}
	end

	local buffer: HistoryBuffer = {
		snapshots = snapshots,
		writeIndex = 1,
		count = 0,
		isCrouching = character:GetAttribute("IsCrouching") == true,
		_attributeConnection = nil,
	}

	buffer._attributeConnection = character:GetAttributeChangedSignal("IsCrouching"):Connect(function()
		buffer.isCrouching = character:GetAttribute("IsCrouching") == true
	end)

	_registry[character] = buffer
	_partsCache[character] = resolveR15Parts(character)
end

function SnapshotBuffer.Unregister(character: Model)
	local buffer = _registry[character]
	if buffer and buffer._attributeConnection then
		buffer._attributeConnection:Disconnect()
	end
	_registry[character] = nil
	_partsCache[character] = nil
end

function SnapshotBuffer.RecordAll(timestamp: number)
	for character, buffer in _registry do
		local parts = _partsCache[character]
		if not parts then continue end

		local root = parts["HumanoidRootPart"]
		if not root then continue end

		local snapshots = buffer.snapshots
		local writeIndex = buffer.writeIndex
		local snap = snapshots[writeIndex]

		local rootCF = root.CFrame
		snap.timestamp = timestamp
		snap.rootCFrame = rootCF
		snap.isCrouching = buffer.isCrouching
		snap.velocity = root.AssemblyLinearVelocity

		local p: BasePart?
		p = parts["Head"];           snap.headCFrame = if p then p.CFrame else rootCF
		p = parts["UpperTorso"];     snap.upperTorsoCFrame = if p then p.CFrame else rootCF
		p = parts["LowerTorso"];     snap.lowerTorsoCFrame = if p then p.CFrame else rootCF
		p = parts["LeftUpperArm"];   snap.leftUpperArmCFrame = if p then p.CFrame else rootCF
		p = parts["LeftLowerArm"];   snap.leftLowerArmCFrame = if p then p.CFrame else rootCF
		p = parts["LeftHand"];       snap.leftHandCFrame = if p then p.CFrame else rootCF
		p = parts["RightUpperArm"];  snap.rightUpperArmCFrame = if p then p.CFrame else rootCF
		p = parts["RightLowerArm"];  snap.rightLowerArmCFrame = if p then p.CFrame else rootCF
		p = parts["RightHand"];      snap.rightHandCFrame = if p then p.CFrame else rootCF
		p = parts["LeftUpperLeg"];   snap.leftUpperLegCFrame = if p then p.CFrame else rootCF
		p = parts["LeftLowerLeg"];   snap.leftLowerLegCFrame = if p then p.CFrame else rootCF
		p = parts["LeftFoot"];       snap.leftFootCFrame = if p then p.CFrame else rootCF
		p = parts["RightUpperLeg"];  snap.rightUpperLegCFrame = if p then p.CFrame else rootCF
		p = parts["RightLowerLeg"];  snap.rightLowerLegCFrame = if p then p.CFrame else rootCF
		p = parts["RightFoot"];      snap.rightFootCFrame = if p then p.CFrame else rootCF

		buffer.writeIndex = if writeIndex == Config.BUFFER_CAPACITY then 1 else writeIndex + 1
		buffer.count = math.min(buffer.count + 1, Config.BUFFER_CAPACITY)
	end
end

-- Returns a reference to the shared singleton `_interpolatedResult`.
-- NEVER store the whole table — extract CFrames immediately after the call.
function SnapshotBuffer.GetInterpolatedSnapshot(character: Model, targetTime: number): HitboxSnapshot?
	local buffer = _registry[character]
	if not buffer or buffer.count < 2 then return nil end

	local snapshots = buffer.snapshots
	local capacity = Config.BUFFER_CAPACITY
	local count = buffer.count
	local writeIndex = buffer.writeIndex

	local s1: HitboxSnapshot? = nil
	local s2: HitboxSnapshot? = nil

	for i = 0, count - 1 do
		local idx = (writeIndex - 1 - i - 1) % capacity + 1
		local snap = snapshots[idx]
		if snap.timestamp <= targetTime then
			s1 = snap
			local s2Idx = (writeIndex - 1 - (i - 1) - 1) % capacity + 1
			s2 = snapshots[s2Idx]
			break
		end
	end

	if not s1 then
		local oldestIdx = (writeIndex - 1 - (count - 1) - 1) % capacity + 1
		return snapshots[oldestIdx]
	end

	if not s2 or s2 == s1 then
		local s = s1 :: HitboxSnapshot
		local timeDiff = targetTime - s.timestamp
		if timeDiff > 0 then
			timeDiff = math.min(timeDiff, Config.MAX_EXTRAPOLATION_SECONDS)
			local offset = s.velocity * timeDiff

			_interpolatedResult.timestamp = targetTime
			_interpolatedResult.rootCFrame = s.rootCFrame + offset
			_interpolatedResult.upperTorsoCFrame = s.upperTorsoCFrame + offset
			_interpolatedResult.lowerTorsoCFrame = s.lowerTorsoCFrame + offset
			_interpolatedResult.headCFrame = s.headCFrame + offset
			_interpolatedResult.leftUpperArmCFrame = s.leftUpperArmCFrame + offset
			_interpolatedResult.leftLowerArmCFrame = s.leftLowerArmCFrame + offset
			_interpolatedResult.leftHandCFrame = s.leftHandCFrame + offset
			_interpolatedResult.rightUpperArmCFrame = s.rightUpperArmCFrame + offset
			_interpolatedResult.rightLowerArmCFrame = s.rightLowerArmCFrame + offset
			_interpolatedResult.rightHandCFrame = s.rightHandCFrame + offset
			_interpolatedResult.leftUpperLegCFrame = s.leftUpperLegCFrame + offset
			_interpolatedResult.leftLowerLegCFrame = s.leftLowerLegCFrame + offset
			_interpolatedResult.leftFootCFrame = s.leftFootCFrame + offset
			_interpolatedResult.rightUpperLegCFrame = s.rightUpperLegCFrame + offset
			_interpolatedResult.rightLowerLegCFrame = s.rightLowerLegCFrame + offset
			_interpolatedResult.rightFootCFrame = s.rightFootCFrame + offset
			_interpolatedResult.isCrouching = s.isCrouching
			_interpolatedResult.velocity = s.velocity
			return _interpolatedResult
		end
		return s
	end

	local v1 = s1 :: HitboxSnapshot
	local v2 = s2 :: HitboxSnapshot
	local duration = v2.timestamp - v1.timestamp
	if duration <= 0 then return v1 end

	local alpha = math.clamp((targetTime - v1.timestamp) / duration, 0, 1)

	_interpolatedResult.timestamp = targetTime
	_interpolatedResult.rootCFrame = v1.rootCFrame:Lerp(v2.rootCFrame, alpha)
	_interpolatedResult.upperTorsoCFrame = v1.upperTorsoCFrame:Lerp(v2.upperTorsoCFrame, alpha)
	_interpolatedResult.lowerTorsoCFrame = v1.lowerTorsoCFrame:Lerp(v2.lowerTorsoCFrame, alpha)
	_interpolatedResult.headCFrame = v1.headCFrame:Lerp(v2.headCFrame, alpha)
	_interpolatedResult.leftUpperArmCFrame = v1.leftUpperArmCFrame:Lerp(v2.leftUpperArmCFrame, alpha)
	_interpolatedResult.leftLowerArmCFrame = v1.leftLowerArmCFrame:Lerp(v2.leftLowerArmCFrame, alpha)
	_interpolatedResult.leftHandCFrame = v1.leftHandCFrame:Lerp(v2.leftHandCFrame, alpha)
	_interpolatedResult.rightUpperArmCFrame = v1.rightUpperArmCFrame:Lerp(v2.rightUpperArmCFrame, alpha)
	_interpolatedResult.rightLowerArmCFrame = v1.rightLowerArmCFrame:Lerp(v2.rightLowerArmCFrame, alpha)
	_interpolatedResult.rightHandCFrame = v1.rightHandCFrame:Lerp(v2.rightHandCFrame, alpha)
	_interpolatedResult.leftUpperLegCFrame = v1.leftUpperLegCFrame:Lerp(v2.leftUpperLegCFrame, alpha)
	_interpolatedResult.leftLowerLegCFrame = v1.leftLowerLegCFrame:Lerp(v2.leftLowerLegCFrame, alpha)
	_interpolatedResult.leftFootCFrame = v1.leftFootCFrame:Lerp(v2.leftFootCFrame, alpha)
	_interpolatedResult.rightUpperLegCFrame = v1.rightUpperLegCFrame:Lerp(v2.rightUpperLegCFrame, alpha)
	_interpolatedResult.rightLowerLegCFrame = v1.rightLowerLegCFrame:Lerp(v2.rightLowerLegCFrame, alpha)
	_interpolatedResult.rightFootCFrame = v1.rightFootCFrame:Lerp(v2.rightFootCFrame, alpha)
	_interpolatedResult.isCrouching = v1.isCrouching
	_interpolatedResult.velocity = v1.velocity

	return _interpolatedResult
end

-- Returns the raw registry for zero-allocation iteration.
function SnapshotBuffer.GetRegistry(): { [Model]: HistoryBuffer }
	return _registry :: { [Model]: HistoryBuffer }
end

return SnapshotBuffer