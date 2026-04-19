--!strict
-- Spectre / Config.luau
-- All tunable constants for the rollback lag-compensation system.
-- Tweak these to fit your game's speed, hitbox sizes, and network conditions.

return table.freeze({
    -- ─── Timing ──────────────────────────────────────────────────
    MAX_REWIND_SECONDS = 0.5,
    -- Furthest back in time (seconds) the server will rewind for a hit claim.
    -- Raise for high-latency tolerance; lower to tighten the anti-cheat window.

    DASH_INVINCIBILITY_DURATION = 0.3,
    -- Duration (seconds) of I-Frames granted after a dash.
    -- Shots landing within this window in the past are rejected.

    INTERPOLATION_BUFFER = 0.1,
    -- Extra rewind (seconds) to compensate for Roblox's ~20 Hz character replication delay.

    MAX_EXTRAPOLATION_SECONDS = 0.25,
    -- Maximum time (seconds) allowed for position prediction during packet loss.
    -- Prevents lagging-out characters from traveling through walls.

    PROJECTILE_GRAVITY = workspace.Gravity,
    -- Downward acceleration (studs/sec²) used when calculating bullet drop.

    -- ─── Anti-wallbang ───────────────────────────────────────────
    IGNORE_UNANCHORED_PARTS = true,
    -- When true, unanchored parts are skipped during the line-of-sight check.
    -- Prevents shots being rejected by a door that closed during the lag interval.

    MAX_LOS_ITERATIONS = 5,
    MAX_WALLBANG_PROBE_DISTANCE = 8.0, -- Maximum penetrable wall thickness (studs).

    MATERIAL_RESISTANCE = table.freeze({
        [Enum.Material.Wood]         = 0.5,
        [Enum.Material.WoodPlanks]   = 0.5,
        [Enum.Material.Fabric]       = 0.2,
        [Enum.Material.Grass]        = 0.3,
        [Enum.Material.Plastic]      = 0.8,
        [Enum.Material.Glass]        = 0.3,
        [Enum.Material.Sand]         = 1.2,
        [Enum.Material.Concrete]     = 2.0,
        [Enum.Material.Brick]        = 1.8,
        [Enum.Material.Metal]        = 4.0,
        [Enum.Material.DiamondPlate] = 4.5,
        [Enum.Material.ForceField]   = math.huge, -- Impenetrable.
    }),
    DEFAULT_MATERIAL_RESISTANCE = 1.0,

    -- ─── Shot-origin validation ───────────────────────────────────
    MAX_ORIGIN_DISTANCE = 12,
    -- Base tolerance (studs): max deviation between reported and rewound shooter position.
    -- Scaled up at runtime by latency × speed.

    MAX_PLAYER_SPEED = 60,
    -- Top movement speed (studs/sec) used to widen origin tolerance at high latency.

    -- ─── Snapshot buffer ─────────────────────────────────────────
    BUFFER_CAPACITY = 24,
    -- Snapshot slots per character. At 60 Hz this covers ~400 ms of history,
    -- comfortably exceeding MAX_REWIND_SECONDS.

    -- ─── R15 hitbox geometry ─────────────────────────────────────
    -- Size of each body segment in studs: Vector3(width, height, depth).
    HEAD_SIZE         = Vector3.new(1.3, 1.3, 1.3),
    UPPER_TORSO_SIZE  = Vector3.new(2.0, 1.6, 1.0),
    LOWER_TORSO_SIZE  = Vector3.new(2.0, 0.4, 1.0),
    UPPER_ARM_SIZE    = Vector3.new(1.0, 1.2, 1.0),
    LOWER_ARM_SIZE    = Vector3.new(1.0, 1.2, 1.0),
    HAND_SIZE         = Vector3.new(0.6, 0.6, 0.6),
    UPPER_LEG_SIZE    = Vector3.new(1.0, 1.5, 1.0),
    LOWER_LEG_SIZE    = Vector3.new(1.0, 1.5, 1.0),
    FOOT_SIZE         = Vector3.new(1.0, 0.4, 1.2),

    -- Broad-phase AABB centered on HumanoidRootPart.
    -- If the ray misses this box, all 15 granular OBB tests are skipped.
    CHARACTER_BOUNDING_BOX_SIZE = Vector3.new(4, 7, 3),

    -- ─── Crouch overrides ────────────────────────────────────────
    CROUCH_UPPER_TORSO_SIZE = Vector3.new(2.0, 1.0, 1.0),

    -- ─── R15 part names (lookup table) ───────────────────────────
    -- Official R15 part names used by SnapshotBuffer for FindFirstChild lookups.
    R15_PART_NAMES = table.freeze({
        "Head",
        "UpperTorso", "LowerTorso",
        "LeftUpperArm", "LeftLowerArm", "LeftHand",
        "RightUpperArm", "RightLowerArm", "RightHand",
        "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
        "RightUpperLeg", "RightLowerLeg", "RightFoot",
    }),

    -- ─── Validation leniency ─────────────────────────────────────
    ROLLBACK_FORGIVENESS = Vector3.new(0.2, 0.2, 0.2),
    -- Extra size (studs) added to each hitbox during ray-OBB tests.
    -- Keep small to maintain pixel-perfect accuracy.

    -- ─── Debug ───────────────────────────────────────────────────
    DEBUG_MODE = true,
    -- Spawns ghost boxes and rays in workspace for each validation call.
    -- Disable in production.

    DEBUG_DURATION = 1.5,
    -- Seconds the debug visuals persist before being auto-destroyed.
})