<div align="center">
  <img src="Spectre-banner.png" width="100%" alt="Spectre Banner">

  *Server-authoritative, zero-allocation rollback hit validation for Roblox FPS engines*

  [![Version](https://img.shields.io/badge/version-4.1.0-blue)](https://github.com/Jeremy84100/Spectre)
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

-- v4.1.0: Use the built-in Blink network bridge for zero-overhead hit registration.
Spectre.InitNetworkBridge(500, function(shooter, target, zone, mult)
    target.Humanoid:TakeDamage(math.round(40 * mult))
    print("Hit:", zone) -- "Head", "UpperTorso", "LeftLeg", etc.
end)
```

> [!IMPORTANT]
> `Spectre.AutoStart()` automatically hooks `PlayerAdded`, `CharacterAdded`, and the `Heartbeat` loop. **You never need to call anything else.** See the full API below for advanced usage like AoE, Wallbang, and Anti-Spread.


- **Pixel-Perfect R15 Rollback:** Tests 15 anatomical OBB segments per character hierarchically (Head → Torso → Extremities).
- **Blink Network Bridge (v4.1.0):** Binary buffer-based networking via [Blink](https://github.com/1Axen/Blink) replaces standard RemoteEvents, slashing network overhead to the absolute minimum.
- **Environment Penetration (Wallbang):** Calculates material thickness, subtracts kinetic energy based on custom resistance values, and scales damage.
- **Advanced Anti-Cheat Guardrails:** Automatically blocks Teleportation, Lag Switches (Ping clamping), Spread Manipulation, and honors I-Frames (Dashes).
- **AoE Validation:** Native support for grenades/explosives with accurate physical distance falloff mapped dynamically around obstacles and walls.
- **Zero-Allocation Architecture:** Uses pre-allocated ring buffers, shared tables, and heavily optimized C-bridge vectors. It will never thrash the garbage collector.

## Installation

### Dependencies (v4.1.0+)

Spectre v4.1.0 uses [Blink](https://github.com/1Axen/Blink) for binary buffer networking. Install it via [Rokit](https://github.com/rojo-rbx/rokit):

```bash
rokit add 1Axen/blink
```

Then regenerate the network definitions if you modify `src/Network.blink`:

```bash
blink src/Network.blink -y
```

### Manual
1. Clone this repository or download the latest release.
2. Place the contents of the `src` folder into a `ServerScriptService.Spectre` ModuleScript.
3. Place the contents of `src/Shared` into `ReplicatedStorage.SpectreShared` (required for the client-side Blink module).

> [!TIP]
> If you use **Rojo**, the included `default.project.json` handles all of this automatically. Just run `rojo serve` and connect Studio.

## Quick Start

### 1. Initialization
Spectre needs to record character histories on the server every frame. Start the engine once when the server initializes.

```lua
local Spectre = require(game.ServerScriptService.Spectre)

-- Automatically hooks into PlayerAdded/CharacterAdded
-- and starts the Heartbeat recording loop.
Spectre.AutoStart()
```

### 2. Validating a Bullet Hit (v4.1.0 — Blink Bridge)
The recommended approach in v4.1.0 is to use `InitNetworkBridge`. It wires Blink's binary packets directly into the Validator with a single call, with zero boilerplate.

```lua
Spectre.AutoStart()

Spectre.InitNetworkBridge(500, function(shooter, target, zone, mult)
    target.Humanoid:TakeDamage(math.round(40 * mult))
end)
```

**On the client**, fire using the shared Blink module from `ReplicatedStorage`:

```lua
local Network = require(game.ReplicatedStorage.SpectreShared.Network.Client)

-- When the player fires their weapon:
Network.PlayerShoot.Fire({
    ShotTick  = workspace:GetServerTimeNow(),
    Origin    = muzzlePosition,
    Direction = mouseDirection,
    Target    = potentialTarget -- Optional, hints the server
})
```

### 3. Validating a Bullet Hit (Legacy — Raw RemoteEvent)
You can still use the raw validator directly if you prefer managing your own networking.

```lua
game.ReplicatedStorage.FireWeaponEvent.OnServerEvent:Connect(function(shooter, clientTimestamp, origin, direction)
    local targetChar = somePlayer.Character

    local isHit, hitZone, distance, damageMultiplier, reason = Spectre.ValidateHit(
        shooter,             -- Player shooting
        targetChar,          -- Suspected target Model
        origin,              -- Where the shot fired from
        direction,           -- Shot trajectory (Vector3)
        500,                 -- Max weapon range (studs)
        Vector3.zero,        -- Muzzle offset (if any)
        clientTimestamp,     -- Time of the shot on client
        3000,                -- Projectile Speed (Optional)
        25                   -- Weapon Penetration Power (Optional, for Wallbangs)
    )

    if isHit then
        print(string.format("Hit! Zone: %s | Distance: %.1f | Dmg Mult: %.2f", hitZone, distance, damageMultiplier))
    else
        warn("Missed! Reason:", reason)
    end
end)
```

### 4. Validating an Explosion (AoE)
Validate grenades or C4 remotely. Spectre checks Line-of-Sight, verifies wallbang viability, and applies explosive falloff out from the epicenter in the past.

```lua
game.ReplicatedStorage.FireExplosionEvent.OnServerEvent:Connect(function(shooter, clientTimestamp, origin, radius)
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

### 5. Debug Visualization
Ever wanted to literally see what the client saw 200 milliseconds ago? The Visualizer is **enabled by default** when `DEBUG_MODE = true` in Config. Disable it for production.

```lua
local Visualizer = require(game.ServerScriptService.Spectre.Modules.Visualizer)
Visualizer.SetEnabled(false) -- Disable in production
```

> [!TIP]
> Disable the Visualizer in production — `SetEnabled(false)` stops all geometry from being spawned. The zero-allocation guarantee only applies when the Visualizer is off.

## ⚡ Performance Benchmarks

Tested on a standard Roblox Server instance using the native `SimulationTest.server.luau` suite (100% Code Coverage, 28/28 tests passing).

### Micro-Benchmarks (Sub-millisecond Precision)
| Scenario | Operations | Time | Memory Leak |
| :--- | :--- | :--- | :--- |
| **Direct Shot Validation** | 10,000 valid shots | ~46 ms (0.0046 ms/call) | **0.00 KB** |
| **Explosion Physics** | 1,000 massive blasts | ~1.56 ms (0.0016 ms/call) | **0.00 KB** |
| **Ring Buffer Recording** | 1,000 frames/player | N/A | **0.00 KB** |

### Security Gatekeeper Results
- **Zero-Allocation Memory**: Confirmed 100% memory stability (0 bytes allocated on the heap during hit validation loop).
- **Lag Switch Nullified**: `MAX_REWIND_SECONDS` natively clamped absurd network timeline manipulations.
- **Wallbang Robustness**: Multi-pass environment bounding handled cleanly without iteration crashes.
- **I-Frame Integrity**: Successfully phased shots fired during player dash windows.
- **Blink Bridge Verified**: `LagComp_BLINK_RELIABLE_REMOTE` RemoteEvent confirmed present and operational.

> [!TIP]
> Use `--!native` and `--!optimize 2` in your scripts to achieve these aerospace speeds. Math operations for OBB intersections are executed near native-C speed.

## 📚 API Reference

Spectre exposes exactly what you need with zero overhead.

### Initialization & State Management
- `Spectre.AutoStart()`
  *Automatically hooks into `PlayerAdded` and `CharacterAdded` to manage the lifecycle of player hitboxes and starts the `Heartbeat` loop. **Highly recommended.***
- `Spectre.InitNetworkBridge(gunRange: number, onHitVerified: callback)` *(v4.1.0)*
  *Wires the Blink binary network layer directly into the Validator. The callback receives `(shooter, target, zone, mult)` for every verified hit. Replaces boilerplate RemoteEvent plumbing.*
- `Spectre.RegisterCharacter(character: Model)`
  *Manually registers a character for history tracking. Only needed if you are building a custom loop or tracking NPCs.*
- `Spectre.UnregisterCharacter(character: Model)`
  *Manually removes a character from tracking and wipes their history buffer. Automatically called if using `AutoStart()`.*
- `Spectre.RecordAll(timestamp: number)`
  *Manually records a snapshot of all registered characters at the given timestamp. Automatically loops if using `AutoStart()`.*

### Validation Matrix
- `Spectre.ValidateHit(shooter, targetCharacter, rayOrigin, rayDirection, maxRange, muzzleOffset, clientTimestamp, projSpeed?, weaponPenetration?, projRadius?, clientAim?, maxSpread?) -> (boolean, string?, number?, number?, string?)`
  *Performs a historical OBB intersection taking into account latency, lag switches, spread angles, and wallbang environment physics. Returns `isHit`, `hitZone`, `distance`, `damageMultiplier`, and a `rejectReason` if missed.*
- `Spectre.ValidateExplosion(shooter, epicenter, radius, clientTimestamp, explosionPenetration?) -> {[Model]: number}`
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
3. **Blink Network Layer (v4.1.0):** All hit data is transmitted as compact binary buffers. No JSON serialization, no Roblox Instance overhead — pure bytes at wire speed.
4. **Optimized C-Bridge Context:** Raycast filters and RaycastParams are aggressively cached using dirty-flag patterns. Only one Raycast is modified dynamically during wallbang procedures, minimizing cross-boundary latency.

## Changelog

### v4.1.0
- **Added** `Spectre.InitNetworkBridge()` — zero-boilerplate Blink integration.
- **Added** `src/Shared/Network/` — generated `Client.luau` and `Server.luau` Blink modules.
- **Added** `src/Network.blink` — Blink IDL definition for the `PlayerShoot` event.
- **Added** `src/Bridge.luau` — Internal bridge connecting Blink packets to the Validator.
- **Updated** `default.project.json` — Rojo now syncs `src/Shared` to `ReplicatedStorage.SpectreShared` automatically.
- **QA** — Test suite expanded to 28/28 passing tests, including network bridge and RemoteEvent presence validation.

## FAQ

**Q: Does this replace Roblox's Client-Side Raycasting?**
A: No, it complements it. The client should still perform an immediate local raycast to display a hitmarker. Send the shot command to the server via the Blink bridge, and **Spectre** validates it to decide if you actually deal damage.

**Q: Can I use this for Melee combat?**
A: Yes! Use `Spectre.ValidateHit` with a very short max-range and large projectile radius. It accurately calculates melee sweeps.

**Q: Do I need Blink to use Spectre?**
A: No. Blink is an optional but highly recommended dependency for v4.1.0+. You can still call `Spectre.ValidateHit` directly from any standard `OnServerEvent` handler.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
*Built for professional, high-concurrency Roblox experiences.*
