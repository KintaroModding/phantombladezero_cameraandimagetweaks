# Camera and Image Tweaks

Field of view, camera distance, lock-on height, an ultrawide cutscene fix, ultrawide HUD placement, and switches for chromatic aberration, vignette, depth of field, lens flares and bloom. Change them in game in a keyboard panel (F9) or in config.lua, live.

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for Phantom Blade Zero (Unreal Engine 5.7), made with
game version `CL-302256_JKS-17280` and UE4SS `v3.0.1-1195-g1ceefac8`, tested in game with UE4SS `v4.0.0` (1.1,
2026-11-13). This README is for developers; what the mod does and
how to install it are in [openmods.md](openmods.md), the mod page on [openmods](https://openmods.nexus).

## How it works

`Scripts/main.lua` runs a loop on the game thread every 100 ms (`LoopInGameThreadWithDelay`). Each tweak does its work
only while it is set or still has a value of the mod to put back; with every setting at its default the loop returns
at once and the mod neither reads nor writes anything in the game.

| Tweak | What the mod changes |
|---|---|
| `FieldOfView` | The player's camera is the Advanced Third Person Camera plugin's `ATPCCameraComponent`. It eases its lens to the active camera mode's `CameraModeSettings.FOVSettings.CameraFOV` (`UATPCCameraModeDataAsset`; the modes are in the component's `SortedCameraModes`). The mod multiplies every mode's value by `FieldOfView` / the normal view's own (the mode of `DefaultCameraModeTag`, 75), kept between 10 and 170, so the game's zooms keep their proportion. Each mode's own value is kept by full name and written back for 0. Every 2 s it looks for modes that are new, loaded again as new objects, or given another value by the game. |
| `CameraDistance` | `SetAdditiveParameter_Distance("CameraAndImageTweaks", value, 0.5)` on the camera component, sent again every 5 s and to a new component (a respawn). |
| `LockOnHeight` | `SetAdditiveParameter_SocketOffset("CameraAndImageTweaksLockOn", (0, 0, value), 0.4)` while `GetCurrentCameraModeTag()` contains `Focus`, `LockTarget`, `LockView` or `TargetLock`, else 0. |
| `UltrawideFix` | `bConstrainAspectRatio` and `bOverrideAspectRatioAxisConstraint` off on every `CameraComponent` and `CineCameraComponent` (not the class default), `PlayerCameraManager.bDefaultConstrainAspectRatio` off, the local player's `AspectRatioAxisConstraint` at `MaintainYFOV` (0). `Auto`: only when the viewport (`WidgetLayoutLibrary:GetViewportSize`) is wider than 1.9:1. |
| `UltrawideHUD` | `SetRenderTranslation` on the widgets of `W_FrontEndHUDLayout_C` whose names start with `WB_PlayerHPBar`, `WB_quickslot`, `W_BuffBar` (to the left) and `W_WeaponUI` (to the right), by (1080 x aspect - 1920) / 2 design units (`Edges`) or half of it (`Halfway`); the vertical translation stays. Checked every 0.25 s, so a part the game moves back gets the offset again. |
| `ChromaticAberration`, `Vignette`, `LensFlares`, `Bloom` | `false`: `PostProcessSettings.bOverride_<X> = true` and `<X> = 0` on every camera component, for `SceneFringeIntensity`, `VignetteIntensity` and `FilmGrainIntensity`, `LensFlareIntensity`, `BloomIntensity`. Checked every tick, so a value the game puts back is ours again 0.1 s later. |
| `DepthOfField` | `false`: every cine camera's `CurrentAperture` = its `LensSettings.MaxFStop`. |

Every value is remembered when the mod first changes it and written back when its setting goes back to the game's
value or `Enable` is false. The game's console variables do nothing in this game since its update of 2026-11-04, so
the image switches are post-process overrides on the cameras.

Objects and searches: the engine is found once (`FindFirstOf("GameEngine")`); the world, the local player, its
controller, camera manager and pawn are read through it as properties. The camera components are searched with
`FindAllOf("CameraComponent")` and `FindAllOf("CineCameraComponent")` when the ultrawide fix starts or the world
changed, and every 3 s while an image switch is off; new ones come through `NotifyOnNewObject` (its callback runs on
the game thread) and are taken 0.05 s later, when they are built. The HUD layout is searched every 3 s while it is
missing. A kept object is used only after `IsValid()` in the same tick; a camera mode or camera that is written back
must also still have its full name (after a garbage collection another object can sit at the same address). When
the world's address changes (a map load), the mod forgets the old world's objects and waits 1.5 s; cameras it had
changed wait 10 s in a list, so a camera that is found again keeps its true original values. Every property the mod
reads on a kept object is defined in a native class, so UE4SS's stale `FindProperty` cache for unloaded Blueprint
classes does not reach it.

**The panel (1.1).** `PanelKey` (F9) opens a panel over the game, built at each opening from native UMG classes
(`UserWidget` with a `WidgetTree`, `Border`, `VerticalBox`, `HorizontalBox`, `TextBlock`; texts through
`KismetTextLibrary.Conv_StringToText`, the engine's Roboto font) and removed at each closing or when the world
changes. A row per setting, a bar for the numbers, an "All tweaks" row for `Enable`. Up/Down choose, Left/Right
change (Shift: bigger steps), Home sets the game's value (again at once: undo). The key binds (`RegisterKeyBind`;
F1 to F12 but F10, so a new `PanelKey` works at once) only put the key into a queue: UE4SS calls them on its input
thread, and the loop on the game thread does the work. A change is in `Settings` at once and goes into `config.lua`
2 s after the last key and when the panel closes: each value is replaced on its own line, its comment stays in its
column, a setting an older file lacks is added before the closing brace, and the new text is loaded once as a check
before it is written. The panel saves only what differs from the file's values, so a file changed by hand wins.

Each tweak writes a line into `UE4SS.log` when its state changes, for example
`[Camera and Image Tweaks] Field of view: on (123 camera modes x1.267; the normal view's own: 75).`; with
`LogDetail = true` also the details (cameras changed, modes loaded again, values the game had put back).

## Deploy and test

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1     # copy the mod folder into the game's ue4ss\Mods
python tests\test_main.py                                 # offline test of main.lua (needs lupa)
```

`deploy.ps1` copies `src\phantombladezero_cameraandimagetweaks\` to `<game folder>\platform\steam\ue4ss\Mods\phantombladezero_cameraandimagetweaks\`. The game
folder is `$env:UE5_GAMES_DIR\PBZ`; `-GameDir` or `-ModsDir` override it. The mod folder holds
`enabled.txt`, so UE4SS starts it without an entry in `mods.txt`. An existing `Scripts\config.lua` in the game stays
(the tester's settings); `-ResetConfig` copies the shipped one. UE4SS loads Lua mods at game start. The mod writes
its lines into `ue4ss\UE4SS.log`, for example `[Camera and Image Tweaks] 1.1 loaded.`

`tests\test_main.py` runs `main.lua` in Lua 5.4 ([lupa](https://pypi.org/project/lupa/)) with mocks of the UE4SS
functions that the script uses. It finds syntax and logic errors before a game start.

Versioning: every change raises the second number (1.0 -> 1.1) in `mod.json` and in `main.lua`:
`python scripts\bump_version.py`.

## Settings

`Scripts/config.lua` holds the player's settings, `DEFAULTS` in `main.lua` every setting with its default, `LIMITS`
the range of the number settings and `CHOICES` the words of the text settings (any case). Every default leaves the
game as it is. The mod reads the file at start and again every 5 seconds (`ReadConfig`): a changed file is used at
the next tick, a broken or half-saved one keeps the last settings, a missing one means the defaults. A number outside
its range is clamped, a `FieldOfView` from 1 to 49 counts as 0 (the game's own), a word that is not a choice keeps the
default; the log names each. Players and mod managers keep their own `config.lua` across updates, so a new `main.lua`
can meet an older file: a setting that the file lacks, or has with another type, keeps its default, and the log says
so (`ParseConfig`). Add each setting to both files with the same value, and read it only from `Settings`, never as
`config.X or default` (for a true/false setting, `false or true` is true). `tests\test_main.py` checks that
`config.lua` ships exactly the defaults, and runs `main.lua` with a missing, empty, broken and wrong `config.lua`.

| Setting | Default | Range |
|---|---|---|
| `Enable` | `true` | `false`: every tweak off, the game's own look |
| `FieldOfView` | `0` | 0 (the game's own) or 50 to 130 |
| `CameraDistance` | `0` | -150 to 500 |
| `LockOnHeight` | `0` | -150 to 100 |
| `UltrawideFix` | `"Off"` | `"Off"`, `"Auto"`, `"On"` |
| `UltrawideHUD` | `"Off"` | `"Off"`, `"Edges"`, `"Halfway"` |
| `ChromaticAberration`, `Vignette`, `DepthOfField`, `LensFlares`, `Bloom` | `true` | `false`: the effect off |
| `PanelKey` | `"F9"` | `"F1"` to `"F12"` but `"F10"`, or `"Off"` |
| `LogDetail` | `false` | `true`: more lines in `UE4SS.log` |

`tests\test_main.py` (121 checks) mocks the engine, the player's camera with four camera modes, three camera
components, the HUD's widget tree, UE4SS's key binds (exact modifier match, as in UE4SS), the UMG widgets of the
panel and the other UE4SS functions; it counts every read, write and search of the mod, so it
also checks that the defaults touch nothing.

## Project layout

```
src/phantombladezero_cameraandimagetweaks/   The UE4SS mod folder: Scripts/main.lua, Scripts/config.lua, enabled.txt
tests/test_main.py    Offline test of main.lua with mocks of UE4SS and the game
docs/                 Cover and screenshots
scripts/              bump_version.py
deploy.ps1            Copies the mod folder into the game's ue4ss\Mods
mod.json              Name, version, game, engine and UE4SS version
```

## License

MIT, see [LICENSE](LICENSE).
