--!strict
-- Spectre / Types.luau
-- Shared type definitions for the zero-allocation R15 full-body tracking system.

-- A complete snapshot of one character's body pose at a precise server timestamp.
-- Each R15 segment has its own CFrame captured directly from the physics state.
export type HitboxSnapshot = {
	timestamp: number,
	-- Torso
	rootCFrame: CFrame,         -- HumanoidRootPart (central pivot)
	upperTorsoCFrame: CFrame,   -- UpperTorso (chest)
	lowerTorsoCFrame: CFrame,   -- LowerTorso (pelvis)
	-- Head
	headCFrame: CFrame,
	-- Left arm
	leftUpperArmCFrame: CFrame,
	leftLowerArmCFrame: CFrame,
	leftHandCFrame: CFrame,
	-- Right arm
	rightUpperArmCFrame: CFrame,
	rightLowerArmCFrame: CFrame,
	rightHandCFrame: CFrame,
	-- Left leg
	leftUpperLegCFrame: CFrame,
	leftLowerLegCFrame: CFrame,
	leftFootCFrame: CFrame,
	-- Right leg
	rightUpperLegCFrame: CFrame,
	rightLowerLegCFrame: CFrame,
	rightFootCFrame: CFrame,
	-- Metadata
	isCrouching: boolean,
	velocity: Vector3,
}

-- Pre-allocated circular ring buffer storing the recent pose history of one character.
export type HistoryBuffer = {
	snapshots: { HitboxSnapshot },
	writeIndex: number,
	count: number,
	isCrouching: boolean,       -- Cached attribute state for zero-overhead access
	_attributeConnection: RBXScriptConnection?,
}

return {}