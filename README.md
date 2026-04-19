<div align="center">
  <img src="Spectre-banner.png" width="100%" alt="Spectre Banner">

  *Server-authoritative, zero-allocation rollback hit validation for Roblox FPS engines*

  [![Version](https://img.shields.io/badge/version-1.0.0-blue)](https://github.com/Jeremy84100/Spectre)
  [![Platform](https://img.shields.io/badge/Roblox-00A2FF?logo=roblox&logoColor=white)](https://roblox.com)
  [![Luau](https://img.shields.io/badge/Luau-Strict-FF5A0E)](https://luau-lang.org)
  [![Performance](https://img.shields.io/badge/Performance-Zero--Allocation-brightgreen)](https://github.com/Jeremy84100/Spectre)
  [![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

  ⭐ If you like this project, star it on GitHub!

  [Overview](#overview) • [Key Features](#key-features) • [Installation](#installation) • [Benchmarks](#-performance-benchmarks) • [FAQ](#faq)

</div>

**Spectre** is a strictly-typed, ultra-high-performance server-authoritative hit validation framework designed to power professional shooter experiences on Roblox. By maintaining a historical **O(1) Circular Buffer** of every player's exact anatomical hitbox, Spectre allows the server to look into the past (rollback) and perfectly replicate what the shooter saw on their screen.

Zero yielding. Zero memory leaks. Zero trust in the client.

## ⚡ 30-Second Quick Start

```lua
-- ServerScriptService / YourWeaponHandler.server.lua
local Spectre = require(game.ServerScriptService.Spectre)
Spectre.AutoStart() -- One line. Handles everything automatically.

game.ReplicatedStorage.FireRemote.OnServerEvent:Connect(function(shooter, targetChar, origin, direction, timestamp)
    local isHit, hitZone, distance, dmgMult = Spectre.ValidateHit(
        shooter, targetChar, origin, direction,
        500,        -- Max weapon range (studs)
        nil,        -- Muzzle offset (optional, defaults to Vector3.zero)
        timestamp   -- workspace:GetServerTimeNow() captured on the client
    )
    if isHit then
        targetChar.Humanoid:TakeDamage(math.round(40 * dmgMult))
        print("Hit:", hitZone) -- "Head", "UpperTorso", "LeftLeg", etc.
    end
end)
```

> [!IMPORTANT]
> `Spectre.AutoStart()` automatically hooks `PlayerAdded`, `CharacterAdded`, and the `Heartbeat` loop. **You never need to call anything else.** See the full API below for advanced usage like AoE, Wallbang, and Anti-Spread.


- **Pixel-Perfect R15 Rollback:** Tests 15 anatomical OBB segments per character hierarchically (Head → Torso → Extremities).
- **Environment Penetration (Wallbang):** Calculates material thickness, subtracts kinetic energy based on custom resistance values, and scales damage.
- **Advanced Anti-Cheat Guardrails:** Automatically blocks Teleportation, Lag Switches (Ping clamping), Spread Manipulation, and honors I-Frames (Dashes).
- **AoE Validation:** Native support for grenades/explosives with accurate physical distance falloff mapped dynamically around obstacles and walls.
- **Zero-Allocation Architecture:** Uses pre-allocated ring buffers, shared tables, and heavily optimized C-bridge vectors. It will never thrash the garbage collector.

## Installation

### Manual
1. Clone this repository or download the latest release.
2. Place the contents of the `src` folder into a ModuleScript named `Spectre`.
3. Locate `Spectre` in `ServerScriptService`.

## Quick Start

### 1. Initialization
Spectre needs to record character histories on the server every frame. Start the engine once when the server initializes.

```lua
local Spectre = require(game.ServerScriptService.Spectre)

-- Automatically hooks into PlayerAdded/CharacterAdded
-- and starts the Heartbeat recording loop.
Spectre.AutoStart()
```

### 2. Validating a Bullet Hit
When a client clicks, they send a remote to the server claiming a timeline (their ping timestamp), an origin point, and a direction. Spectre travels back to that exact timeline to judge the accuracy.

```lua
game.ReplicatedStorage.FireWeaponEvent.OnServerEvent:Connect(function(shooter, clientTimestamp, origin, direction)
    -- Target filtering logic...
    local targetChar = somePlayer.Character 
    
    local isHit, hitZone, distance, damageMultiplier, reason = Spectre.ValidateHit(
        shooter,             -- Player shooting
        targetChar,          -- Suspected target Model
        origin,              -- Where the shot fired from
        direction,           -- Shot trajectory (Vector3)
        500,                 -- Max weapon range (studs)
        Vector3.zero,        -- Muzzle offset (if any)
        clientTimestamp,     -- Time of the shot on client
        3000,                -- Projectile Speed (Optional, calculates bullet drop & travel limits)
        25                   -- Weapon Penetration Power (Optional, for Wallbangs)
    )

    if isHit then
        print(string.format("Hit! Zone: %s | Distance: %.1f | Dmg Mult: %.2f", hitZone, distance, damageMultiplier))
        -- Apply damage based on hitZone (e.g., Headshot = 2x multiplier)
    else
        warn("Missed! Reason:", reason)
    end
end)
```

### 3. Validating an Explosion (AoE)
Validate grenades or C4 remotely. Spectre checks Line-of-Sight, verifies wallbang viability, and applies explosive falloff out from the epicenter in the past.

```lua
game.ReplicatedStorage.FireExplosionEvent.OnServerEvent:Connect(function(shooter, clientTimestamp, origin, radius)
    
    -- Evaluates all players globally and returns a map of damage multipliers for whoever was hit!
    local hitMap = Spectre.ValidateExplosion(
        shooter,         -- Person throwing the grenade
        origin,          -- Epicenter of the blast
        radius,          -- Blast radius (studs)
        clientTimestamp, -- Time of the throw
        10               -- Penetration (Blast goes through wood, blocked by metal) 
    )

    for character, damageMult in hitMap do
        local baseDamage = 100
        character.Humanoid:TakeDamage(math.round(baseDamage * damageMult))
    end
end)
```

### 4. Debug Visualization
Ever wanted to literally see what the client saw 200 milliseconds ago? The Visualizer is **enabled by default** when `DEBUG_MODE = true` in Config. Disable it for production.

```lua
-- The Visualizer is active by default when DEBUG_MODE is enabled.
-- Call SetEnabled(false) to disable it at runtime (e.g., during benchmarks or in production).
local Visualizer = require(game.ServerScriptService.Spectre.Modules.Visualizer)
Visualizer.SetEnabled(false) -- Disable in production
```

> [!TIP]
> Disable the Visualizer in production — `SetEnabled(false)` stops all geometry from being spawned. The zero-allocation guarantee only applies when the Visualizer is off.

## ⚡ Performance Benchmarks

Tested on a standard Roblox Server instance using the native `SimulationTest.server.luau` suite (100% Code Coverage metrics).

### Micro-Benchmarks (Sub-millisecond Precision)
| Scenario | Operations | Time | Memory Leak |
| :--- | :--- | :--- | :--- |
| **Direct Shot Validation** | 10,000 valid shots | 45.26 ms (0.0045 ms/call) | **0.00 KB** |
| **Explosion Physics** | 1,000 massive blasts | 1.55 ms (0.0016 ms/call) | **0.00 KB** |
| **Ring Buffer Recording** | 1,000 frames/player | N/A | **0.00 KB** |

### Security Gatekeeper Results
- **Zero-Allocation Memory**: Confirmed 100% memory stability (0 bytes allocated on the heap during hit validation loop).
- **Lag Switch Nullified**: `MAX_REWIND_SECONDS` natively clamped absurd network timeline manipulations.
- **Wallbang Robustness**: Multi-pass environment bounding handled cleanly without iteration crashes.
- **I-Frame Integrity**: Successfully phased shots fired during player dash windows.

> [!TIP]
> Use `--!native` and `--!optimize 2` in your scripts to achieve these aerospace speeds. Math operations for OBB intersections are executed near native-C speed.

## 📚 API Reference

Spectre exposes exactly what you need with zero overhead.

### Initialization & State Management
- `Spectre.AutoStart()`
  *Automatically hooks into `PlayerAdded` and `CharacterAdded` to manage the lifecycle of player hitboxes and starts the `Heartbeat` loop. **Highly recommended.***
- `Spectre.RegisterCharacter(character: Model)`
  *Manually registers a character for history tracking. Only needed if you are building a custom loop or tracking NPCs.*
- `Spectre.UnregisterCharacter(character: Model)`
  *Manually removes a character from tracking and wipes their history buffer. Automatically called if using `AutoStart()`.*
- `Spectre.RecordAll(timestamp: number)`
  *Manually records a snapshot of all registered characters at the given timestamp. Automatically loops if using `AutoStart()`.*

### Validation Matrix
- `Spectre.ValidateHit(shooter: Player, targetCharacter: Model, rayOrigin: Vector3?, rayDirection: Vector3?, maxRange: number, muzzleOffset: Vector3, clientTimestamp: number?, projSpeed: number?, weaponPenetration: number?, projRadius: number?, clientAim: Vector3?, maxSpread: number?) -> (boolean, string?, number?, number?, string?)`
  *Performs a historical OBB intersection taking into account latency, lag switches, spread angles, and wallbang environment physics. Returns `isHit`, `hitZone`, `distance`, `damageMultiplier`, and a `rejectReason` if missed.*
- `Spectre.ValidateExplosion(shooter: Player, epicenter: Vector3, radius: number, clientTimestamp: number, explosionPenetration: number?) -> {[Model]: number}`
  *Rolls back all players, calculates Line-of-Sight from the blast center, applies Wallbang penetration, and calculates a scaled damage multiplier (0.0 to 1.0) for every hit character.*

### Configuration (`src/Config.luau`)
Spectre is highly tunable. Everything from Wallbang resistance to hitbox expansion is centralized in the Configuration module.

**Timing & Network:**
- `MAX_REWIND_SECONDS` (0.5s): Maximum accepted latency for rollback. Clamps severe Lag Switches.
- `DASH_INVINCIBILITY_DURATION` (0.3s): I-Frame duration where hits are rejected.
- `INTERPOLATION_BUFFER` (0.1s): Extra rewind to pad Roblox's native 20Hz character replication.
- `MAX_EXTRAPOLATION_SECONDS` (0.25s): Position prediction limits for lagging characters.

**Environment & Wallbangs:**
- `MAX_WALLBANG_PROBE_DISTANCE` (8.0 studs): Maximum penetrable wall thickness.
- `MATERIAL_RESISTANCE`: A dictionary mapping Roblox materials to kinetic resistance multipliers (e.g., `Metal = 4.0`, `Wood = 0.5`).
- `IGNORE_UNANCHORED_PARTS` (true): Skips physically active parts like open/closing doors during rollback queries.

**Geometry & Precision:**
- `BUFFER_CAPACITY` (24): Number of historical snapshots stored per character (~400ms at 60Hz).
- `ROLLBACK_FORGIVENESS` (0.2 studs): An invisible vector expansion added to all hitboxes. Favors the shooter against mathematical float discrepancies.
- `MAX_ORIGIN_DISTANCE` (12 studs): Permitted deviation between the shooter's stated physical origin and their actual server-rollback origin. Scaled by `MAX_PLAYER_SPEED`.

**Debug Elements:**
- `DEBUG_MODE`: Toggles the generation of 3D ghost rigs and line traces during validation.
- `DEBUG_DURATION` (1.5s): Auto-cleanup time for debug visualizations.

## Architecture

Traditional Roblox "hitboxes" rely on server-side `.Touched` events or simplistic raycasts, leading to intense input latency or "I was behind a wall!" ghost shots. **Spectre** is built differently:

1. **True R15 Fidelity:** We perform Minkowski-summed math intersections. No physical parts are cloned into the workspace to test shots.
2. **Circular Buffer History:** To avoid garbage collector thrashing via `table.insert` / `table.remove`, the history tracking uses 1D flattened arrays with looping read/write heads.
3. **Optimized C-Bridge Context:** Raycast filters and RaycastParams are aggressively cached using dirty-flag patterns. Only one Raycast is modified dynamically during wallbang procedures, minimizing cross-boundary latency.

## FAQ

**Q: Does this replace Roblox's Client-Side Raycasting?**  
A: No, it complements it. The client should still perform an immediate local raycast to display a hitmarker. Send the shot command to the server, and **Spectre** validates it to decide if you actually deal damage.

**Q: Can I use this for Melee combat?**  
A: Yes! Use `Spectre.ValidateHit` with a very short max-range and large projectile radius. It accurately calculates melee sweeps.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
*Built for professional, high-concurrency Roblox experiences.*
