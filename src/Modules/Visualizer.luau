--!strict
--!native
--!optimize 2
-- Spectre / Modules / Visualizer.luau
-- Renders debug ghost boxes and shot rays in workspace during development.

local Config = require(script.Parent.Parent.Config)

local Visualizer = {}

local _debugFolder: Folder? = nil
local _enabled: boolean = true

-- ─── Pre-configured templates (C-bridge optimization) ─────────────────────────
-- Cloning a pre-configured template is significantly faster than setting
-- 8+ properties individually on each call.
local _boxTemplate = Instance.new("Part")
_boxTemplate.Name = "DebugBox"
_boxTemplate.Anchored = true
_boxTemplate.CanCollide = false
_boxTemplate.CanTouch = false
_boxTemplate.CanQuery = false
_boxTemplate.CastShadow = false
_boxTemplate.Material = Enum.Material.ForceField
_boxTemplate.Transparency = 0.5

local _rayTemplate = Instance.new("Part")
_rayTemplate.Name = "DebugRay"
_rayTemplate.Anchored = true
_rayTemplate.CanCollide = false
_rayTemplate.CanTouch = false
_rayTemplate.CanQuery = false
_rayTemplate.CastShadow = false
_rayTemplate.Material = Enum.Material.ForceField
_rayTemplate.Transparency = 0.5
_rayTemplate.Size = Vector3.new(0.05, 0.05, 1)

-- ─── Private ──────────────────────────────────────────────────────────────────

local function getDebugFolder(): Folder
	if _debugFolder and _debugFolder.Parent == workspace then
		return _debugFolder
	end

	local folder = workspace:FindFirstChild("Spectre_Debug")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Spectre_Debug"
		folder.Parent = workspace
	end

	_debugFolder = folder :: Folder
	return _debugFolder :: Folder
end

-- ─── Public API ───────────────────────────────────────────────────────────────

-- Enables or disables the visualizer (useful during benchmarks).
function Visualizer.SetEnabled(enabled: boolean)
	_enabled = enabled
end

-- Renders a hitbox ghost in the world for DEBUG_DURATION seconds.
function Visualizer.ShowBox(cframe: CFrame, size: Vector3, color: Color3)
	if not _enabled then return end

	local box = _boxTemplate:Clone()
	box.Color = color
	box.Size = size
	box.CFrame = cframe
	box.Parent = getDebugFolder()

	task.delay(Config.DEBUG_DURATION, game.Destroy, box)
end

-- Renders a shot ray in the world for DEBUG_DURATION seconds.
function Visualizer.ShowRay(origin: Vector3, direction: Vector3, length: number, color: Color3)
	if not _enabled then return end

	local ray = _rayTemplate:Clone()
	ray.Color = color

	local distance = math.min(direction.Magnitude, length)
	ray.Size = Vector3.new(0.2, 0.2, distance)
	ray.CFrame = CFrame.lookAt(origin + direction.Unit * (distance / 2), origin + direction)
	ray.Parent = getDebugFolder()

	task.delay(Config.DEBUG_DURATION, game.Destroy, ray)
end

return Visualizer
