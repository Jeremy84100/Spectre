--!strict
-- Spectre / Tests / SimulationTest.server.luau
-- Exhaustive QA suite: hit precision, anti-cheat, AoE, memory, and edge cases.

local Spectre = require(script.Parent.Parent)
local Config          = require(script.Parent.Parent.Config)
local SnapshotBuffer  = require(script.Parent.Parent.Core.SnapshotBuffer)
local Visualizer      = require(script.Parent.Parent.Modules.Visualizer)
local RunService      = game:GetService("RunService")

print("==================================================")
print("  STARTING Spectre QA SUITE")
print("==================================================")

-- ─── 1. Fixture setup ─────────────────────────────────────────────────────────

local fakeCharacter = Instance.new("Model")
fakeCharacter.Name = "R15SimDummy"
local fakeRoot = Instance.new("Part")
fakeRoot.Name = "HumanoidRootPart"
fakeRoot.CFrame = CFrame.new(0, 3, 0)
fakeRoot.Parent = fakeCharacter
fakeCharacter.PrimaryPart = fakeRoot

local function makePart(name: string, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.CFrame = cf
	p.Parent = fakeCharacter
	return p
end

local fakeHead = makePart("Head",          CFrame.new(0, 4.5, 0))
local fakeUT   = makePart("UpperTorso",    CFrame.new(0, 3.5, 0))
local fakeLT   = makePart("LowerTorso",    CFrame.new(0, 2.8, 0))
local fakeLUA  = makePart("LeftUpperArm",  CFrame.new(-1.5, 3.5, 0))
local fakeLLA  = makePart("LeftLowerArm",  CFrame.new(-1.5, 2.3, 0))
local fakeLH   = makePart("LeftHand",      CFrame.new(-1.5, 1.5, 0))
local fakeRUA  = makePart("RightUpperArm", CFrame.new(1.5, 3.5, 0))
local fakeRLA  = makePart("RightLowerArm", CFrame.new(1.5, 2.3, 0))
local fakeRH   = makePart("RightHand",     CFrame.new(1.5, 1.5, 0))
local fakeLUL  = makePart("LeftUpperLeg",  CFrame.new(-0.5, 2.0, 0))
local fakeLLL  = makePart("LeftLowerLeg",  CFrame.new(-0.5, 0.7, 0))
local fakeLF   = makePart("LeftFoot",      CFrame.new(-0.5, 0.2, 0))
local fakeRUL  = makePart("RightUpperLeg", CFrame.new(0.5, 2.0, 0))
local fakeRLL  = makePart("RightLowerLeg", CFrame.new(0.5, 0.7, 0))
local fakeRF   = makePart("RightFoot",     CFrame.new(0.5, 0.2, 0))

-- Walls for wallbang tests (parked out of range until needed).
local wall1 = Instance.new("Part")
wall1.Name = "TestWall_Wood"
wall1.Size = Vector3.new(20, 20, 1)
wall1.CFrame = CFrame.new(0, -100, 0)
wall1.Anchored = true
wall1.Material = Enum.Material.Wood  -- Resistance 0.5
wall1.Parent = workspace

local wall2 = Instance.new("Part")
wall2.Name = "TestWall_Metal"
wall2.Size = Vector3.new(20, 20, 1)
wall2.CFrame = CFrame.new(0, -100, 0)
wall2.Anchored = true
wall2.Material = Enum.Material.Metal  -- Resistance 4.0
wall2.Parent = workspace

Spectre.RegisterCharacter(fakeCharacter)

local shooterModel = Instance.new("Model")
local shooterRoot  = Instance.new("Part")
shooterRoot.Name = "HumanoidRootPart"
shooterRoot.Parent = shooterModel
shooterModel.PrimaryPart = shooterRoot
local dummyShooter = { Name = "SniperAI", Character = shooterModel }

-- ─── 2. Ring buffer recording (100 frames — forces multiple wraparounds) ──────

print("Recording R15 history (ring buffer wraparound stress)...")
local currentX = 0
for _ = 1, 100 do
	RunService.Heartbeat:Wait()
	currentX += 1
	local offset = Vector3.new(currentX, 0, 0)
	fakeRoot.CFrame = CFrame.new(0, 3, 0) + offset
	fakeHead.CFrame = CFrame.new(0, 4.5, 0) + offset
	fakeUT.CFrame   = CFrame.new(0, 3.5, 0) + offset
	fakeLT.CFrame   = CFrame.new(0, 2.8, 0) + offset
	fakeLUA.CFrame  = CFrame.new(-1.5, 3.5, 0) + offset
	fakeLLA.CFrame  = CFrame.new(-1.5, 2.3, 0) + offset
	fakeLH.CFrame   = CFrame.new(-1.5, 1.5, 0) + offset
	fakeRUA.CFrame  = CFrame.new(1.5, 3.5, 0) + offset
	fakeRLA.CFrame  = CFrame.new(1.5, 2.3, 0) + offset
	fakeRH.CFrame   = CFrame.new(1.5, 1.5, 0) + offset
	fakeLUL.CFrame  = CFrame.new(-0.5, 2.0, 0) + offset
	fakeLLL.CFrame  = CFrame.new(-0.5, 0.7, 0) + offset
	fakeLF.CFrame   = CFrame.new(-0.5, 0.2, 0) + offset
	fakeRUL.CFrame  = CFrame.new(0.5, 2.0, 0) + offset
	fakeRLL.CFrame  = CFrame.new(0.5, 0.7, 0) + offset
	fakeRF.CFrame   = CFrame.new(0.5, 0.2, 0) + offset
	Spectre.RecordAll(workspace:GetServerTimeNow())
end

local serverNow = workspace:GetServerTimeNow()

-- ─── 3. Test runner ───────────────────────────────────────────────────────────

local passedTests = 0
local totalTests  = 0

local function assertTest(testName: string, condition: boolean, details: string)
	totalTests += 1
	if condition then
		passedTests += 1
		print(string.format("[PASSED] %s", testName))
	else
		warn(string.format("[FAILED] %s | %s", testName, details))
	end
end

local function runHitTest(
	testName: string,
	ping: number,
	targetY: number,
	projSpeed: number?,
	weaponPen: number?,
	expectHit: boolean,
	expectZone: string?,
	customShooterPos: Vector3?,
	aimDir: Vector3?,
	spread: number?
)
	local travelTime  = if projSpeed then (10 / projSpeed) else 0
	local totalRewind = math.clamp(ping + Config.INTERPOLATION_BUFFER + travelTime, 0, Config.MAX_REWIND_SECONDS)
	local rewindTime  = serverNow - totalRewind

	local snap = SnapshotBuffer.GetInterpolatedSnapshot(fakeCharacter, rewindTime)
	local expectedX = if snap then snap.rootCFrame.Position.X else currentX

	local originPos = customShooterPos or Vector3.new(expectedX, targetY, -10)
	shooterRoot.Position = originPos
	local shootDir = Vector3.new(0, 0, 1)

	local hit, zone = Spectre.ValidateHit(
		dummyShooter :: any, fakeCharacter, originPos, shootDir, 100, Vector3.zero, serverNow - ping, projSpeed, weaponPen, nil, aimDir, spread
	)

	assertTest(testName, (hit == expectHit) and (zone == expectZone),
		string.format("Expected: %s (%s) | Got: %s (%s)", tostring(expectHit), tostring(expectZone), tostring(hit), tostring(zone)))
end

-- ─── 4. Test execution ────────────────────────────────────────────────────────

print("\n--- RAY-OBB PRECISION ---")
runHitTest("Hitbox 1: Headshot",                        0.2, 4.5, nil, 10, true,  "Head")
runHitTest("Hitbox 2: Upper Torso",                     0.2, 3.5, nil, 10, true,  "UpperTorso")
runHitTest("Hitbox 3: Lower Leg",                       0.2, 0.7, nil, 10, true,  "LeftLowerLeg")
runHitTest("Hitbox 4: Complete Miss (Broad-Phase Drop)", 0.2, 100, nil, 10, false, nil)

print("\n--- ANTI-CHEAT GUARDS ---")
runHitTest("Hack 1: Anti-Teleport",                  0.2, 3.5, nil, 10, false, nil, Vector3.new(1000, 3.5, -10))
local lagHackX = currentX - (60 * 5.0)
runHitTest("Hack 2: Lag Switch (MAX_REWIND clamp)",  5.0, 3.5, nil, 10, false, nil, Vector3.new(lagHackX, 3.5, -10))
runHitTest("Hack 3: Aimbot / Anti-Spread",           0.2, 3.5, nil, 10, false, nil, nil, Vector3.new(1, 0, 0), 5)

print("\n--- WALLBANG ---")
local snapWall = SnapshotBuffer.GetInterpolatedSnapshot(fakeCharacter, serverNow - (0.2 + Config.INTERPOLATION_BUFFER))
local wallX = if snapWall then snapWall.rootCFrame.Position.X else 0

wall1.CFrame = CFrame.new(wallX, 3, -5)
runHitTest("Wallbang 1: Zero penetration blocked",           0.2, 3.5, nil, 0,  false, nil)
runHitTest("Wallbang 2: Wood penetrated (pen 10)",           0.2, 3.5, nil, 10, true,  "UpperTorso")

wall2.CFrame = CFrame.new(wallX, 3, -3)
-- Wood costs 0.5, Metal costs 4.0 → 2.5 remaining < 4.0 → BLOCKED.
runHitTest("Wallbang 3: Wood + Metal double wall blocked",   0.2, 3.5, nil, 3,  false, nil)
runHitTest("Wallbang 4: Both walls penetrated (railgun 50)", 0.2, 3.5, nil, 50, true,  "UpperTorso")

wall1.CFrame = CFrame.new(0, -100, 0)
wall2.CFrame = CFrame.new(0, -100, 0)

print("\n--- AoE EXPLOSIONS ---")
local function runAoETest(testName: string, origin: Vector3, radius: number, pen: number?, expectedMultiplier: number)
	local results = Spectre.ValidateExplosion(dummyShooter :: any, origin, radius, serverNow - 0.2, pen)
	local result  = results[fakeCharacter] or 0
	local passed  = math.abs(result - expectedMultiplier) < 0.02
	assertTest(testName, passed, string.format("Expected: %.2f | Got: %.2f", expectedMultiplier, result))
end

local snapAoE    = SnapshotBuffer.GetInterpolatedSnapshot(fakeCharacter, serverNow - (0.2 + Config.INTERPOLATION_BUFFER))
local aoeTarget  = if snapAoE then snapAoE.upperTorsoCFrame.Position else Vector3.zero

runAoETest("AoE 1: Direct hit (center)",          aoeTarget,                              10, 0,  1.0)
runAoETest("AoE 2: Falloff at half radius",        aoeTarget + Vector3.new(0, 0, 5),      10, 0,  0.5)
runAoETest("AoE 3: Out of range",                  aoeTarget + Vector3.new(0, 0, 15),     10, 0,  0.0)

wall2.CFrame = CFrame.new(aoeTarget.X, 3, aoeTarget.Z + 2)
runAoETest("AoE 4: Blocked by metal wall",         aoeTarget + Vector3.new(0, 0, 5),      10, 0,  0.0)
-- Metal resistance 4.0, thickness ~1 stud → energyCost=4, wallMult=1-(4/50)=0.92, final=0.5*0.92≈0.46.
runAoETest("AoE 5: Explosive wallbang (C4, pen 50)", aoeTarget + Vector3.new(0, 0, 5),   10, 50, 0.46)
wall2.CFrame = CFrame.new(0, -100, 0)

print("\n--- SNAPSHOT BUFFER ---")
local futureSnap = SnapshotBuffer.GetInterpolatedSnapshot(fakeCharacter, serverNow + 10)
assertTest("Buffer 1: Extrapolation limit", futureSnap ~= nil, "Extrapolation returned nil.")

local ancientSnap = SnapshotBuffer.GetInterpolatedSnapshot(fakeCharacter, serverNow - 100)
assertTest("Buffer 2: Oldest snapshot fallback", ancientSnap ~= nil, "Buffer crashed on ancient timestamp.")

Spectre.UnregisterCharacter(fakeCharacter)
local fakeStillInRegistry = SnapshotBuffer.GetRegistry()[fakeCharacter] ~= nil
assertTest("Buffer 3: Unregister zero-leak", not fakeStillInRegistry, "Dummy still in registry after unregister.")

-- Re-register with fresh snapshots for the benchmark.
Spectre.RegisterCharacter(fakeCharacter)
for _ = 1, 10 do
	RunService.Heartbeat:Wait()
	Spectre.RecordAll(workspace:GetServerTimeNow())
end
serverNow = workspace:GetServerTimeNow()

print("\n--- EDGE CASES ---")

-- Edge 1: Zero-magnitude direction → should be caught by the NaN guard.
do
	local hit = Spectre.ValidateHit(
		dummyShooter :: any, fakeCharacter,
		Vector3.new(currentX, 3.5, -10), Vector3.zero,
		100, Vector3.zero, serverNow - 0.1
	)
	assertTest("Edge 1: Zero direction (NaN guard)", hit == false, "NaN guard failed.")
end

-- Edge 2: Unregistered target (freshly dead character).
do
	local ghostCharacter = Instance.new("Model")
	local ghostRoot = Instance.new("Part")
	ghostRoot.Name = "HumanoidRootPart"
	ghostRoot.Parent = ghostCharacter
	ghostCharacter.PrimaryPart = ghostRoot
	local hit = Spectre.ValidateHit(
		dummyShooter :: any, ghostCharacter,
		Vector3.new(currentX, 3.5, -10), Vector3.new(0, 0, 1),
		100, Vector3.zero, serverNow - 0.1
	)
	assertTest("Edge 2: Unregistered target (0 snapshots)", hit == false, "Hit on ghost character succeeded.")
	ghostCharacter:Destroy()
end

-- Edge 3: I-Frame window (dash invincibility).
do
	local rewindTimeDash = serverNow - (0.1 + Config.INTERPOLATION_BUFFER)
	fakeCharacter:SetAttribute("LastDashTime", rewindTimeDash - 0.05)
	local hit = Spectre.ValidateHit(
		dummyShooter :: any, fakeCharacter,
		Vector3.new(currentX, 3.5, -10), Vector3.new(0, 0, 1),
		100, Vector3.zero, serverNow - 0.1
	)
	assertTest("Edge 3: I-Frame (dash invincibility)", hit == false, "Shot passed through I-Frame window.")
	fakeCharacter:SetAttribute("LastDashTime", nil)
end

-- Edge 4: Ring buffer wraparound — interpolation across slot boundary must be monotonic.
do
	local snapRecent = SnapshotBuffer.GetInterpolatedSnapshot(fakeCharacter, serverNow - 0.05)
	local snapOld    = SnapshotBuffer.GetInterpolatedSnapshot(fakeCharacter, serverNow - 0.35)
	local coherent = (snapRecent ~= nil) and (snapOld ~= nil)
		and (snapRecent.timestamp > snapOld.timestamp)
	assertTest("Edge 4: Ring buffer wraparound coherence", coherent,
		string.format("Timestamps incoherent: recent=%.4f old=%.4f",
			if snapRecent then snapRecent.timestamp else -1,
			if snapOld    then snapOld.timestamp    else -1))
end

-- Edge 5: Multi-registry — 5 characters registered and cleanly unregistered.
do
	local dummies: { Model } = {}
	for i = 1, 5 do
		local m = Instance.new("Model")
		local r = Instance.new("Part")
		r.Name = "HumanoidRootPart"
		r.CFrame = CFrame.new(i * 10, 3, 0)
		r.Parent = m
		m.PrimaryPart = r
		Spectre.RegisterCharacter(m)
		table.insert(dummies, m)
	end
	for _ = 1, 3 do
		RunService.Heartbeat:Wait()
		Spectre.RecordAll(workspace:GetServerTimeNow())
	end
	local countBefore = 0
	for _ in SnapshotBuffer.GetRegistry() do countBefore += 1 end
	for _, m in dummies do
		Spectre.UnregisterCharacter(m)
		m:Destroy()
	end
	local countAfter = 0
	for _ in SnapshotBuffer.GetRegistry() do countAfter += 1 end
	assertTest("Edge 5: Multi-registry (5 characters + cleanup)",
		countAfter == countBefore - 5,
		string.format("Before: %d | After: %d (expected delta: -5)", countBefore, countAfter))
end

-- Edge 6: No timestamp (instant weapon — shotgun, laser). latencyRewind = 0; must not crash.
do
	local hitNoTs = Spectre.ValidateHit(
		dummyShooter :: any, fakeCharacter,
		Vector3.new(currentX, 3.5, -20), Vector3.new(0, 0, 1),
		500, Vector3.zero, nil
	)
	assertTest("Edge 6: Nil timestamp (instant weapon)", hitNoTs == true or hitNoTs == false,
		"Call crashed on nil timestamp.")
end

-- Edge 7: Visualizer cleanup — parts must be auto-destroyed after DEBUG_DURATION.
do
	Visualizer.SetEnabled(true)
	Visualizer.ShowBox(CFrame.new(0, 100, 0), Vector3.new(1, 1, 1), Color3.new(1, 0, 0))
	Visualizer.ShowRay(Vector3.new(0, 100, 0), Vector3.new(0, 1, 0), 10, Color3.new(0, 1, 0))

	local folder = workspace:FindFirstChild("Spectre_Debug")
	local partsSpawned = folder and folder:FindFirstChild("DebugBox") and folder:FindFirstChild("DebugRay") and true or false

	task.wait(Config.DEBUG_DURATION + 0.1)

	local partsDestroyed = not folder or (not folder:FindFirstChild("DebugBox") and not folder:FindFirstChild("DebugRay"))

	assertTest("Edge 7: Visualizer cleanup (zero-closure task.delay)", partsSpawned and partsDestroyed,
		string.format("Spawned: %s | Destroyed: %s", tostring(partsSpawned), tostring(partsDestroyed)))

	if folder then folder:ClearAllChildren() end
end

-- ─── 5. Performance benchmark (10 000 hits + 1 000 explosions) ───────────────

print(string.format("\nQA SCORE: %d / %d PASSED", passedTests, totalTests))

print("\n--- PERFORMANCE BENCHMARK ---")
task.wait(1)
gcinfo()

Visualizer.SetEnabled(false)

local originPosBench = Vector3.new(currentX, 3.5, -20)
shooterRoot.Position = originPosBench
local shootDirBench = Vector3.new(0, 0, 1)

local startMem  = gcinfo()
local startTime = os.clock()

for _ = 1, 10000 do
	Spectre.ValidateHit(dummyShooter :: any, fakeCharacter, originPosBench, shootDirBench, 500, Vector3.zero, serverNow - 0.05)
end
local timeHitMs = (os.clock() - startTime) * 1000

local startExploTime = os.clock()
for _ = 1, 1000 do
	Spectre.ValidateExplosion(dummyShooter :: any, originPosBench, 50, serverNow - 0.05, 100)
end
local timeExploMs = (os.clock() - startExploTime) * 1000

local memUsedKb = gcinfo() - startMem

Visualizer.SetEnabled(Config.DEBUG_MODE)

print(string.format("10 000 ValidateHit     : %.2f ms  (%.4f ms/call)", timeHitMs,   timeHitMs   / 10000))
print(string.format(" 1 000 ValidateExplosion: %.2f ms  (%.4f ms/call)", timeExploMs, timeExploMs / 1000))

if memUsedKb <= 0 then
	print("ZERO ALLOCATION: heap unchanged.")
else
	warn("MEMORY LEAK: " .. memUsedKb .. " KB allocated on heap.")
end

print("==================================================")

-- ─── Cleanup ──────────────────────────────────────────────────────────────────
Spectre.UnregisterCharacter(fakeCharacter)
fakeCharacter:Destroy()
shooterModel:Destroy()
wall1:Destroy()
wall2:Destroy()