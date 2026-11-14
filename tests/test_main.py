"""Offline test of Scripts/main.lua with lupa (Lua 5.4) and small mocks of UE4SS and the game.

The mocks stand in for the UE4SS functions that the script uses (the game-thread loops LoopInGameThreadWithDelay, the
old LoopAsync, ExecuteInGameThread, NotifyOnNewObject, FindFirstOf, FindAllOf, StaticFindObject, FName) and for the
game: the engine with its viewport, world, game instance, local player, controller and camera manager; the player's
pawn with its camera component (camera modes, additive parameters, the current camera mode tag); camera and cine camera
components with their aspect-ratio flags, post-process settings and aperture; the HUD layout with its widget tree.
Every write to a game object is counted (WRITES), and so are property reads (READS) and searches (SEARCHES); a written
number is stored as a 32-bit float, as in the game. os.clock is the mock's CLOCK, which TICK and WAIT move on.

The checks: the loops; the defaults change nothing and read nothing; each tweak, live: field of view (with modes that
the game puts back or loads again), camera distance, lock-on height, the ultrawide fix (also on cameras made later),
the ultrawide HUD, the image switches and depth of field; every value goes back to the game's when its setting does or
Enable is false; a new world; a missing player camera; errors. Then the settings files a player may have instead of
the shipped config.lua: main.lua must start, and every setting the file does not give keeps its default; the shipped
config.lua must hold exactly the defaults of main.lua.

Usage:
    python tests/test_main.py        (needs lupa: python -m pip install lupa)

Exit code: 0 = all checks passed, 1 = a check failed.
"""

import json
import stat
import sys
import tempfile
from pathlib import Path

from lupa import lua54

ROOT = Path(__file__).resolve().parent.parent
MAIN = ROOT / "src" / "phantombladezero_cameraandimagetweaks" / "Scripts" / "main.lua"
CONFIG = MAIN.parent / "config.lua"

MOCKS = r"""
LOG = {}
print = function(...) LOG[#LOG + 1] = table.concat({...}, "") end

LOOPS, DELAYS = {}, {}
ASYNC_LOOPS, GAME_THREAD_CALLS = 0, 0
function LoopInGameThreadWithDelay(ms, callback) LOOPS[#LOOPS + 1] = callback DELAYS[#DELAYS + 1] = ms return #LOOPS end
function LoopAsync(ms, callback) ASYNC_LOOPS = ASYNC_LOOPS + 1 LOOPS[#LOOPS + 1] = callback DELAYS[#DELAYS + 1] = ms end
function ExecuteInGameThread(callback) GAME_THREAD_CALLS = GAME_THREAD_CALLS + 1 callback() end
CLOCK = 100
os.clock = function() return CLOCK end
function RUN(ms) for i = 1, #LOOPS do if DELAYS[i] == ms then LOOPS[i]() end end end
function TICK(n) for _ = 1, n or 1 do CLOCK = CLOCK + 0.1 RUN(100) end end
function WAIT(seconds) TICK(math.floor(seconds * 10 + 0.5)) end
function CONFIG() RUN(5000) end

NOTIFY = {}
function NotifyOnNewObject(class, callback) NOTIFY[class] = callback end

WRITES, READS, SEARCHES = 0, 0, 0
local function Float(value) return (string.unpack("f", string.pack("f", value))) end
function RAW(object) return getmetatable(object).data end

-- A game object or struct: reads and writes of its fields are counted, numbers are stored as 32-bit floats.
-- THROW_READ: a field whose read raises an error.
THROW_READ = {}
function Proxy(fields, methods)
    local data = fields or {}
    return setmetatable({}, {
        data = data,
        __index = function(_, key)
            if methods and methods[key] ~= nil then return methods[key] end
            if THROW_READ[key] then error("read of " .. key .. " failed") end
            READS = READS + 1
            return data[key]
        end,
        __newindex = function(_, key, value)
            WRITES = WRITES + 1
            if type(value) == "number" then value = Float(value) end
            data[key] = value
        end,
    })
end

local nextAddress = 0x10000
function Object(fields, methods)
    fields = fields or {}
    nextAddress = nextAddress + 0x100
    fields.address = fields.address or nextAddress
    local all = {
        IsValid = function(self) return RAW(self).valid ~= false end,
        GetAddress = function(self) return RAW(self).address end,
        GetFullName = function(self) return RAW(self).fullName end,
        GetFName = function(self) local name = RAW(self).name return { ToString = function() return name end } end,
    }
    for name, method in pairs(methods or {}) do all[name] = method end
    return Proxy(fields, all)
end
function Name(text) return { ToString = function() return text end } end
function Tag(text) return { TagName = Name(text) } end
function FName(text) return Name(text) end
function Param(value) return { get = function() return value end } end

CALLS = {}
local function Call(text) WRITES = WRITES + 1 CALLS[#CALLS + 1] = text end
function CALLED(prefix)
    local n = 0
    for _, text in ipairs(CALLS) do if text:sub(1, #prefix) == prefix then n = n + 1 end end
    return n
end
function LAST_CALL() return CALLS[#CALLS] end

-- The camera modes.
ROOT = "/Game/Test/TrueThirdPersonCamera/Blueprints/CameraModes/"
function Mode(name, tag, value)
    return Object({ fullName = "BP_BaseCameraModeData_C " .. ROOT .. name .. "." .. name, CameraModeTag = Tag(tag),
        CameraModeSettings = Proxy({ FOVSettings = Proxy({ CameraFOV = Float(value) }) }) })
end
function NEW_MODES()
    MODES = { Mode("DA_CameraMode_ShouderDefault", "CameraType.ShoulderDefault", 75),
        Mode("DA_CameraMode_HoldDeflect", "CameraType.Combat.HoldDeflect", 60),
        Mode("DA_CameraMode_Focus", "CameraType.Combat.Focus", 70),
        Mode("DA_CameraMode_Wide", "CameraType.Special.Wide", 150) }
end
function SET_FOV(index, value) RAW(RAW(RAW(MODES[index]).CameraModeSettings).FOVSettings).CameraFOV = Float(value) end
function FOVS()
    local parts = {}
    for i, mode in ipairs(MODES) do
        parts[i] = string.format("%.2f", RAW(RAW(RAW(mode).CameraModeSettings).FOVSettings).CameraFOV)
    end
    return table.concat(parts, ", ")
end
MODE_MAP = { ForEach = function(_, callback)
    for _, mode in ipairs(MODES) do callback(Param(RAW(mode).CameraModeTag), Param(mode)) end
end }

-- The player's camera component.
CURRENT_TAG = "CameraType.ShoulderDefault"
DISTANCE_THROWS = false
function PlayerCameraComponent()
    return Object({ fullName = "NBCameraComponent /Game/Maps/Level.Level:PersistentLevel.BP_Hun_C_0.NBCamera",
        SortedCameraModes = MODE_MAP, DefaultCameraModeTag = Tag("CameraType.ShoulderDefault") }, {
        SetAdditiveParameter_Distance = function(self, name, value, blend)
            if DISTANCE_THROWS then error("Was unable to call\nstack traceback", 0) end
            Call(string.format("Distance %s %g %g @%x", name:ToString(), value, blend, RAW(self).address))
        end,
        SetAdditiveParameter_SocketOffset = function(self, name, vector, blend)
            Call(string.format("Socket %s %g %g %g %g", name:ToString(), vector.X, vector.Y, vector.Z, blend))
        end,
        GetCurrentCameraModeTag = function() return Tag(CURRENT_TAG) end,
    })
end

-- Camera components.
function PostProcess()
    return Proxy({ bOverride_SceneFringeIntensity = false, SceneFringeIntensity = Float(0.5),
        bOverride_VignetteIntensity = true, VignetteIntensity = Float(0.4),
        bOverride_FilmGrainIntensity = false, FilmGrainIntensity = 0,
        bOverride_LensFlareIntensity = false, LensFlareIntensity = 1,
        bOverride_BloomIntensity = false, BloomIntensity = Float(0.675) })
end
function Camera(name, constrain, override)
    return Object({ fullName = "CameraComponent " .. name, bConstrainAspectRatio = constrain,
        bOverrideAspectRatioAxisConstraint = override, PostProcessSettings = PostProcess() })
end
function Cine(name, constrain, override)
    return Object({ fullName = "CineCameraComponent " .. name, bConstrainAspectRatio = constrain,
        bOverrideAspectRatioAxisConstraint = override, PostProcessSettings = PostProcess(),
        CurrentAperture = Float(2.8), LensSettings = Proxy({ MaxFStop = 22 }) })
end
function PP(camera) return RAW(RAW(camera).PostProcessSettings) end
function IMAGE(camera)
    local p = PP(camera)
    return string.format("fringe %s %g, vignette %s %g, grain %s %g, flare %s %g, bloom %s %g",
        tostring(p.bOverride_SceneFringeIntensity), p.SceneFringeIntensity, tostring(p.bOverride_VignetteIntensity),
        p.VignetteIntensity, tostring(p.bOverride_FilmGrainIntensity), p.FilmGrainIntensity,
        tostring(p.bOverride_LensFlareIntensity), p.LensFlareIntensity, tostring(p.bOverride_BloomIntensity),
        p.BloomIntensity)
end
function BOX(camera)
    local raw = RAW(camera)
    return tostring(raw.bConstrainAspectRatio) .. " " .. tostring(raw.bOverrideAspectRatioAxisConstraint)
end

-- The HUD: W_FrontEndHUDLayout_C > WidgetTree.RootWidget (canvas) > AspectRatioScaleBox_0 (content) > playerhud.
function Widget(name, methods)
    local all = { SetRenderTranslation = function(self, vector)
        WRITES = WRITES + 1
        local translation = RAW(RAW(self).RenderTransform).Translation
        RAW(translation).X, RAW(translation).Y = Float(vector.X), Float(vector.Y)
    end }
    for key, method in pairs(methods or {}) do all[key] = method end
    return Object({ name = name, fullName = "Widget " .. name,
        RenderTransform = Proxy({ Translation = Proxy({ X = 0, Y = 0 }) }) }, all)
end
function Panel(name, children)
    return Widget(name, { GetChildrenCount = function() return #children end,
        GetChildAt = function(_, i) return children[i + 1] end })
end
function NEW_HUD()
    HP, SLOTS, BUFFS = Widget("WB_PlayerHPBar_82"), Widget("WB_quickslot"), Widget("W_BuffBar")
    WEAPONS, TIPS = Widget("W_WeaponUI"), Widget("WB_Tips")
    RAW(RAW(RAW(BUFFS).RenderTransform).Translation).Y = 12
    local playerhud = Panel("playerhud", { HP, SLOTS, BUFFS, WEAPONS, TIPS })
    local box = Widget("AspectRatioScaleBox_0", { GetContent = function() return playerhud end })
    HUD = Object({ name = "W_FrontEndHUDLayout_C_0", fullName = "W_FrontEndHUDLayout_C /Engine/Transient.W_0",
        WidgetTree = Proxy({ RootWidget = Panel("CanvasPanel_0", { box }) }) })
end
function X(widget) return RAW(RAW(RAW(widget).RenderTransform).Translation).X end
function HUD_X() return string.format("%g %g %g %g %g", X(HP), X(SLOTS), X(BUFFS), X(WEAPONS), X(TIPS)) end
function HUD_Y(widget) return RAW(RAW(RAW(widget).RenderTransform).Translation).Y end

-- A world with everything in it.
VIEW_W, VIEW_H = 3440, 1440
ATPC_CLASS = Object({ fullName = "Class /Script/AdvancedThirdPersonCamera.ATPCCameraComponent" })
LIBRARY = Object({}, { GetViewportSize = function() return { X = VIEW_W, Y = VIEW_H } end,
    GetViewportScale = function() return 1.333 end })

-- Key binds: as in UE4SS, a callback fires when its key is pressed with exactly its modifier keys.
Key = setmetatable({}, { __index = function(_, name) return name end })
ModifierKey = { SHIFT = "SHIFT", CONTROL = "CONTROL", ALT = "ALT" }
BINDS = {}
function RegisterKeyBind(key, modifiers, callback)
    if type(modifiers) == "function" then callback, modifiers = modifiers, {} end
    BINDS[#BINDS + 1] = { key = key, modifiers = table.concat(modifiers, "+"), callback = callback }
end
function PRESS(key, modifier)
    local fired = 0
    for _, bind in ipairs(BINDS) do
        if bind.key == key and bind.modifiers == (modifier or "") then bind.callback() fired = fired + 1 end
    end
    return fired
end
function KEY(key, modifier, times) for _ = 1, times or 1 do PRESS(key, modifier) end TICK() end

-- UMG: the classes, the font, the text library, and widgets that record what the panel does with them.
UMG_PRESENT = true
UMG_CLASSES = {}
for _, name in ipairs({ "UserWidget", "WidgetTree", "CanvasPanel", "Border", "SizeBox", "VerticalBox",
    "HorizontalBox", "TextBlock" }) do
    UMG_CLASSES["/Script/UMG." .. name] = Object({ name = name, fullName = "Class /Script/UMG." .. name })
end
FONT = Object({ fullName = "Font /Engine/EngineFonts/Roboto.Roboto" })
TEXT_LIBRARY = Object({}, { Conv_StringToText = function(_, text) return { text = text } end })
ON_SCREEN, BUILDS, TEXT_SETS = 0, 0, 0
TEXTS, ROOT_WIDGET = {}, nil
local Slot = setmetatable({}, { __index = function() return function() end end })
function StaticConstructObject(class, outer, name)
    local kind = RAW(class).name
    nextAddress = nextAddress + 0x100
    local data = { kind = kind, address = nextAddress, fields = {}, outer = outer }
    local widget = setmetatable({}, { data = data,
        __index = function(_, key)
            if data.fields[key] ~= nil then return data.fields[key] end
            if key == "IsValid" then return function() return data.valid ~= false end end
            if key == "GetAddress" then return function() return data.address end end
            if key == "SetText" then return function(_, text) data.text = text.text TEXT_SETS = TEXT_SETS + 1 end end
            if key == "SetColorAndOpacity" then return function(_, color) data.color = color.SpecifiedColor end end
            if key == "AddToViewport" then return function(_, z) data.z = z ON_SCREEN = ON_SCREEN + 1 end end
            if key == "RemoveFromParent" then
                return function() if data.z then ON_SCREEN = ON_SCREEN - 1 end data.z = nil end
            end
            if key == "SetVisibility" then return function(_, value) data.visibility = value end end
            if key == "GetDesiredSize" then return function() return { X = 900, Y = 760 } end end
            if key == "SetRenderScale" then return function(_, scale) data.scale = scale.X end end
            if key:sub(1, 10) == "AddChildTo" then return function() return Slot end end
            return function() end
        end,
        __newindex = function(_, key, value) data.fields[key] = value end })
    if kind == "UserWidget" then BUILDS = BUILDS + 1 TEXTS = {} ROOT_WIDGET = widget end
    if kind == "TextBlock" then TEXTS[#TEXTS + 1] = data end
    return widget
end
-- Every text of the last panel, in the order of its text blocks.
function PANEL()
    local parts = {}
    for i, data in ipairs(TEXTS) do parts[i] = data.text or "" end
    return table.concat(parts, "|")
end
-- Row i's label and value (the title and the status line come first; five text blocks per row).
function ROW(i) return TEXTS[2 + (i - 1) * 5 + 1].text .. "=" .. TEXTS[2 + (i - 1) * 5 + 2].text end
function BAR(i) return TEXTS[2 + (i - 1) * 5 + 3].text .. "/" .. TEXTS[2 + (i - 1) * 5 + 4].text end
function LABEL_COLOR(i) return TEXTS[2 + (i - 1) * 5 + 1].color.R end
-- A new pawn with a new camera component (a respawn).
function NEW_PAWN()
    PLAYER_CAMERA = PlayerCameraComponent()
    PAWN = Object({ fullName = "BP_Hun_C /Game/Maps/Level.Level:PersistentLevel.BP_Hun_C_0" }, {
        GetComponentByClass = function(_, class) if class == ATPC_CLASS then return PLAYER_CAMERA end end })
end
function NEW_WORLD()
    WORLD = Object({ fullName = "World /Game/Maps/Level.Level" })
    NEW_PAWN()
    MANAGER = Object({ bDefaultConstrainAspectRatio = true })
    CONTROLLER = Object({ PlayerCameraManager = MANAGER }, { K2_GetPawn = function() return PAWN end })
    RAW(PLAYER).PlayerController = CONTROLLER
    GAME_CAMERA, PLAIN, CINE = Camera("GameCamera", true, false), Camera("Plain", false, false), Cine("Cine", false, true)
    DEFAULT_CAMERA = Camera("/Script/Engine.Default__CameraComponent", true, false)
    RAW(DEFAULT_CAMERA).fullName = "CameraComponent /Script/Engine.Default__CameraComponent"
    CAMERAS = { CameraComponent = { DEFAULT_CAMERA, GAME_CAMERA, PLAIN }, CineCameraComponent = { CINE } }
    if VIEWPORT then RAW(VIEWPORT).World = WORLD end
    NEW_HUD()
end
PLAYER = Object({ AspectRatioAxisConstraint = 1 })
NEW_MODES()
NEW_WORLD()
VIEWPORT = Object({ World = WORLD })
ENGINE = Object({ GameViewport = VIEWPORT, GameInstance = Object({ LocalPlayers = { PLAYER } }) })
HUD_PRESENT = true
ENGINE_THROWS = false

function FindFirstOf(class)
    SEARCHES = SEARCHES + 1
    if class == "GameEngine" then
        if ENGINE_THROWS then error("FindFirstOf failed", 0) end
        return ENGINE
    end
    if class == "W_FrontEndHUDLayout_C" and HUD_PRESENT then return HUD end
    return nil
end
function FindAllOf(class)
    SEARCHES = SEARCHES + 1
    local list = CAMERAS[class]
    if not list or #list == 0 then return nil end
    local copy = {}
    for i, object in ipairs(list) do copy[i] = object end
    return copy
end
function StaticFindObject(path)
    SEARCHES = SEARCHES + 1
    if path == "/Script/AdvancedThirdPersonCamera.ATPCCameraComponent" then return ATPC_CLASS end
    if path == "/Script/UMG.Default__WidgetLayoutLibrary" then return LIBRARY end
    if UMG_CLASSES[path] and UMG_PRESENT then return UMG_CLASSES[path] end
    if path == "/Engine/EngineFonts/Roboto.Roboto" then return FONT end
    if path == "/Script/Engine.Default__KismetTextLibrary" then return TEXT_LIBRARY end
    return Object({ valid = false })
end

-- A camera the game makes now: NotifyOnNewObject's callback runs while it is built.
function NEW_CAMERA(kind, constrain, override)
    local camera = (kind == "cine" and Cine or Camera)("New" .. tostring(CLOCK), constrain, override)
    table.insert(CAMERAS[kind == "cine" and "CineCameraComponent" or "CameraComponent"], camera)
    local callback = NOTIFY["/Script/Engine.CameraComponent"]
    if callback then NOTIFY_RESULT = callback(camera) end
    return camera
end

function DESCRIBE(t)
    local names = {}
    for name in pairs(t) do names[#names + 1] = tostring(name) end
    table.sort(names)
    local parts = {}
    for i, name in ipairs(names) do parts[i] = name .. "=" .. tostring(t[name]) end
    return table.concat(parts, ", ")
end
"""

PLAYER_CONFIGS = [
    ("no config.lua", None, "No config.lua"),
    ("an empty or older config.lua", "return {}\n", None),
    ("a broken config.lua", "return {\n    Enable =\n", "config.lua not read"),
    ("a config.lua without a table", "-- nothing here\n", "does not return a table"),
    ("a config.lua with wrong types", "wrong types", "must be a"),
    ("a config.lua with an unknown setting", "return { NoSuchSetting = 1 }\n", "unknown setting NoSuchSetting"),
]

GAME_FOVS = "75.00, 60.00, 70.00, 150.00"
FOV95 = "95.00, 76.00, 88.67, 170.00"
GAME_IMAGE = "fringe false 0.5, vignette true 0.4, grain false 0, flare false 1, bloom false 0.675"


def lua_path(path: Path) -> str:
    return "[[" + path.as_posix() + "]]"


class Run:
    """main.lua in a fresh Lua state, with config.lua read from config_folder; before: Lua run before main.lua."""

    def __init__(self, config_folder: Path, before: str = ""):
        self.folder = config_folder
        self.lua = lua54.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCKS)
        self.lua.execute(f'package.path = {lua_path(config_folder)} .. "/?.lua"; package.cpath = ""')
        if before:
            self.lua.execute(before)
        self.g = self.lua.globals()
        self.do(MAIN.read_text(encoding="utf-8"))

    def do(self, code: str):
        """Runs Lua code; a Lua error that stops it becomes an "Error" line in the log, so the checks fail."""
        try:
            return self.lua.execute(code)
        except lua54.LuaError as error:
            self.g.LOG[len(self.g.LOG) + 1] = "Error: main.lua stopped: " + str(error).splitlines()[0]

    def eval(self, expression: str):
        return self.lua.eval(expression)

    def log(self):
        return [self.g.LOG[i].rstrip() for i in range(1, len(self.g.LOG) + 1)]

    def count(self, text: str) -> int:
        return sum(text in line for line in self.log())

    def write_config(self, text: str):
        (self.folder / "config.lua").write_text(text, encoding="utf-8")

    def set(self, text: str, wait: float = 2):
        """A new config.lua, read by the mod, then `wait` seconds of game."""
        self.write_config(text)
        self.do(f"CONFIG() WAIT({wait})")


def settings_lines(log):
    return [line.split("] Settings: ", 1)[1] for line in log if "] Settings: " in line]


def main() -> None:
    version = json.loads((ROOT / "mod.json").read_text(encoding="utf-8"))["version"]
    failures = []

    def check(condition, text):
        print(("ok    " if condition else "FAIL  ") + text)
        if not condition:
            failures.append(text)

    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        shipped_text = CONFIG.read_text(encoding="utf-8")

        def folder(name, text=shipped_text):
            f = temp / name
            f.mkdir()
            if text is not None:
                (f / "config.lua").write_text(text, encoding="utf-8")
            return f

        def config(**values):
            """The shipped config.lua with other values, for example config(Bloom="false")."""
            text = shipped_text
            for name, value in values.items():
                lines = [line for line in text.splitlines() if line.strip().startswith(name + " = ")]
                assert len(lines) == 1, name
                old = lines[0].split(",", 1)[0]
                text = text.replace(old + ",", f"    {name} = {value},")
            return text

        # --- The mod as players get it: every default leaves the game as it is.
        r = Run(folder("shipped"))
        e = r.eval
        log = r.log()
        for line in log:
            print("      log: " + line)
        check(list(r.g.DELAYS.values()) == [100, 5000] and r.g.ASYNC_LOOPS == 0 and r.g.GAME_THREAD_CALLS == 0,
              "game-thread loops: the work every 100 ms, the config read every 5 s")
        check(e("NOTIFY['/Script/Engine.CameraComponent'] ~= nil"), "NotifyOnNewObject for new camera components")
        check(any(f"{version} loaded." in line for line in log), f"load line with the version {version} of mod.json")
        shipped = e(f"DESCRIBE(dofile({lua_path(CONFIG)}))")
        check(settings_lines(log) == [shipped] and not any("config.lua" in line for line in log),
              "one settings line with the shipped values, no warning")
        r.do("WAIT(10) NEW_CAMERA('cine', true, true) WAIT(1) CONFIG()")
        check(e("WRITES") == 0 and e("READS") == 0 and e("SEARCHES") == 0 and e("NOTIFY_RESULT") is False,
              "the defaults on an ultrawide screen: no write, no read, no search, also for a new camera")
        check(len(r.log()) == len(log), "the defaults: no log line in 11 s of game")

        # --- Field of view, live.
        r.set(config(FieldOfView="95"))
        check(e("FOVS()") == FOV95, "FieldOfView 95: every camera mode x95/75 (60 -> 76), clamped at 170")
        check(r.count("Field of view: on (4 camera modes x1.267; the normal view's own: 75).") == 1,
              "one log line for the field of view")
        writes = e("WRITES")
        r.do("WAIT(10)")
        check(e("WRITES") == writes, "10 s later: no write (the values hold)")
        r.do("SET_FOV(3, 70) WAIT(2.1)")
        check(e("FOVS()") == FOV95, "the game puts a mode's own value back: it is scaled again")
        r.do("SET_FOV(3, 80) WAIT(2.1)")
        check(e("FOVS()") == "95.00, 76.00, 101.33, 170.00", "the game gives a mode a new value: it is scaled")
        r.do("OLD = MODES[2] MODES[2] = Mode('DA_CameraMode_HoldDeflect', 'CameraType.Combat.HoldDeflect', 60) "
             "WAIT(2.1)")
        check(e("FOVS()") == "95.00, 76.00, 101.33, 170.00" and e("RAW(RAW(RAW(OLD).CameraModeSettings).FOVSettings)"
                                                                  ".CameraFOV") == 76,
              "a mode loaded again as a new object: the new object is scaled")
        r.do("MODES[2] = Mode('DA_CameraMode_HoldDeflect', 'CameraType.Combat.HoldDeflect', 76) WAIT(2.1)")
        check(e("FOVS()") == "95.00, 76.00, 101.33, 170.00",
              "a mode loaded again with our value copied: it stays 76, not 96")
        r.set(config(FieldOfView="200"))
        check(r.count("FieldOfView = 200 is outside 0 to 130; 130 is used") == 1
              and e("FOVS()") == "130.00, 104.00, 138.67, 170.00", "FieldOfView 200: clamped to 130")
        r.set(config(FieldOfView="0"))
        check(e("FOVS()") == "75.00, 60.00, 80.00, 150.00" and r.count("Field of view: off.") == 1,
              "FieldOfView 0 (live): every mode has the game's value again")
        writes, reads = e("WRITES"), e("READS")
        r.do("WAIT(5)")
        check(e("WRITES") == writes and e("READS") == reads, "all back at the defaults: no write and no read")
        r.set(config(FieldOfView="40"))
        check(r.count("FieldOfView = 40 is below 50; 0 (the game's own) is used.") == 1 and e("WRITES") == writes,
              "FieldOfView 40: the game's own, as in the source mod")
        r.do("SET_FOV(3, 70)")

        # --- Camera distance and lock-on height.
        r.set(config(CameraDistance="150"))
        check(e("CALLED('Distance CameraAndImageTweaks 150 0.5')") == 1, "CameraDistance 150: one call, blend 0.5")
        r.do("WAIT(5)")
        check(e("CALLED('Distance CameraAndImageTweaks 150 0.5')") == 2, "sent again after 5 s")
        r.do("NEW_PAWN() TICK()")
        check(e("LAST_CALL() == string.format('Distance CameraAndImageTweaks 150 0.5 @%x', RAW(PLAYER_CAMERA)"
                ".address)"), "a new camera component (a respawn): the distance is sent to it at once")
        r.set(config(CameraDistance="0"))
        check(e("CALLED('Distance CameraAndImageTweaks 0 0.5')") == 1 and r.count("Camera distance: off.") == 1,
              "CameraDistance 0: one call with 0")
        calls = e("#CALLS")
        r.do("WAIT(10)")
        check(e("#CALLS") == calls, "then no more calls")
        r.set(config(LockOnHeight="-80"))
        check(e("CALLED('Socket')") == 0, "LockOnHeight -80 in the normal view: no call")
        r.do("CURRENT_TAG = 'CameraType.Combat.Focus' TICK()")
        check(e("LAST_CALL()") == "Socket CameraAndImageTweaksLockOn 0 0 -80 0.4"
              and r.count("Lock-on height: on (-80 in the camera mode CameraType.Combat.Focus).") == 1,
              "in a lock-on camera mode: the camera goes 80 lower, blend 0.4")
        r.do("TICK(5)")
        check(e("CALLED('Socket')") == 1, "one call while the lock lasts")
        r.do("CURRENT_TAG = 'CameraType.ShoulderDefault' TICK()")
        check(e("LAST_CALL()") == "Socket CameraAndImageTweaksLockOn 0 0 0 0.4", "the lock ends: back to 0")
        r.do("CURRENT_TAG = 'CameraType.LockView.SideM' TICK()")
        r.set(config(LockOnHeight="0"))
        check(e("LAST_CALL()") == "Socket CameraAndImageTweaksLockOn 0 0 0 0.4" and e("CALLED('Socket')") == 4,
              "LockOnHeight 0 while locked on: back to 0")
        r.do("CURRENT_TAG = 'CameraType.ShoulderDefault'")

        # --- The ultrawide fix.
        r.set(config(UltrawideFix='"On"'))
        check(e("BOX(GAME_CAMERA)") == "false false" and e("BOX(CINE)") == "false false"
              and e("BOX(PLAIN)") == "false false" and e("BOX(DEFAULT_CAMERA)") == "true false"
              and e("RAW(PLAYER).AspectRatioAxisConstraint") == 0
              and e("RAW(MANAGER).bDefaultConstrainAspectRatio") is False,
              "UltrawideFix On: no camera boxes the picture, the local player keeps MaintainYFOV (class default "
              "untouched)")
        check(r.count("Ultrawide fix: on (3 cameras unboxed).") == 1,
              "one log line for the ultrawide fix (the game camera, the cine camera, the cine camera made at the "
              "defaults)")
        r.do("NEW = NEW_CAMERA('cine', true, false) TICK(2)")
        check(e("BOX(NEW)") == "false false", "a cutscene camera made later: unboxed within 0.2 s")
        r.do("LATE = NEW_CAMERA('cine', true, false)")
        r.set(config(UltrawideFix='"Off"'))
        check(e("BOX(GAME_CAMERA)") == "true false" and e("BOX(CINE)") == "false true"
              and e("BOX(PLAIN)") == "false false" and e("BOX(NEW)") == "true false"
              and e("RAW(PLAYER).AspectRatioAxisConstraint") == 1
              and e("RAW(MANAGER).bDefaultConstrainAspectRatio") is True,
              "UltrawideFix Off: every value as the game had it")
        r.do("VIEW_W, VIEW_H = 1920, 1080")
        writes = e("WRITES")
        r.set(config(UltrawideFix='"auto"'))
        check(e("WRITES") == writes and r.count("Ultrawide fix: not needed (Auto: the screen is 1.78:1, not wider "
                                                "than 1.9:1).") == 1,
              'UltrawideFix "auto" (any case) on a 16:9 screen: nothing written, the log says why')
        r.do("VIEW_W, VIEW_H = 3440, 1440 TICK()")
        check(e("BOX(GAME_CAMERA)") == "false false", "Auto on a 21:9 screen: on")
        r.do("RAW(PLAYER).AspectRatioAxisConstraint = 0")
        r.set(config(UltrawideFix='"Off"'))
        r.set(config(UltrawideFix='"On"'))
        r.do("RAW(PLAYER).AspectRatioAxisConstraint = 1")
        r.set(config(UltrawideFix='"Off"'))
        check(e("RAW(PLAYER).AspectRatioAxisConstraint") == 1,
              "a local player that had MaintainYFOV already: the mod does not write it back")
        r.do("RAW(PLAYER).AspectRatioAxisConstraint = 1")

        # --- The ultrawide HUD.
        r.set(config(UltrawideHUD='"Edges"'))
        check(e("HUD_X()") == "-330 -330 -330 330 0" and e("HUD_Y(BUFFS)") == 12,
              "UltrawideHUD Edges on 3440x1440: health, slots, buffs 330 to the left, weapons 330 to the right; "
              "other widgets and the vertical position stay")
        check(r.count("Ultrawide HUD: on (4 HUD parts moved 330 to the sides).") == 1, "one log line for the HUD")
        r.do("RAW(RAW(RAW(WEAPONS).RenderTransform).Translation).X = 0 TICK(3)")
        check(e("X(WEAPONS)") == 330, "the game moves a part back: ours again within 0.3 s")
        r.set(config(UltrawideHUD='"Halfway"'))
        check(e("HUD_X()") == "-165 -165 -165 165 0", "Halfway: half of it")
        r.do("VIEW_W, VIEW_H = 5120, 1440 WAIT(1)")
        check(e("HUD_X()") == "-480 -480 -480 480 0", "Halfway on 32:9: 480")
        r.do("VIEW_W, VIEW_H = 1920, 1080 WAIT(1)")
        check(e("HUD_X()") == "0 0 0 0 0" and r.count("Ultrawide HUD: not needed (the screen is 1.78:1, not wider "
                                                       "than 16:9).") == 1, "a 16:9 screen: the HUD as in the game")
        r.do("VIEW_W, VIEW_H = 3440, 1440 WAIT(1)")
        r.set(config(UltrawideHUD='"Off"'))
        check(e("HUD_X()") == "0 0 0 0 0" and e("HUD_Y(BUFFS)") == 12, "UltrawideHUD Off: the HUD as in the game")

        # --- The image switches.
        r.set(config(Bloom="false"))
        check(e("IMAGE(GAME_CAMERA)") == GAME_IMAGE.replace("bloom false 0.675", "bloom true 0")
              and e("IMAGE(CINE)") == e("IMAGE(GAME_CAMERA)") and e("IMAGE(DEFAULT_CAMERA)") == GAME_IMAGE,
              "Bloom false: an override of 0 on every camera (not on the class default)")
        check(r.count("Image switches: on (Bloom off on ") == 1, "one log line for the image switches")
        r.set(config(Bloom="false", Vignette="false", ChromaticAberration="false", LensFlares="false"))
        check(e("IMAGE(PLAIN)") == "fringe true 0, vignette true 0, grain true 0, flare true 0, bloom true 0",
              "all four switches off: fringe, vignette with film grain, lens flares, bloom")
        r.do("PP(PLAIN).bOverride_BloomIntensity = false PP(PLAIN).BloomIntensity = 0.675 TICK()")
        check(e("PP(PLAIN).bOverride_BloomIntensity") is True and e("PP(PLAIN).BloomIntensity") == 0,
              "the game puts a value back: ours again at the next tick")
        r.do("NEW_IMAGE = NEW_CAMERA('camera', false, false) TICK(2)")
        check(e("IMAGE(NEW_IMAGE)") == "fringe true 0, vignette true 0, grain true 0, flare true 0, bloom true 0",
              "a camera made later: the overrides within 0.2 s")
        r.set(config())
        check(e("IMAGE(PLAIN)") == GAME_IMAGE and e("IMAGE(CINE)") == GAME_IMAGE and e("IMAGE(NEW_IMAGE)") == GAME_IMAGE
              and r.count("Image switches: off.") == 1,
              "all switches true again: every camera's own flags and values (vignette's own override stays)")
        r.set(config(DepthOfField="false"))
        check(e("RAW(CINE).CurrentAperture") == 22, "DepthOfField false: the cine camera at its highest f-number")
        r.do("RAW(CINE).CurrentAperture = 4 TICK()")
        check(e("RAW(CINE).CurrentAperture") == 22, "the game opens the aperture: back to 22")
        r.set(config())
        check(abs(e("RAW(CINE).CurrentAperture") - 2.8) < 1e-6, "DepthOfField true: the cine camera's own f/2.8")
        writes, reads = e("WRITES"), e("READS")
        r.do("WAIT(5)")
        check(e("WRITES") == writes and e("READS") == reads, "everything back at the defaults: no write and no read")

        # --- Enable, a new world, a missing player camera.
        everything = config(FieldOfView="95", CameraDistance="150", UltrawideFix='"On"', UltrawideHUD='"Edges"',
                            Bloom="false", DepthOfField="false", LockOnHeight="-80")
        r.set(everything)
        r.do("CURRENT_TAG = 'CameraType.Combat.Focus' TICK()")
        check(e("FOVS()") == FOV95 and e("BOX(GAME_CAMERA)") == "false false" and e("HUD_X()") == "-330 -330 -330 330 0"
              and e("PP(GAME_CAMERA).bOverride_BloomIntensity") is True and e("RAW(CINE).CurrentAperture") == 22
              and e("LAST_CALL()") == "Socket CameraAndImageTweaksLockOn 0 0 -80 0.4",
              "every tweak at once")
        r.set(everything.replace("Enable = true", "Enable = false"))
        check(e("FOVS()") == GAME_FOVS and e("BOX(GAME_CAMERA)") == "true false" and e("HUD_X()") == "0 0 0 0 0"
              and e("IMAGE(GAME_CAMERA)") == GAME_IMAGE and abs(e("RAW(CINE).CurrentAperture") - 2.8) < 1e-6
              and e("CALLED('Distance CameraAndImageTweaks 0 0.5')") == 2
              and e("LAST_CALL()") == "Socket CameraAndImageTweaksLockOn 0 0 0 0.4"
              and e("RAW(PLAYER).AspectRatioAxisConstraint") == 1,
              "Enable = false (live): every value back to the game's, the game's own look")
        writes, reads = e("WRITES"), e("READS")
        r.do("WAIT(5)")
        check(e("WRITES") == writes and e("READS") == reads, "Enable = false: then no write and no read")
        r.set(everything)
        check(e("FOVS()") == FOV95 and e("BOX(GAME_CAMERA)") == "false false"
              and e("PP(GAME_CAMERA).bOverride_BloomIntensity") is True, "Enable = true again: every tweak again")
        r.do("RAW(VIEWPORT).World = nil TICK() RAW(VIEWPORT).World = WORLD WAIT(2)")
        check(e("BOX(GAME_CAMERA)") == "false false" and e("PP(GAME_CAMERA).bOverride_BloomIntensity") is True,
              "the world is missing for a moment, then the same world: every tweak again")
        r.set(config())
        check(e("BOX(GAME_CAMERA)") == "true false" and e("IMAGE(GAME_CAMERA)") == GAME_IMAGE
              and abs(e("RAW(CINE).CurrentAperture") - 2.8) < 1e-6,
              "then the defaults: the cameras get the game's own values, not ours read again")
        r.set(config(UltrawideFix='"On"'))
        r.do("RAW(VIEWPORT).World = nil TICK() RAW(VIEWPORT).World = WORLD TICK()")
        r.set(config())
        check(e("BOX(GAME_CAMERA)") == "true false" and e("RAW(MANAGER).bDefaultConstrainAspectRatio") is True,
              "the fix goes off while the mod waits after such a moment: the cameras get their own values back")
        r.set(everything)
        r.do("OLD_MANAGER = MANAGER NEW_WORLD() WRITES_BEFORE = WRITES TICK(14)")
        check(e("WRITES") == e("WRITES_BEFORE"), "a new world: nothing written for 1.4 s")
        r.do("WAIT(1)")
        check(e("BOX(GAME_CAMERA)") == "false false" and e("PP(GAME_CAMERA).bOverride_BloomIntensity") is True
              and e("RAW(CINE).CurrentAperture") == 22 and e("HUD_X()") == "-330 -330 -330 330 0"
              and e("RAW(MANAGER).bDefaultConstrainAspectRatio") is False
              and e("CALLED(string.format('Distance CameraAndImageTweaks 150 0.5 @%x', RAW(PLAYER_CAMERA).address))")
              == 1 and e("FOVS()") == FOV95,
              "after the settle time: every tweak on the new world's objects")
        check(e("RAW(OLD_MANAGER).bDefaultConstrainAspectRatio") is True,
              "the old world's camera manager, if still there, gets its own value back")
        r.do("PAWN_KEPT = PAWN PAWN = nil WAIT(1)")
        r.set(config())
        check(e("FOVS()") == GAME_FOVS and not any("Error" in line for line in r.log()),
              "no player pawn (a loading screen): FieldOfView 0 still restores the modes, no error")
        r.do("PAWN = PAWN_KEPT")
        r.set(config(FieldOfView="110"))
        r.do("PAWN = nil WAIT(1) RAW(CONTROLLER).PlayerCameraManager = MANAGER")
        check(not any("Error" in line for line in r.log()), "FieldOfView set without a player pawn: no error")
        r.do("PAWN = PAWN_KEPT WAIT(1)")
        check(e("FOVS()") == "110.00, 88.00, 102.67, 170.00", "the pawn is back: the field of view is applied")
        r.do("REUSED = table.remove(MODES, 2) RAW(REUSED).fullName = 'BP_BaseCameraModeData_C /Game/Other.Other' "
             "RAW(RAW(RAW(REUSED).CameraModeSettings).FOVSettings).CameraFOV = 50")
        r.set(config(FieldOfView="95"))
        check(e("FOVS()") == "95.00, 88.67, 170.00"
              and e("RAW(RAW(RAW(REUSED).CameraModeSettings).FOVSettings).CameraFOV") == 50,
              "a kept mode whose address now holds another object (a garbage collection): that object is left alone")
        r.set(config())
        check(not any("Error" in line or "not available" in line for line in r.log()), "no error line in this run")

        # --- Errors.
        broken = Run(folder("broken", config(CameraDistance="100", FieldOfView="95")), "DISTANCE_THROWS = true")
        broken.do("WAIT(5)")
        check(broken.count("Camera distance: not available (SetAdditiveParameter_Distance: Was unable to call).") == 1
              and broken.eval("FOVS()") == FOV95,
              "a call that fails: one line (its first), the other tweaks still work")
        failing = Run(folder("failing", config(Bloom="false")), "ENGINE_THROWS = true")
        failing.do("WAIT(60)")
        check(failing.count("Error: FindFirstOf failed") == 10, "an error every 5 s: at most 10 error lines")
        reading = Run(folder("reading", config(Bloom="false", FieldOfView="95")), "THROW_READ.PlayerController = true")
        reading.do("WAIT(3)")
        check(reading.eval("PP(GAME_CAMERA).bOverride_BloomIntensity") is True and reading.eval("FOVS()") == GAME_FOVS
              and not any("Error" in line for line in reading.log()),
              "a read that fails for the player: no field of view, the image switches still work")
        reuse = Run(folder("reuse", config(CameraDistance="100")))
        reuse.do("WAIT(3)")
        reuse.set(config(), 1)
        reuse.do("local world, pawn = RAW(WORLD).address, RAW(PAWN).address NEW_WORLD() "
                 "RAW(WORLD).address, RAW(PAWN).address = world, pawn")
        reuse.set(config(CameraDistance="100"), 3)
        check(reuse.eval("CALLED(string.format('Distance CameraAndImageTweaks 100 0.5 @%x', RAW(PLAYER_CAMERA)"
                         ".address))") == 1,
              "after a time with every setting at its default, a new world and pawn at the old addresses: the new "
              "camera component is used")
        old = Run(folder("old", config(Bloom="false")), "LoopInGameThreadWithDelay = nil")
        old.do("WAIT(2)")
        check(old.eval("ASYNC_LOOPS") == 2 and old.count("no game-thread loops") == 1
              and old.eval("PP(GAME_CAMERA).bOverride_BloomIntensity") is True,
              "a UE4SS without game-thread loops: LoopAsync, and a log line")
        quiet = Run(folder("quiet", config(UltrawideFix='"On"')), "NotifyOnNewObject = nil")
        quiet.do("WAIT(2) LATE = NEW_CAMERA('cine', true, false) WAIT(3.1)")
        check(quiet.count("No notice of new cameras") == 1 and quiet.eval("BOX(LATE)") == "false false",
              "without NotifyOnNewObject: a log line, and new cameras are found by the search every 3 s")
        detail = Run(folder("detail", config(LogDetail="true", Bloom="false")))
        detail.do("WAIT(4)")
        check(detail.count("Image switches: 3 camera settings written.") == 1
              and detail.count("Image switches: on (Bloom off on 3 cameras).") == 1,
              "LogDetail = true: a line about the writes, and the state line once")

        # --- The panel (1.1).
        p = Run(folder("panel"))
        pe = p.eval
        cfg_file = p.folder / "config.lua"
        check(pe("#BINDS") == 18 and pe("PRESS('F10')") == 0 and pe("PRESS('HOME')") == 1,
              "key binds: F1 to F12 but F10, the four arrows, Home, Shift+Left and Shift+Right")
        p.do("WAIT(2)")
        check(pe("READS") == 0 and pe("SEARCHES") == 0, "keys bound, panel never opened: nothing read")
        reads, writes, searches = pe("READS"), pe("WRITES"), pe("SEARCHES")
        p.do("PRESS('RIGHT_ARROW') PRESS('F9')")
        check(pe("READS") == reads and pe("WRITES") == writes and pe("SEARCHES") == searches and pe("BUILDS") == 0,
              "a key press itself touches no game object: the work waits for the game-thread loop")
        p.do("TICK()")
        panel_text = pe("PANEL()")
        check(pe("BUILDS") == 1 and pe("ON_SCREEN") == 1 and pe("RAW(ROOT_WIDGET).visibility") == 3
              and f"CAMERA AND IMAGE TWEAKS {version}" in panel_text and pe("ROW(1)") == "> All tweaks=On"
              and pe("ROW(2)") == "   Field of view=Game (75)" and pe("ROW(5)") == "   Ultrawide fix=Off (game)"
              and pe("ROW(11)") == "   Bloom=Game" and "Up/Down: choose" in panel_text and "F9: close" in panel_text,
              "F9 opens the panel at the next tick: on screen, not taking the mouse, every row at the game's value")
        check(pe("PRESS('RIGHT_ARROW')") == 1 and pe("PRESS('RIGHT_ARROW', 'SHIFT')") == 1,
              "Shift+Right fires only the Shift bind (UE4SS matches modifiers exactly)")
        p.do("TICK()")
        p.do("KEY('DOWN_ARROW') KEY('LEFT_ARROW', 'SHIFT', 4) KEY('RIGHT_ARROW')")
        check(pe("ROW(2)") == "> Field of view=75" and abs(pe("LABEL_COLOR(2)") - 0.745) < 1e-6
              and pe("ROW(1)") == "   All tweaks=On", "Down, then Right from the game's value: 75 (the normal view's own)")
        p.do("KEY('RIGHT_ARROW') KEY('RIGHT_ARROW', 'SHIFT')")
        check(pe("ROW(2)") == "> Field of view=81", "Right: 76, Shift+Right: 81 (steps of 1 and 5)")
        p.do("WAIT(1.5)")
        check(pe("FOVS()") == "81.00, 64.80, 75.60, 162.00",
              "the change works (after the 1.5 s settle time of the first tweak in a world): the camera modes x81/75")
        check(cfg_file.read_text(encoding="utf-8") == shipped_text, "1.5 s after the last key: config.lua not written yet")
        p.do("WAIT(0.6)")
        old_line = next(line for line in shipped_text.splitlines() if line.strip().startswith("FieldOfView = "))
        column = old_line.index("--")
        new_line = "    FieldOfView = 81," + " " * (column - len("    FieldOfView = 81,")) + old_line[column:]
        check(cfg_file.read_text(encoding="utf-8") == shipped_text.replace(old_line, new_line),
              "2 s after the last key: config.lua holds FieldOfView = 81, its comment in the same column, nothing else "
              "changed")
        check(p.count("Panel: saved to config.lua (FieldOfView = 81).") == 1, "one log line for the save")
        settings_count = len(settings_lines(p.log()))
        p.do("CONFIG() WAIT(1)")
        check(len(settings_lines(p.log())) == settings_count and pe("FOVS()") == "81.00, 64.80, 75.60, 162.00",
              "the next read of config.lua finds the panel's own text: nothing changes")
        p.do("KEY('LEFT_ARROW', 'SHIFT', 7)")
        check(pe("ROW(2)") == "> Field of view=Game (75)", "Shift+Left below 50: the game's own")
        p.do("KEY('LEFT_ARROW') KEY('DOWN_ARROW') KEY('RIGHT_ARROW') KEY('RIGHT_ARROW', 'SHIFT', 6)")
        check(pe("ROW(2)") == "   Field of view=Game (75)" and pe("ROW(3)") == "> Camera distance=+500"
              and pe("BAR(3)") == "=" * 20 + "/",
              "Left at the game's own stays; camera distance: +25, then Shift+Right up to the limit 500, a full bar")
        p.do("KEY('HOME')")
        check(pe("ROW(3)") == "> Camera distance=Game" and pe("BAR(3)") == "=" * 5 + "/" + "=" * 15,
              "Home: the game's value; the bar at 0 of -150 to 500")
        p.do("KEY('HOME')")
        check(pe("ROW(3)") == "> Camera distance=+500", "Home again at once: undo")
        p.do("KEY('LEFT_ARROW', 'SHIFT', 5) KEY('DOWN_ARROW') KEY('DOWN_ARROW') KEY('RIGHT_ARROW')")
        check(pe("ROW(3)") == "   Camera distance=Game" and pe("ROW(5)") == "> Ultrawide fix=Auto",
              "back to 0; the ultrawide fix: Off -> Auto")
        p.do("KEY('RIGHT_ARROW') KEY('RIGHT_ARROW')")
        check(pe("ROW(5)") == "> Ultrawide fix=Off (game)", "Auto -> On -> Off: the choices go round")
        p.do("KEY('LEFT_ARROW')")
        check(pe("ROW(5)") == "> Ultrawide fix=On", "Left from Off: On")
        p.do("KEY('DOWN_ARROW', nil, 6) KEY('RIGHT_ARROW') WAIT(1)")
        check(pe("ROW(11)") == "> Bloom=Off" and pe("PP(GAME_CAMERA).bOverride_BloomIntensity") is True
              and pe("BOX(GAME_CAMERA)") == "false false",
              "Bloom: Off, and it works at once (also the ultrawide fix On)")
        p.do("KEY('DOWN_ARROW') KEY('RIGHT_ARROW') WAIT(1)")
        check(pe("ROW(1)") == "> All tweaks=Off" and pe("IMAGE(GAME_CAMERA)") == GAME_IMAGE
              and pe("BOX(GAME_CAMERA)") == "true false" and abs(pe("LABEL_COLOR(11)") - 0.270) < 1e-6,
              "Down from the last row: All tweaks; Off: the game's own look, the other rows dimmed")
        p.do("KEY('F9')")
        saved = cfg_file.read_text(encoding="utf-8")
        loaded = pe(f"DESCRIBE(dofile({lua_path(cfg_file)}))")
        check(pe("ON_SCREEN") == 0 and "    Enable = false," in saved and '    UltrawideFix = "On",' in saved
              and "    Bloom = false," in saved and "Enable=false" in loaded and "FieldOfView=0" in loaded
              and p.count('Panel: saved to config.lua (Enable = false, FieldOfView = 0, UltrawideFix = "On", '
                          'Bloom = false).') == 1,
              "F9 closes the panel (off the screen) and saves at once; config.lua loads with the new values")
        builds = pe("BUILDS")
        p.do("KEY('RIGHT_ARROW') KEY('HOME') WAIT(3)")
        check(cfg_file.read_text(encoding="utf-8") == saved and pe("BUILDS") == builds,
              "arrows and Home with the panel closed: nothing")
        p.do("KEY('F9')")
        check(pe("BUILDS") == builds + 1 and pe("ON_SCREEN") == 1 and pe("ROW(1)") == "> All tweaks=Off",
              "F9 again: a new panel, the row kept")
        p.do("NEW_WORLD() TICK()")
        check(pe("ON_SCREEN") == 0, "a new world (a map load) closes the panel")
        p.set(config(PanelKey='"F5"'), 1)
        p.do("KEY('F9')")
        check(pe("BUILDS") == builds + 1, "PanelKey = \"F5\" (live): F9 does nothing")
        p.do("KEY('F5')")
        check(pe("BUILDS") == builds + 2 and "F5: close" in pe("PANEL()"), "F5 opens it")
        p.set(config(PanelKey='"Off"'), 0.2)
        p.do("KEY('F5') KEY('F9')")
        check(pe("ON_SCREEN") == 0 and pe("BUILDS") == builds + 2, "PanelKey = \"Off\" (live): it closes, no key opens it")
        p.set(config(), 0.5)
        p.do("KEY('F9') KEY('UP_ARROW') KEY('RIGHT_ARROW')")
        check(pe("ROW(11)") == "> Bloom=Off", "a change not saved yet")
        hand = config(CameraDistance="100")
        p.set(hand, 3)
        check(cfg_file.read_text(encoding="utf-8") == hand and pe("ROW(11)") == "> Bloom=Game"
              and pe("ROW(3)") == "   Camera distance=+100",
              "config.lua changed by hand meanwhile: the file wins, the panel shows its values and saves nothing")
        p.do("KEY('F9') WAIT(1)")
        p.set(config(), 1)
        reads = pe("READS")
        p.do("WAIT(5)")
        check(pe("READS") == reads and pe("ON_SCREEN") == 0 and not any("Error" in line for line in p.log()),
              "panel closed, every setting at the game's value: no read; no error line in this run")

        older = Run(folder("older", "return {\n    Enable = true,\n}\n"))
        older.do("KEY('F9') KEY('UP_ARROW') KEY('RIGHT_ARROW') KEY('F9')")
        check((older.folder / "config.lua").read_text(encoding="utf-8") == "return {\n    Enable = true,\n    Bloom = false,\n}\n"
              and older.count("Panel: saved to config.lua (Bloom = false).") == 1,
              "an older config.lua without the setting: the line is added before the closing brace")
        nofile = Run(folder("nofile", None))
        nofile.do("KEY('F9') KEY('UP_ARROW') KEY('RIGHT_ARROW') KEY('F9') WAIT(2)")
        bloom_off = nofile.eval("PP(GAME_CAMERA).bOverride_BloomIntensity")
        nofile.do("KEY('F9') KEY('UP_ARROW') KEY('RIGHT_ARROW') KEY('F9')")
        check(nofile.count("The panel could not save config.lua (there is no config.lua)") == 1 and bloom_off is True,
              "no config.lua: one line, the change still works until the game closes")
        locked = Run(folder("locked"))
        locked_file = locked.folder / "config.lua"
        locked_file.chmod(stat.S_IREAD)
        try:
            locked.do("KEY('F9') KEY('UP_ARROW') KEY('RIGHT_ARROW') KEY('F9')")
        finally:
            locked_file.chmod(stat.S_IREAD | stat.S_IWRITE)
        check(locked.count("The panel could not save config.lua (it cannot be written)") == 1
              and locked_file.read_text(encoding="utf-8") == shipped_text,
              "a read-only config.lua: one line, the file stays")
        noumg = Run(folder("noumg"), "UMG_PRESENT = false")
        noumg.do("for _ = 1, 7 do KEY('F9') end")
        check(noumg.count("The panel could not open (the UMG class UserWidget is not there); the tweaks in config.lua "
                          "still work.") == 5 and noumg.eval("ON_SCREEN") == 0,
              "UMG classes missing: a line per try, at most 5; nothing on the screen")
        nokeys = Run(folder("nokeys"), "RegisterKeyBind = nil")
        check(nokeys.count("This UE4SS has no key binds: the panel is not available") == 1
              and len(nokeys.g.LOOPS) == 2, "a UE4SS without key binds: one line, the tweaks' loops still there")
        badtext = Run(folder("badtext", config(Bloom="false")),
                      "TEXT_LIBRARY = Object({}, { Conv_StringToText = function() error('no text', 0) end })")
        badtext.do("KEY('F9') WAIT(2)")
        check(badtext.count("Error in the panel: no text") == 1 and badtext.eval("ON_SCREEN") == 0
              and badtext.eval("PP(GAME_CAMERA).bOverride_BloomIntensity") is True,
              "an error inside the panel: one line, the panel closes, the tweaks still work")

        # --- The settings files a player may have.
        odd = Run(folder("odd", config(UltrawideHUD='"Wide"', CameraDistance="-900")))
        check(odd.count('config.lua: UltrawideHUD = "Wide" is not one of Off, Edges, Halfway; the default Off is used.')
              == 1 and odd.count("CameraDistance = -900 is outside -150 to 500; -150 is used.") == 1,
              "a word that is not a choice, and a number out of range: the log says what is used")
        r.write_config("return {\n    Enable =\n")
        r.do("CONFIG()")
        check(any("config.lua not read (line" in line and "the last settings stay" in line for line in r.log()),
              "a broken (half-saved) file keeps the last settings")
        folders = {}
        for case, content, _ in PLAYER_CONFIGS:
            if content == "wrong types":
                content = r.eval(f"""(function()
                    local lines = {{}}
                    for name, value in pairs(dofile({lua_path(CONFIG)})) do
                        lines[#lines + 1] = string.format("    [%q] = %s,", name, type(value) == "string" and "0" or '"wrong"')
                    end
                    return "return {{\\n" .. table.concat(lines, "\\n") .. "\\n}}\\n"
                end)()""")
            folders[case] = folder(f"player{len(folders)}", content)
        defaults = settings_lines(Run(folders["an empty or older config.lua"]).log())
        check(defaults == [shipped], f"config.lua ships exactly the defaults of main.lua ({defaults})")
        count = len(list(r.eval(f"dofile({lua_path(CONFIG)})").keys()))
        for case, _, expected in PLAYER_CONFIGS:
            run = Run(folders[case])
            run.do("WAIT(3) CONFIG()")
            log = run.log()
            fine = (settings_lines(log) == defaults and len(run.g.LOOPS) == 2 and run.eval("WRITES") == 0
                    and not any("Error" in line for line in log))
            if expected is None:
                fine = fine and not any("config.lua" in line for line in log)
            else:
                fine = fine and sum(expected in line for line in log) == (count if case.endswith("wrong types") else 1)
            check(fine, f"{case}: starts with the defaults and changes nothing"
                  + (f", logs '{expected}' once per setting" if case.endswith("wrong types")
                     else (f", logs '{expected}' once" if expected else ", no warning")))
            if not fine:
                for line in log:
                    print("      log: " + line)
        off = Run(folder("off", config(Enable="false", Bloom="false")))
        off.do("WAIT(3)")
        check(len(off.g.LOOPS) == 2 and off.eval("WRITES") == 0 and off.count("changes nothing until it is true") == 1,
              "Enable = false at start: the loops are there (live settings), nothing written")
        off.set(config(Bloom="false"))
        check(off.eval("PP(GAME_CAMERA).bOverride_BloomIntensity") is True, "Enable = true later (live): applied")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
