-- Camera and Image Tweaks for Phantom Blade Zero.
--
-- What the game's own settings do not have, each a setting in config.lua that works live:
-- FieldOfView: the player camera (the Advanced Third Person Camera plugin's ATPCCameraComponent on the player) eases
--   its lens to the active camera mode's CameraModeSettings.FOVSettings.CameraFOV (UATPCCameraModeDataAsset; about
--   120 modes: the normal shoulder view at 75, combat, special moves, doors...). The mod multiplies every mode's value
--   by FieldOfView / the normal view's own (the component's default camera mode), so combat, lock-on and special-move
--   views keep their zoom in proportion. Cutscenes use their own cameras and keep their framing.
-- CameraDistance: one named additive distance on the player's camera component (SetAdditiveParameter_Distance, blend
--   DISTANCE_BLEND s), in every camera mode, on top of the game's own distance changes (the normal distance is 350).
-- LockOnHeight: one named additive socket offset (SetAdditiveParameter_SocketOffset, Z only, blend LOCK_BLEND s), only
--   while the camera is in a lock-on camera mode (its tag holds one of LOCK_PATTERNS).
-- UltrawideFix: gameplay is already wide on wider screens (the local player's AspectRatioAxisConstraint is
--   MaintainYFOV). Cutscene cameras box the picture to their own aspect ratio: the mod turns bConstrainAspectRatio and
--   bOverrideAspectRatioAxisConstraint off on every camera component (also on cameras made later), the camera manager's
--   bDefaultConstrainAspectRatio off, and makes sure the local player keeps MaintainYFOV. "Auto": only on screens wider
--   than ULTRAWIDE_ASPECT.
-- UltrawideHUD: the game lays its HUD out in a centred 16:9 box. On a wider screen the mod gives the HUD's health bar,
--   quick slots and buffs (left) and weapons (right) a render translation towards the screen edges (paint only), in
--   the box's 1920x1080 design units: (1080 * aspect - 1920) / 2 for "Edges", half of it for "Halfway".
-- ChromaticAberration, Vignette (with film grain), LensFlares, Bloom: false sets a post-process override of 0 on every
--   camera component (PostProcessSettings.bOverride_<X> = true, <X> = 0); the engine blends it into the view a frame
--   later. DepthOfField false stops every cine camera down to its highest f-number (CurrentAperture =
--   LensSettings.MaxFStop), which removes nearly all background blur; the gameplay camera is already at f/40. (Console
--   variables do nothing in this game since its update of 2026-11-04, so these are not console variables.)
--
-- Every value the mod changes is remembered when it first changes it, and written back when its setting goes back to
-- the game's value or Enable is false. With every setting at its default the mod reads and writes nothing in the game.
--
-- How: a loop on the game thread every TICK_MS does the work of each tweak that is set or still has something to put
-- back, each inside pcall. When the world changes (a map load), the mod forgets the old world's objects and waits
-- SETTLE_SECONDS. Objects it keeps are used only after IsValid() in the same tick. Searches: the engine once; every
-- camera component (FindAllOf) when the ultrawide fix starts or the world changed, and every IMAGE_RESCAN_SECONDS while
-- an image switch is off; the HUD every HUD_FIND_SECONDS while it is not found. New camera components come through
-- NotifyOnNewObject (UE4SS runs its callback on the game thread) and are taken NEW_CAMERA_SETTLE_SECONDS later, when
-- their construction is done. Every property the mod reads on a kept object is defined in a native class, so UE4SS's
-- stale FindProperty cache (a freed property of an unloaded Blueprint class) does not reach it.
--
-- Taken over from the user's PhantomTweaks 1.1.1 (the same game calls, values and times), without its settings.ini,
-- its compare key and its command channel: every tweak is a live config.lua setting (1.0, 2026-11-12). 1.1 (the
-- user's wish, 2026-11-13) brings back the source's
-- keyboard panel ("The panel" below): PanelKey (F9) opens it, a row per setting, a bar for the numbers, an "All
-- tweaks" row instead of the compare key, and every change goes into config.lua.
--
-- Settings: the player edits Scripts\config.lua. The mod reads it at start and again every CONFIG_INTERVAL_MS, and a
-- change shows within a moment, without a restart; a broken or half-saved file keeps the last settings. DEFAULTS holds
-- every setting with its default, LIMITS the range of a number, CHOICES the words of a text setting. A player (or a mod
-- manager) keeps their config.lua across updates, so a new main.lua can meet an older file: a setting that the file
-- lacks, or has with another type, keeps its default, and the log says so. Read a setting only from Settings, never as
-- `config.X or default`: for a true/false setting, `false or true` is true.

local MOD_NAME = "Camera and Image Tweaks"
local VERSION = "1.1"
local TICK_MS = 100
local CONFIG_INTERVAL_MS = 5000
-- After a map load the mod waits this long before it touches anything.
local SETTLE_SECONDS = 1.5
-- The engine object is searched for at most this often while it is missing.
local ENGINE_RETRY_SECONDS = 5
-- Log at most this many error lines, state lines and LogDetail lines per game start.
local MAX_ERROR_LOGS = 10
local MAX_STATE_LOGS = 100
local MAX_DETAIL_LOGS = 400

-- The player's camera and its camera modes.
local CAMERA_CLASS = "/Script/AdvancedThirdPersonCamera.ATPCCameraComponent"
local FOV_MIN = 50                 -- FieldOfView below this (and above 0) means the game's own
local FOV_FALLBACK = 75            -- the normal view's field of view when its camera mode is not found
local FOV_LOWEST, FOV_HIGHEST = 10, 170   -- a scaled camera mode stays inside these
local MODE_CHECK_SECONDS = 2       -- between looks for camera modes that are new or loaded again
local DISTANCE_PARAMETER = "CameraAndImageTweaks"
local DISTANCE_BLEND = 0.5
local DISTANCE_RESEND_SECONDS = 5  -- the distance is sent again this often, in case the game reset it
local LOCK_PARAMETER = "CameraAndImageTweaksLockOn"
local LOCK_BLEND = 0.4
local LOCK_PATTERNS = { "Focus", "LockTarget", "LockView", "TargetLock" }
-- Camera components, the screen and the HUD.
local NEW_CAMERA_CLASS = "/Script/Engine.CameraComponent"
local CAMERA_SEARCH_CLASSES = { "CameraComponent", "CineCameraComponent" }
local NEW_CAMERA_SETTLE_SECONDS = 0.05
local MAX_PENDING_CAMERAS = 256
local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetLayoutLibrary"
local ULTRAWIDE_ASPECT = 1.9       -- "Auto" counts a screen wider than this (width / height) as ultrawide
local MAINTAIN_YFOV = 0            -- EAspectRatioAxisConstraint::AspectRatio_MaintainYFOV
local IMAGE_RESCAN_SECONDS = 3
local KEEP_PREVIOUS_SECONDS = 10
local IMAGE_SWITCHES = {
    { setting = "ChromaticAberration", fields = { "SceneFringeIntensity" } },
    { setting = "Vignette", fields = { "VignetteIntensity", "FilmGrainIntensity" } },
    { setting = "LensFlares", fields = { "LensFlareIntensity" } },
    { setting = "Bloom", fields = { "BloomIntensity" } },
}
local HUD_CLASS = "W_FrontEndHUDLayout_C"
local HUD_LEFT = { "WB_PlayerHPBar", "WB_quickslot", "W_BuffBar" }
local HUD_RIGHT = { "W_WeaponUI" }
local HUD_SPREAD = { Edges = 1.0, Halfway = 0.5 }
local HUD_CHECK_SECONDS = 0.25
local HUD_FIND_SECONDS = 3
local HUD_MAX_WIDGETS = 400
local HUD_MAX_DEPTH = 12
-- The panel. F10 is not offered: UE4SS's ConsoleEnablerMod makes it a console key.
local PANEL_KEYS = { "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F11", "F12" }
local PANEL_SAVE_SECONDS = 2       -- a change goes into config.lua this long after the last key press
local PANEL_MAX_KEYS = 32          -- key presses waiting for the game thread
local PANEL_BAR = 20               -- the length of a value bar, in characters
local PANEL_WIDTH = 900
local PANEL_HEIGHT_SHARE = 0.55    -- the panel's height as a share of the screen's
local PANEL_Z_ORDER = 80
local PANEL_MAX_FAIL_LOGS = 5
local PANEL_MAX_SAVE_LOGS = 50
local FONT_PATH = "/Engine/EngineFonts/Roboto.Roboto"
local TEXT_LIBRARY = "/Script/Engine.Default__KismetTextLibrary"
local VISIBLE_NO_MOUSE = 3         -- ESlateVisibility::HitTestInvisible: shown, never takes the mouse

-- Every setting with its default; config.lua ships the same names and values (tests\test_main.py checks it). Every
-- default leaves the game as it is.
local DEFAULTS = {
    Enable = true,
    FieldOfView = 0,
    CameraDistance = 0,
    LockOnHeight = 0,
    UltrawideFix = "Off",
    UltrawideHUD = "Off",
    ChromaticAberration = true,
    Vignette = true,
    DepthOfField = true,
    LensFlares = true,
    Bloom = true,
    PanelKey = "F9",
    LogDetail = false,
}
-- The order of the settings in a config.lua the panel writes from nothing (a missing setting is added at the end).
local SETTING_ORDER = {
    "Enable", "FieldOfView", "CameraDistance", "LockOnHeight", "UltrawideFix", "UltrawideHUD", "ChromaticAberration",
    "Vignette", "DepthOfField", "LensFlares", "Bloom", "PanelKey", "LogDetail",
}
-- Number settings outside their range are clamped.
local LIMITS = {
    FieldOfView = { 0, 130 },
    CameraDistance = { -150, 500 },
    LockOnHeight = { -150, 100 },
}
-- The words a text setting takes (any case).
local CHOICES = {
    UltrawideFix = { "Off", "Auto", "On" },
    UltrawideHUD = { "Off", "Edges", "Halfway" },
    PanelKey = { "Off", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F11", "F12" },
}

local errors, stateLogs, detailLogs = 0, 0, 0
local Settings = {}
-- The settings as config.lua holds them now (after a read, or a save of the panel). The panel saves only what differs
-- from them, so a file changed by hand wins over a panel change that is not saved yet.
local fileSettings = {}

local function Log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local function LogError(message)
    errors = errors + 1
    if errors <= MAX_ERROR_LOGS then
        Log(message)
    end
end

-- LogDetail lines; message is a function, so nothing is built while LogDetail is off.
local function Detail(message)
    if Settings.LogDetail and detailLogs < MAX_DETAIL_LOGS then
        detailLogs = detailLogs + 1
        Log(message())
    end
end

local function FirstLine(message)
    return (tostring(message):match("^[^\n]*"))
end

local function Now()
    return os.clock()
end

-- The state of each tweak in the log: a line when its state changes (on, off, not available...), a LogDetail line
-- when only its details change or while it waits for the game.
local PARTS = { "fov", "distance", "lockon", "ultrawide", "hud", "image" }
local LABELS = {
    fov = "Field of view", distance = "Camera distance", lockon = "Lock-on height", ultrawide = "Ultrawide fix",
    hud = "Ultrawide HUD", image = "Image switches",
}
local reported, reportedState = {}, {}
for _, part in ipairs(PARTS) do
    reported[part], reportedState[part] = "off", "off"
end

local function Report(part, state, detail)
    local text = detail and (state .. " (" .. detail .. ")") or state
    if reported[part] == text then
        return
    end
    reported[part] = text
    local line = LABELS[part] .. ": " .. text .. "."
    if state ~= "waiting" and state ~= reportedState[part] and stateLogs < MAX_STATE_LOGS then
        reportedState[part] = state
        stateLogs = stateLogs + 1
        Log(line)
    else
        Detail(function()
            return line
        end)
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------------------------------

local function CopyDefaults()
    local settings = {}
    for name, value in pairs(DEFAULTS) do
        settings[name] = value
    end
    return settings
end

-- One line for the log: every setting, sorted by name.
local function Describe(settings)
    local names = {}
    for name in pairs(settings) do
        names[#names + 1] = name
    end
    table.sort(names)
    local parts = {}
    for i, name in ipairs(names) do
        parts[i] = name .. "=" .. tostring(settings[name])
    end
    return table.concat(parts, ", ")
end

-- Lua's line number and reason, without the chunk name.
local function Reason(message)
    message = tostring(message)
    local line, reason = message:match("config%.lua:(%d+): ([^\n]*)")
    return line and ("line " .. line .. ": " .. reason) or (message:gsub("%s*\n%s*", " "))
end

-- DEFAULTS with the values of config.lua's text over them; nil and the reason when the text is not a usable file.
local function ParseConfig(text)
    local chunk, problem = load(text, "=config.lua", "t", {})
    if not chunk then
        return nil, "config.lua not read (" .. Reason(problem) .. ")"
    end
    local ok, config = pcall(chunk)
    if not ok then
        return nil, "config.lua not read (" .. Reason(config) .. ")"
    end
    if type(config) ~= "table" then
        return nil, "config.lua does not return a table"
    end
    local settings = CopyDefaults()
    for name, value in pairs(config) do
        local default = DEFAULTS[name]
        local limit = LIMITS[name]
        local choices = CHOICES[name]
        if default == nil then
            Log("config.lua: unknown setting " .. tostring(name) .. " ignored.")
        elseif type(value) ~= type(default) then
            Log(string.format("config.lua: %s must be a %s; the default %s is used.", name, type(default),
                tostring(default)))
        elseif choices then
            local match = nil
            for _, choice in ipairs(choices) do
                if choice:lower() == value:lower() then
                    match = choice
                end
            end
            if match then
                settings[name] = match
            else
                Log(string.format('config.lua: %s = "%s" is not one of %s; the default %s is used.', name, value,
                    table.concat(choices, ", "), default))
            end
        elseif limit and value ~= value then
            Log(string.format("config.lua: %s is not a number; the default %s is used.", name, tostring(default)))
        elseif limit and (value < limit[1] or value > limit[2]) then
            local clamped = math.min(limit[2], math.max(limit[1], value))
            Log(string.format("config.lua: %s = %s is outside %s to %s; %s is used.", name, tostring(value),
                tostring(limit[1]), tostring(limit[2]), tostring(clamped)))
            settings[name] = clamped
        else
            settings[name] = value
        end
    end
    -- A field of view between 0 and FOV_MIN means the game's own, as in the source mod.
    if settings.FieldOfView > 0 and settings.FieldOfView < FOV_MIN then
        Log(string.format("config.lua: FieldOfView = %s is below %d; 0 (the game's own) is used.",
            tostring(settings.FieldOfView), FOV_MIN))
        settings.FieldOfView = 0
    end
    return settings
end

local configPath = nil
-- The text of the last read; false: no file at the last read; nil: not read yet.
local configText = nil

-- Reads config.lua when its text changed since the last read. At start, a missing or broken file means the defaults;
-- later, a broken file keeps the last settings (a half-saved file), and a missing one means the defaults.
local function ReadConfig()
    local atStart = configText == nil
    configPath = configPath or package.searchpath("config", package.path)
    local text = false
    if configPath then
        local file = io.open(configPath, "rb")
        if file then
            text = file:read("a") or false
            file:close()
        end
    end
    if text == configText then
        return
    end
    configText = text
    local settings, problem
    if text == false then
        settings, problem = CopyDefaults(), nil
        Log("No config.lua; every setting uses its default.")
    else
        settings, problem = ParseConfig(text)
    end
    if not settings then
        if atStart then
            Log(problem .. "; every setting uses its default.")
            settings = CopyDefaults()
        else
            Log(problem .. "; the last settings stay.")
            return
        end
    end
    local line = Describe(settings)
    if atStart or line ~= Describe(Settings) then
        Log("Settings: " .. line)
    end
    Settings = settings
    fileSettings = CopyDefaults()
    for name, value in pairs(settings) do
        fileSettings[name] = value
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Game objects
---------------------------------------------------------------------------------------------------------------------

local function Valid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

local function Address(object)
    if object == nil then
        return nil
    end
    local ok, address = pcall(function()
        return object:GetAddress()
    end)
    if ok and type(address) == "number" and address ~= 0 then
        return address
    end
    return nil
end

-- A kept game object; Alive gives it back only while it is valid (a level load or a garbage collection frees
-- objects, and anything but IsValid on a freed one can crash inside UE4SS, where pcall cannot catch it).
local function Keep(object)
    local address = Address(object)
    if not address then
        return nil
    end
    return { object = object, address = address }
end

local function Alive(kept)
    if kept and Valid(kept.object) then
        return kept.object
    end
    return nil
end

local function FullName(object)
    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    if ok and type(name) == "string" then
        return name
    end
    return nil
end

-- The engine is found once; the world, the local player and its controller are read through it as properties.
local engineObject = nil
local engineSearch = -math.huge
local widgetLibrary = nil

local function Engine(now)
    if Valid(engineObject) then
        return engineObject
    end
    if now - engineSearch < ENGINE_RETRY_SECONDS then
        return nil
    end
    engineSearch = now
    local found = FindFirstOf("GameEngine")
    if not Valid(found) then
        found = FindFirstOf("Engine")
    end
    if Valid(found) then
        engineObject = found
        return found
    end
    return nil
end

local function World(now)
    local engine = Engine(now)
    if not engine then
        return nil
    end
    local ok, world = pcall(function()
        local viewport = engine.GameViewport
        if Valid(viewport) then
            return viewport.World
        end
        return nil
    end)
    if ok and Valid(world) then
        return world
    end
    return nil
end

local function LocalPlayer(now)
    local engine = Engine(now)
    if not engine then
        return nil
    end
    local ok, player = pcall(function()
        local instance = engine.GameInstance
        if not Valid(instance) then
            return nil
        end
        local players = instance.LocalPlayers
        if players and #players > 0 then
            return players[1]
        end
        return nil
    end)
    if ok and Valid(player) then
        return player
    end
    return nil
end

local function PlayerController(now)
    local player = LocalPlayer(now)
    if not player then
        return nil
    end
    local ok, controller = pcall(function()
        return player.PlayerController
    end)
    if ok and Valid(controller) then
        return controller
    end
    return nil
end

-- The viewport's width / height, or nil.
local function ViewportAspect(world)
    if not world then
        return nil
    end
    local ok, aspect = pcall(function()
        if not Valid(widgetLibrary) then
            widgetLibrary = StaticFindObject(WIDGET_LIBRARY)
        end
        local size = widgetLibrary:GetViewportSize(world)
        if size and type(size.X) == "number" and type(size.Y) == "number" and size.Y > 0 then
            return size.X / size.Y
        end
        return nil
    end)
    if ok then
        return aspect
    end
    return nil
end

local function AspectText(aspect)
    return aspect and string.format("%.2f:1", aspect) or "not known yet"
end

-- The player's camera component (an ATPCCameraComponent on the pawn), or nil (main menu, loading).
local camera = { class = nil, pawn = nil, kept = nil }

local function PlayerCamera(now)
    local controller = PlayerController(now)
    if not controller then
        return nil
    end
    local okp, pawn = pcall(function()
        return controller:K2_GetPawn()
    end)
    if not okp or not Valid(pawn) then
        return nil
    end
    local pawnAddress = Address(pawn)
    if camera.pawn == pawnAddress then
        local component = Alive(camera.kept)
        if component then
            return component
        end
    end
    if not Valid(camera.class) then
        camera.class = StaticFindObject(CAMERA_CLASS)
    end
    if not Valid(camera.class) then
        return nil
    end
    local okc, component = pcall(function()
        return pawn:GetComponentByClass(camera.class)
    end)
    if not okc or not Valid(component) then
        return nil
    end
    camera.pawn, camera.kept = pawnAddress, Keep(component)
    return component
end

---------------------------------------------------------------------------------------------------------------------
-- Field of view: every camera mode's target field of view, scaled
---------------------------------------------------------------------------------------------------------------------

local fov = {
    modes = {},          -- full name -> { kept, fov = the game's own CameraFOV }
    base = nil,          -- the normal view's own field of view (the default camera mode's original)
    factor = nil,        -- the factor applied to the modes we know now; nil: apply again
    lastFactor = 1,      -- the last factor written (kept across a map load)
    scaled = false,      -- true while a mode may hold a value of ours
    count = 0,
    lastCheck = -math.huge,
}

local function ModeFov(mode)
    local ok, value = pcall(function()
        return mode.CameraModeSettings.FOVSettings.CameraFOV
    end)
    if ok and type(value) == "number" then
        return value
    end
    return nil
end

local function SetModeFov(mode, value)
    pcall(function()
        mode.CameraModeSettings.FOVSettings.CameraFOV = value
    end)
end

local function ScaledFov(original, factor)
    return math.max(FOV_LOWEST, math.min(FOV_HIGHEST, original * factor))
end

local function Near(a, b)
    return math.abs(a - b) <= 1e-3
end

-- Records every mode the component has loaded (its original field of view once, while it is still the game's own).
-- Returns the number of modes and whether any are new to us. The game loads the mode assets again in a new region as
-- new objects under the same names; such an object holds the game's own value again, unless it was copied from ours.
local function CollectModes(component)
    local ok, map = pcall(function()
        return component.SortedCameraModes
    end)
    if not ok or not map then
        return 0, false
    end
    local count, fresh = 0, false
    pcall(function()
        map:ForEach(function(_, value)
            local mode = value:get()
            if not Valid(mode) then
                return
            end
            count = count + 1
            local name = FullName(mode)
            if not name then
                return
            end
            local entry = fov.modes[name]
            if not entry then
                local original = ModeFov(mode)
                if original then
                    fov.modes[name] = { kept = Keep(mode), fov = original }
                    fresh = true
                end
            elseif not entry.kept or Address(mode) ~= entry.kept.address or not Alive(entry.kept) then
                local current = ModeFov(mode)
                if current then
                    if not Near(current, ScaledFov(entry.fov, fov.lastFactor)) then
                        entry.fov = current
                    end
                    entry.kept = Keep(mode)
                    fresh = true
                end
            end
        end)
    end)
    if not fov.base then
        -- The normal view: the component's default camera mode.
        local okt, tag = pcall(function()
            return component.DefaultCameraModeTag.TagName:ToString()
        end)
        if okt and type(tag) == "string" then
            pcall(function()
                map:ForEach(function(_, value)
                    local mode = value:get()
                    local okm, modeTag = pcall(function()
                        return mode.CameraModeTag.TagName:ToString()
                    end)
                    if okm and modeTag == tag then
                        local entry = fov.modes[FullName(mode) or ""]
                        fov.base = entry and entry.fov or ModeFov(mode)
                    end
                end)
            end)
        end
    end
    return count, fresh
end

-- A kept mode only while it is valid and still has its name (after a garbage collection another object can sit at
-- the same address).
local function ModeObject(name, entry)
    local mode = Alive(entry.kept)
    if mode and FullName(mode) == name then
        return mode
    end
    return nil
end

local function ApplyFactor(factor)
    local count = 0
    for name, entry in pairs(fov.modes) do
        local mode = ModeObject(name, entry)
        if mode then
            local wanted = ScaledFov(entry.fov, factor)
            if not Near(ModeFov(mode) or 0, wanted) then
                SetModeFov(mode, wanted)
            end
            count = count + 1
        end
    end
    fov.factor, fov.lastFactor, fov.scaled = factor, factor, factor ~= 1
    return count
end

-- Whether the game put a mode's value back since we wrote it (the same object, its values loaded again). A value that
-- is neither ours nor the original we know is the game's new original.
local function Drifted()
    local any = false
    for name, entry in pairs(fov.modes) do
        local mode = ModeObject(name, entry)
        local current = mode and ModeFov(mode)
        if current and not Near(current, ScaledFov(entry.fov, fov.factor)) then
            if not Near(current, entry.fov) then
                entry.fov = current
            end
            any = true
        end
    end
    return any
end

local function TickFieldOfView(component, now)
    local want = Settings.Enable and Settings.FieldOfView > 0
    if not component then
        if not want and fov.scaled then
            ApplyFactor(1)
        end
        Report("fov", want and "waiting" or "off", want and "no player camera yet" or nil)
        return
    end
    if fov.count == 0 or now - fov.lastCheck >= MODE_CHECK_SECONDS then
        fov.lastCheck = now
        local count, fresh = CollectModes(component)
        if count ~= fov.count or fresh or (fov.factor and Drifted()) then
            if fov.count > 0 then
                Detail(function()
                    return string.format("Camera modes changed (%d -> %d%s): the field of view is applied again.",
                        fov.count, count, fresh and ", loaded again" or "")
                end)
            end
            fov.count, fov.factor = count, nil
        end
    end
    local base = fov.base or FOV_FALLBACK
    local factor = want and Settings.FieldOfView / base or 1
    if fov.factor ~= factor then
        ApplyFactor(factor)
    end
    if fov.count == 0 then
        Report("fov", want and "not found" or "off", want and "the player's camera has no camera modes" or nil)
    elseif want then
        Report("fov", "on", string.format("%d camera modes x%.3f; the normal view's own: %g", fov.count, factor, base))
    else
        Report("fov", "off")
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Camera distance and lock-on height: named additive parameters of the player's camera component
---------------------------------------------------------------------------------------------------------------------

-- applied: the value of ours on the component at `component` (an address); a new component has none.
local distance = { name = nil, component = nil, applied = 0, sent = -math.huge }
local lock = { name = nil, component = nil, applied = 0 }

local function TickDistance(component, now)
    local want = Settings.Enable and Settings.CameraDistance or 0
    if not component then
        Report("distance", want ~= 0 and "waiting" or "off", want ~= 0 and "no player camera yet" or nil)
        return
    end
    local address = Address(component)
    if distance.component ~= address then
        distance.component, distance.applied = address, 0
    end
    if distance.applied ~= want or (want ~= 0 and now - distance.sent >= DISTANCE_RESEND_SECONDS) then
        distance.name = distance.name or FName(DISTANCE_PARAMETER)
        local ok, err = pcall(function()
            component:SetAdditiveParameter_Distance(distance.name, want, DISTANCE_BLEND)
        end)
        if not ok then
            Report("distance", "not available", "SetAdditiveParameter_Distance: " .. FirstLine(err))
            return
        end
        distance.applied, distance.sent = want, now
    end
    if want ~= 0 then
        Report("distance", "on", string.format("%+g", want))
    else
        Report("distance", "off")
    end
end

local function IsLockTag(tag)
    if type(tag) ~= "string" then
        return false
    end
    for _, pattern in ipairs(LOCK_PATTERNS) do
        if tag:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local function TickLockOn(component)
    local height = Settings.Enable and Settings.LockOnHeight or 0
    if not component then
        Report("lockon", height ~= 0 and "waiting" or "off", height ~= 0 and "no player camera yet" or nil)
        return
    end
    local address = Address(component)
    if lock.component ~= address then
        lock.component, lock.applied = address, 0
    end
    local tag = nil
    if height ~= 0 or lock.applied ~= 0 then
        local ok, text = pcall(function()
            return component:GetCurrentCameraModeTag().TagName:ToString()
        end)
        if ok and type(text) == "string" then
            tag = text
        end
    end
    local want = (height ~= 0 and IsLockTag(tag)) and height or 0
    if lock.applied ~= want then
        lock.name = lock.name or FName(LOCK_PARAMETER)
        -- A plain vector as a Lua table (a struct without arrays); the source mod measured this call in game.
        local ok, err = pcall(function()
            component:SetAdditiveParameter_SocketOffset(lock.name, { X = 0, Y = 0, Z = want }, LOCK_BLEND)
        end)
        if not ok then
            Report("lockon", "not available", "SetAdditiveParameter_SocketOffset: " .. FirstLine(err))
            return
        end
        lock.applied = want
    end
    if height == 0 then
        Report("lockon", "off")
    elseif want ~= 0 then
        Report("lockon", "on", string.format("%+g in the camera mode %s", want, tag))
    else
        Report("lockon", "waiting", "for a lock-on camera mode; now " .. tostring(tag))
    end
end

---------------------------------------------------------------------------------------------------------------------
-- New camera components (NotifyOnNewObject)
---------------------------------------------------------------------------------------------------------------------

-- touched: the camera components we changed. previous: those of the last world check, kept for
-- KEEP_PREVIOUS_SECONDS: when the same camera is found again (the world check saw a change, but the camera is still
-- there), it keeps its true originals, not the values of ours that we would read from it now.
local ultrawide = {
    on = false,
    scanned = false,     -- the camera components of this world were searched
    lastScan = -math.huge,
    touched = {},        -- address -> { kept, name, constrain, override }
    previous = {},
    player = nil,        -- { kept, original, changed }: the local player's AspectRatioAxisConstraint
    manager = nil,       -- { kept, original, changed }: the camera manager's bDefaultConstrainAspectRatio
}
local image = {
    active = false,
    touched = {},        -- address -> { kept, name, saved = { field -> { flag, value } }, aperture = original or nil }
    previous = {},
    lastScan = -math.huge,
    resets = 0,
}
local previousUntil = -math.huge
local pending = {}           -- { object, time }: camera components the game made since the last tick
local newCameraNotice = false

-- A kept camera only while it is valid and still has its name (after a garbage collection another object can sit at
-- the same address).
local function NamedAlive(entry)
    local object = Alive(entry.kept)
    if object and FullName(object) == entry.name then
        return object
    end
    return nil
end

-- The entry of `object` in `previous` when it is the same camera, taken back into `touched`.
local function TakeBack(part, address, object)
    local old = part.previous[address]
    if old and Now() < previousUntil and Alive(old.kept) and FullName(object) == old.name then
        part.touched[address], part.previous[address] = old, nil
        return true
    end
    return false
end

-- Runs on the game thread (UE4SS queues an object made on another thread and calls this later on the game thread),
-- while the object is still being built: it is only noted here.
local function OnNewCamera(object)
    if (ultrawide.on or image.active) and #pending < MAX_PENDING_CAMERAS then
        pending[#pending + 1] = { object = object, time = Now() }
    end
    return false
end

---------------------------------------------------------------------------------------------------------------------
-- Ultrawide fix
---------------------------------------------------------------------------------------------------------------------

local function UnboxCamera(object)
    if not Valid(object) then
        return
    end
    local address = Address(object)
    if not address or ultrawide.touched[address] or TakeBack(ultrawide, address, object) then
        return
    end
    local name = FullName(object)
    if not name or name:find("Default__", 1, true) then
        return
    end
    local ok1, constrain = pcall(function()
        return object.bConstrainAspectRatio
    end)
    local ok2, override = pcall(function()
        return object.bOverrideAspectRatioAxisConstraint
    end)
    constrain = ok1 and constrain == true
    override = ok2 and override == true
    if not constrain and not override then
        return
    end
    ultrawide.touched[address] = { kept = Keep(object), name = name, constrain = constrain, override = override }
    if constrain then
        pcall(function()
            object.bConstrainAspectRatio = false
        end)
    end
    if override then
        pcall(function()
            object.bOverrideAspectRatioAxisConstraint = false
        end)
    end
    Detail(function()
        return "Ultrawide fix: unboxed " .. name .. "."
    end)
end

local function ScanCameras(take)
    for _, class in ipairs(CAMERA_SEARCH_CLASSES) do
        local ok, list = pcall(FindAllOf, class)
        if ok and type(list) == "table" then
            for _, object in ipairs(list) do
                pcall(take, object)
            end
        end
    end
end

-- The two values of the local player and the camera manager that the fix sets.
local function ReadAxis(object)
    return object.AspectRatioAxisConstraint
end

local function WriteAxis(object, value)
    object.AspectRatioAxisConstraint = value
end

local function ReadBox(object)
    return object.bDefaultConstrainAspectRatio
end

local function WriteBox(object, value)
    object.bDefaultConstrainAspectRatio = value
end

-- Gives a held object its own value back, when the mod changed it and the object is still the same one.
local function Release(record, write)
    if record and record.changed then
        local object = NamedAlive(record)
        if object then
            pcall(write, object, record.original)
        end
    end
end

-- Remembers an object's value before the first change (the record), then writes `wanted` whenever the object holds
-- another value. The record lives across map loads; for another object it starts again, and the old one gets its own
-- value back first.
local function Hold(record, object, read, write, wanted)
    if record and record.kept.address ~= Address(object) then
        Release(record, write)
        record = nil
    end
    if not record then
        local ok, original = pcall(read, object)
        local kept = Keep(object)
        if not ok or original == nil or not kept then
            return nil
        end
        record = { kept = kept, name = FullName(object), original = original, changed = false }
    end
    local ok, current = pcall(read, object)
    if ok and current ~= wanted and pcall(write, object, wanted) then
        record.changed = true
    end
    return record
end

local function RestoreUltrawide()
    for _, list in ipairs({ ultrawide.touched, ultrawide.previous }) do
        for address, entry in pairs(list) do
            local object = NamedAlive(entry)
            if object then
                if entry.constrain then
                    pcall(function()
                        object.bConstrainAspectRatio = true
                    end)
                end
                if entry.override then
                    pcall(function()
                        object.bOverrideAspectRatioAxisConstraint = true
                    end)
                end
            end
            list[address] = nil
        end
    end
    Release(ultrawide.player, WriteAxis)
    Release(ultrawide.manager, WriteBox)
    ultrawide.player, ultrawide.manager = nil, nil
    ultrawide.on, ultrawide.scanned = false, false
end

local function UltrawideWanted(aspect)
    if not Settings.Enable or Settings.UltrawideFix == "Off" then
        return false
    end
    if Settings.UltrawideFix == "On" then
        return true
    end
    if aspect == nil then
        return ultrawide.on   -- no viewport for a moment (loading): keep what we have
    end
    return aspect > ULTRAWIDE_ASPECT
end


local function TickUltrawide(now, aspect)
    local want = UltrawideWanted(aspect)
    if not want then
        if ultrawide.on or ultrawide.player or ultrawide.manager or next(ultrawide.previous) then
            RestoreUltrawide()
        end
        if Settings.Enable and Settings.UltrawideFix == "Auto" then
            Report("ultrawide", "not needed", string.format("Auto: the screen is %s, not wider than %g:1",
                AspectText(aspect), ULTRAWIDE_ASPECT))
        else
            Report("ultrawide", "off")
        end
        return
    end
    ultrawide.on = true
    -- Without NotifyOnNewObject, new cameras are found by a search every IMAGE_RESCAN_SECONDS.
    if not ultrawide.scanned or (not newCameraNotice and now - ultrawide.lastScan >= IMAGE_RESCAN_SECONDS) then
        ultrawide.scanned, ultrawide.lastScan = true, now
        ScanCameras(UnboxCamera)
    end
    local player = LocalPlayer(now)
    if player then
        ultrawide.player = Hold(ultrawide.player, player, ReadAxis, WriteAxis, MAINTAIN_YFOV)
    end
    local controller = PlayerController(now)
    local okm, manager = pcall(function()
        return controller and controller.PlayerCameraManager
    end)
    if okm and Valid(manager) then
        ultrawide.manager = Hold(ultrawide.manager, manager, ReadBox, WriteBox, false)
    end
    local count = 0
    for _ in pairs(ultrawide.touched) do
        count = count + 1
    end
    Report("ultrawide", "on", string.format("%d camera%s unboxed", count, count == 1 and "" or "s"))
end

---------------------------------------------------------------------------------------------------------------------
-- Image switches: post-process overrides on every camera component, and the cine cameras' aperture
---------------------------------------------------------------------------------------------------------------------

-- The fields to override (field -> 0) and whether depth of field is off.
local function ImageWanted()
    local fields, aperture = {}, false
    if not Settings.Enable then
        return fields, aperture
    end
    for _, switch in ipairs(IMAGE_SWITCHES) do
        if Settings[switch.setting] == false then
            for _, field in ipairs(switch.fields) do
                fields[field] = 0
            end
        end
    end
    return fields, Settings.DepthOfField == false
end

local function AddImageCamera(object)
    if not Valid(object) then
        return
    end
    local address = Address(object)
    if not address or image.touched[address] or TakeBack(image, address, object) then
        return
    end
    local name = FullName(object)
    if not name or name:find("Default__", 1, true) then
        return
    end
    -- Only real camera components have the settings struct.
    local okp, settings = pcall(function()
        return object.PostProcessSettings
    end)
    if not okp or not settings then
        return
    end
    local okb, flag = pcall(function()
        return settings.bOverride_BloomIntensity
    end)
    if not okb or type(flag) ~= "boolean" then
        return
    end
    image.touched[address] = { kept = Keep(object), name = name, saved = {}, aperture = nil }
end

-- Brings one camera in line with the wanted fields and aperture; returns the number of writes.
local function SyncImage(object, entry, fields, aperture)
    local writes = 0
    local settings = object.PostProcessSettings
    if not settings then
        return 0
    end
    for field, target in pairs(fields) do
        local flag = settings["bOverride_" .. field]
        local value = settings[field]
        local right = flag == true and value == target
        if entry.saved[field] == nil then
            entry.saved[field] = { flag = flag, value = value }
        elseif not right then
            image.resets = image.resets + 1   -- the game put its own value back
        end
        if not right then
            settings["bOverride_" .. field] = true
            settings[field] = target
            writes = writes + 1
        end
    end
    for field, saved in pairs(entry.saved) do
        if fields[field] == nil then
            settings["bOverride_" .. field] = saved.flag
            settings[field] = saved.value
            entry.saved[field] = nil
            writes = writes + 1
        end
    end
    local okc, current = pcall(function()
        return object.CurrentAperture
    end)
    if okc and type(current) == "number" then
        local okm, highest = pcall(function()
            return object.LensSettings.MaxFStop
        end)
        if okm and type(highest) == "number" then
            if aperture then
                if current < highest - 0.01 then
                    if entry.aperture == nil then
                        entry.aperture = current
                    else
                        image.resets = image.resets + 1
                    end
                    object.CurrentAperture = highest
                    writes = writes + 1
                end
            elseif entry.aperture ~= nil then
                if math.abs(current - highest) < 0.01 then
                    object.CurrentAperture = entry.aperture
                    writes = writes + 1
                end
                entry.aperture = nil
            end
        end
    end
    return writes
end

local function TickImage(now)
    local fields, aperture = ImageWanted()
    local any = next(fields) ~= nil or aperture
    image.active = any
    if not any and next(image.previous) ~= nil then
        -- Handed back while the cameras of the last world were still waiting to be found again.
        for address, entry in pairs(image.previous) do
            local object = NamedAlive(entry)
            if object then
                pcall(SyncImage, object, entry, {}, false)
            end
            image.previous[address] = nil
        end
    end
    if not any and next(image.touched) == nil then
        Report("image", "off")
        return
    end
    if any and now - image.lastScan >= IMAGE_RESCAN_SECONDS then
        image.lastScan = now
        ScanCameras(AddImageCamera)
    end
    local writes, live, resets = 0, 0, image.resets
    for address, entry in pairs(image.touched) do
        local object = Alive(entry.kept)
        if not object then
            image.touched[address] = nil
        else
            live = live + 1
            local ok, count = pcall(SyncImage, object, entry, fields, aperture)
            if ok then
                writes = writes + count
            else
                Detail(function()
                    return "Image switches: a camera was not changed: " .. FirstLine(count)
                end)
            end
            if not any and next(entry.saved) == nil and entry.aperture == nil then
                image.touched[address] = nil   -- handed back: forget it
            end
        end
    end
    if not any and next(image.touched) == nil then
        image.lastScan = -math.huge   -- the next switch that goes off looks for the cameras at once
    end
    if writes > 0 then
        Detail(function()
            local reset = image.resets - resets
            return string.format("Image switches: %d camera setting%s written%s.", writes, writes == 1 and "" or "s",
                reset > 0 and string.format(" (%d of them the game had put back)", reset) or "")
        end)
    end
    if any then
        local off = {}
        for _, switch in ipairs(IMAGE_SWITCHES) do
            if Settings[switch.setting] == false then
                off[#off + 1] = switch.setting
            end
        end
        if aperture then
            off[#off + 1] = "DepthOfField"
        end
        Report("image", live > 0 and "on" or "waiting", string.format("%s off on %d camera%s",
            table.concat(off, ", "), live, live == 1 and "" or "s"))
    else
        Report("image", "off")
    end
end

-- The cameras that NotifyOnNewObject noted, once their construction is done.
local function TakeNewCameras(now)
    if #pending == 0 then
        return
    end
    local keep = {}
    for _, item in ipairs(pending) do
        if now - item.time > NEW_CAMERA_SETTLE_SECONDS then
            if ultrawide.on then
                pcall(UnboxCamera, item.object)
            end
            if image.active then
                pcall(AddImageCamera, item.object)
            end
        else
            keep[#keep + 1] = item
        end
    end
    pending = keep
end

---------------------------------------------------------------------------------------------------------------------
-- Ultrawide HUD: a render translation on the HUD's left and right parts
---------------------------------------------------------------------------------------------------------------------

local hud = {
    root = nil,          -- the kept HUD layout
    widgets = nil,       -- { kept, side = -1 | 1, name }
    moved = {},          -- address -> kept: widgets we have moved
    lastFind = -math.huge,
    lastCheck = -math.huge,
}

local function WidgetName(widget)
    local ok, name = pcall(function()
        return widget:GetFName():ToString()
    end)
    if ok and type(name) == "string" then
        return name
    end
    return nil
end

local function HudSide(name)
    if not name then
        return nil
    end
    for _, prefix in ipairs(HUD_LEFT) do
        if name:sub(1, #prefix) == prefix then
            return -1
        end
    end
    for _, prefix in ipairs(HUD_RIGHT) do
        if name:sub(1, #prefix) == prefix then
            return 1
        end
    end
    return nil
end

-- The HUD's left and right parts, by name prefix (the editor's number suffixes can change with a game update): a walk
-- down panels (GetChildrenCount, GetChildAt), content widgets (GetContent) and user widgets (WidgetTree.RootWidget).
-- A matched widget is not walked into.
local function CollectHudWidgets(root)
    local found, visited = {}, 0
    local function Walk(widget, depth)
        if visited >= HUD_MAX_WIDGETS or depth > HUD_MAX_DEPTH or not Valid(widget) then
            return
        end
        visited = visited + 1
        local name = depth > 0 and WidgetName(widget) or nil
        local side = HudSide(name)
        if side then
            local kept = Keep(widget)
            if kept then
                found[#found + 1] = { kept = kept, side = side, name = name }
            end
            return
        end
        local okc, count = pcall(function()
            return widget:GetChildrenCount()
        end)
        if okc and type(count) == "number" then
            for i = 0, count - 1 do
                local okx, child = pcall(function()
                    return widget:GetChildAt(i)
                end)
                if okx and Valid(child) then
                    Walk(child, depth + 1)
                end
            end
            return
        end
        local okn, content = pcall(function()
            return widget:GetContent()
        end)
        if okn and Valid(content) then
            Walk(content, depth + 1)
            return
        end
        local okt, rootWidget = pcall(function()
            return widget.WidgetTree.RootWidget
        end)
        if okt and Valid(rootWidget) then
            Walk(rootWidget, depth + 1)
        end
    end
    Walk(root, 0)
    return found
end

-- Design units each side moves by, for this screen and setting (0 = none).
local function HudOffset(aspect)
    local spread = HUD_SPREAD[Settings.UltrawideHUD]
    if not Settings.Enable or not spread or not aspect or aspect <= 16 / 9 + 0.01 then
        return 0
    end
    return math.floor((1080 * aspect - 1920) / 2 * spread + 0.5)
end

local function Translation(widget)
    local ok, x, y = pcall(function()
        local translation = widget.RenderTransform.Translation
        return translation.X, translation.Y
    end)
    if ok and type(x) == "number" then
        return x, type(y) == "number" and y or 0
    end
    return nil, 0
end

-- Sets the horizontal translation and keeps the vertical one.
local function SetTranslationX(widget, x)
    local _, y = Translation(widget)
    return pcall(function()
        widget:SetRenderTranslation({ X = x, Y = y })
    end)
end

local function RestoreHud()
    for address, kept in pairs(hud.moved) do
        local widget = Alive(kept)
        if widget then
            SetTranslationX(widget, 0)
        end
        hud.moved[address] = nil
    end
end

local function FindHud(now)
    local root = Alive(hud.root)
    if root and hud.widgets then
        return root
    end
    if now - hud.lastFind < HUD_FIND_SECONDS then
        return nil
    end
    hud.lastFind = now
    local ok, found = pcall(FindFirstOf, HUD_CLASS)
    if not ok or not Valid(found) then
        return nil
    end
    local widgets = CollectHudWidgets(found)
    if #widgets == 0 then
        return nil
    end
    hud.root, hud.widgets = Keep(found), widgets
    Detail(function()
        local names = {}
        for i, entry in ipairs(widgets) do
            names[i] = entry.name
        end
        return "Ultrawide HUD: found " .. table.concat(names, ", ") .. "."
    end)
    return found
end

local function TickHud(now, aspect)
    local want = HudOffset(aspect)
    if want == 0 then
        if next(hud.moved) then
            RestoreHud()
        end
        if Settings.Enable and Settings.UltrawideHUD ~= "Off" then
            Report("hud", "not needed", "the screen is " .. AspectText(aspect) .. ", not wider than 16:9")
        else
            Report("hud", "off")
        end
        return
    end
    if now - hud.lastCheck < HUD_CHECK_SECONDS then
        return
    end
    hud.lastCheck = now
    if not FindHud(now) then
        Report("hud", "waiting", "the HUD is not there yet")
        return
    end
    local count = 0
    for _, entry in ipairs(hud.widgets) do
        local widget = Alive(entry.kept)
        if widget then
            local x = entry.side * want
            local current = Translation(widget)
            -- Also when the game animated it: our offset goes back on within HUD_CHECK_SECONDS.
            if current == nil or math.abs(current - x) > 0.5 then
                SetTranslationX(widget, x)
            end
            hud.moved[entry.kept.address] = entry.kept
            count = count + 1
        end
    end
    if count == 0 then
        hud.root, hud.widgets = nil, nil   -- the HUD was built again: look for it again
        Report("hud", "waiting", "the HUD is not there yet")
        return
    end
    Report("hud", "on", string.format("%d HUD parts moved %d to the sides", count, want))
end

---------------------------------------------------------------------------------------------------------------------
-- The panel: PanelKey (F9) opens it over the game. Up/Down choose a row, Left/Right change it (Shift: bigger steps),
-- Home sets the game's value (Home again at once: undo). A change works at once (the loop reads Settings) and goes
-- into config.lua PANEL_SAVE_SECONDS after the last key press, and when the panel closes.
--
-- The widgets are built at each opening and removed at each closing (runtime UMG, as in the source mod: a UserWidget
-- with a WidgetTree, made with StaticConstructObject, in the engine's Roboto font). Only native UMG classes are used,
-- so UE4SS's stale FindProperty cache (UE4SS issue #1496: a property of an unloaded Blueprint class) cannot reach the
-- panel. A map load clears the viewport, so the panel closes when the world changes. The key callbacks run on UE4SS's
-- input thread: they only put the key into a queue, and the loop on the game thread does the work. The keys reach the
-- game too (UE4SS's key binds do not take them away).
---------------------------------------------------------------------------------------------------------------------

-- Colours are linear (UMG). The sRGB colour is in each comment.
local COLORS = {
    text = { R = 0.807, G = 0.745, B = 0.644, A = 1 },      -- #E8E0D2
    dim = { R = 0.270, G = 0.249, B = 0.231, A = 1 },       -- #8E8984
    selected = { R = 0.745, G = 0.063, B = 0.042, A = 1 },  -- #E0473A
    changed = { R = 0.708, G = 0.445, B = 0.147, A = 1 },   -- #DBB26B
    good = { R = 0.319, G = 0.708, B = 0.319, A = 1 },      -- #99DB99
    empty = { R = 0.090, G = 0.083, B = 0.077, A = 1 },     -- #545250
}
local PANEL_BACK = { R = 0.003, G = 0.0025, B = 0.0025, A = 0.90 }
local PANEL_EDGE = { R = 0.341, G = 0.022, B = 0.014, A = 1 }

-- The rows; ASCII only in every text.
local ROWS = {
    { setting = "Enable", label = "All tweaks", kind = "switch", on = "On", off = "Off",
        help = "Off: every tweak off at once, to compare with the game's own look." },
    { setting = "FieldOfView", label = "Field of view", kind = "fov", step = 1, big = 5, part = "fov",
        help = "The normal view's field of view (the game's: 75). Combat and special-move views keep their zoom in "
            .. "proportion; cutscenes keep theirs." },
    { setting = "CameraDistance", label = "Camera distance", kind = "offset", step = 25, big = 100, part = "distance",
        help = "Further back (+) or closer (-) in every view, on top of the game's own distance (350)." },
    { setting = "LockOnHeight", label = "Lock-on height", kind = "offset", step = 10, big = 50, part = "lockon",
        help = "Lower (-) or higher (+), in cm, only while you are locked on. Experimental: the line above names the "
            .. "camera mode." },
    { setting = "UltrawideFix", label = "Ultrawide fix", kind = "choice", part = "ultrawide",
        help = "Cutscenes without black bars on screens wider than 16:9. Auto: only on screens wider than 1.9:1." },
    { setting = "UltrawideHUD", label = "Ultrawide HUD", kind = "choice", part = "hud",
        help = "On wide screens: health bar, quick slots and buffs to the left edge, weapons to the right. Halfway: "
            .. "in between." },
    { setting = "ChromaticAberration", label = "Chromatic aberration", kind = "switch", on = "Game", off = "Off",
        part = "image", gap = true, help = "Colour fringes towards the screen edges." },
    { setting = "Vignette", label = "Vignette", kind = "switch", on = "Game", off = "Off", part = "image",
        help = "Darkened screen edges. Off also turns film grain off." },
    { setting = "DepthOfField", label = "Depth of field", kind = "switch", on = "Game", off = "Off", part = "image",
        help = "Background blur. Off stops every cutscene camera down to its highest f-number." },
    { setting = "LensFlares", label = "Lens flares", kind = "switch", on = "Game", off = "Off", part = "image",
        help = "Flare sprites from bright lights." },
    { setting = "Bloom", label = "Bloom", kind = "switch", on = "Game", off = "Off", part = "image",
        help = "Glow around bright light. Off is crisper but flatter, especially in HDR." },
}

local keyQueue = {}
-- When the panel made a change that is not in config.lua yet (nil: none).
local panelDirtyAt = nil
local panel = {
    visible = false, selected = 1, widgets = nil, world = nil, cache = {}, builds = 0, failLogs = 0, saveLogs = 0,
    undo = nil, saveProblem = nil,
}

-- Runs on UE4SS's input thread (UE4SS v4.0.0 holds its game-thread Lua lock around it): only a Lua table changes
-- here, no game object is touched.
local function QueueKey(action)
    if #keyQueue < PANEL_MAX_KEYS then
        keyQueue[#keyQueue + 1] = action
    end
end

local function Round(value)
    return math.floor(value + 0.5)
end

local function RowRange(row)
    if row.kind == "fov" then
        return FOV_MIN, LIMITS.FieldOfView[2]
    end
    return LIMITS[row.setting][1], LIMITS[row.setting][2]
end

-- The normal view's own field of view: where Right from "Game" starts.
local function GameFov()
    return Round(fov.base or FOV_FALLBACK)
end

-- The next value of a row: dir -1 or 1; big: Shift.
local function StepValue(row, value, dir, big)
    if row.kind == "switch" then
        return not value
    end
    if row.kind == "choice" then
        local choices = CHOICES[row.setting]
        local index = 1
        for i, choice in ipairs(choices) do
            if choice == value then
                index = i
            end
        end
        return choices[(index - 1 + dir) % #choices + 1]
    end
    local low, high = RowRange(row)
    local step = big and row.big or row.step
    if row.kind == "fov" then
        if value == 0 then
            if dir < 0 then
                return 0
            end
            return math.max(low, math.min(high, GameFov()))
        end
        local new = Round(value + dir * step)
        if new < low then
            return 0
        end
        return math.min(high, new)
    end
    return math.max(low, math.min(high, Round(value + dir * step)))
end

local function ValueText(row, value)
    if row.kind == "switch" then
        return value and row.on or row.off
    end
    if row.kind == "choice" then
        return value == "Off" and "Off (game)" or value
    end
    if value == 0 then
        return row.kind == "fov" and ("Game (" .. GameFov() .. ")") or "Game"
    end
    if row.kind == "offset" then
        return string.format("%+d", Round(value))
    end
    return string.format("%d", Round(value))
end

-- A number row's bar: the filled part and the rest, both of "=" (one glyph, so every bar has the same width).
local function BarParts(row, value)
    if row.kind ~= "fov" and row.kind ~= "offset" then
        return "", ""
    end
    local low, high = RowRange(row)
    local share = 0
    if not (row.kind == "fov" and value == 0) then
        share = (value - low) / (high - low)
    end
    local filled = math.max(0, math.min(PANEL_BAR, Round(share * PANEL_BAR)))
    return string.rep("=", filled), string.rep("=", PANEL_BAR - filled)
end

local function StatusText(row)
    if row.setting == "Enable" then
        return Settings.Enable and "Now: the tweaks that are set work." or "Now: every tweak off, the game's own look."
    end
    local state = reported[row.part] or "off"
    return "Now: " .. state .. "."
end

-- A setting's value as config.lua text.
local function FormatValue(value)
    if type(value) == "boolean" then
        return tostring(value)
    end
    if type(value) == "number" then
        if value == math.floor(value) then
            return string.format("%d", value)
        end
        return string.format("%g", value)
    end
    return string.format("%q", value)
end

local function SameValue(a, b)
    if type(a) == "string" and type(b) == "string" then
        return a:lower() == b:lower()
    end
    return a == b
end

-- config.lua's text with the values of `values`: each setting's value on its own line is replaced, its comment stays
-- in its column; a setting the file lacks is added before the closing brace when its value is not the default. nil
-- when there is no closing brace.
local function RewriteConfig(text, values)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    local seen = {}
    for i, line in ipairs(lines) do
        local body, cr = line:match("^(.-)(\r?)$")
        local indent, name, equals, rest = body:match("^(%s*)([%a_][%w_]*)(%s*=%s*)(.*)$")
        if name and DEFAULTS[name] ~= nil and values[name] ~= nil then
            seen[name] = true
            local literal, tail = rest:match("^(.-)(%s*,.*)$")
            if not literal then
                literal, tail = rest:match("^(.-)(%s*%-%-.*)$")
            end
            if not literal then
                literal, tail = rest, ""
            end
            local new = FormatValue(values[name])
            if new ~= literal then
                local comma, spaces, comment = tail:match("^(%s*,)(%s*)(%-%-.*)$")
                if comma then
                    tail = comma .. string.rep(" ", math.max(1, #spaces + #literal - #new)) .. comment
                end
                lines[i] = indent .. name .. equals .. new .. tail .. cr
            end
        end
    end
    local missing = {}
    for _, name in ipairs(SETTING_ORDER) do
        if not seen[name] and not SameValue(values[name], DEFAULTS[name]) then
            missing[#missing + 1] = "    " .. name .. " = " .. FormatValue(values[name]) .. ","
        end
    end
    if #missing > 0 then
        local close = nil
        for i = #lines, 1, -1 do
            if lines[i]:match("^%s*}") then
                close = i
                break
            end
        end
        if not close then
            return nil
        end
        for k, line in ipairs(missing) do
            table.insert(lines, close + k - 1, line)
        end
    end
    return table.concat(lines, "\n")
end

-- True when the text gives every setting the value of `values` (a missing setting counts as its default).
local function ConfigHolds(text, values)
    local chunk = load(text, "=config.lua", "t", {})
    if not chunk then
        return false
    end
    local ok, config = pcall(chunk)
    if not ok or type(config) ~= "table" then
        return false
    end
    for name, default in pairs(DEFAULTS) do
        local value = config[name]
        if value == nil then
            value = default
        end
        if not SameValue(value, values[name]) then
            return false
        end
    end
    return true
end

local function SaveProblem(problem)
    if panel.saveProblem ~= problem then
        panel.saveProblem = problem
        Log("The panel could not save config.lua (" .. problem .. "): its changes last until the game closes.")
    end
end

-- Writes the panel's changes into config.lua; the next read finds its own text and changes nothing.
local function SaveConfig()
    panelDirtyAt = nil
    local changed = {}
    for _, name in ipairs(SETTING_ORDER) do
        if not SameValue(Settings[name], fileSettings[name]) then
            changed[#changed + 1] = name .. " = " .. FormatValue(Settings[name])
        end
    end
    if #changed == 0 then
        return
    end
    if not configPath then
        SaveProblem("there is no config.lua")
        return
    end
    local file = io.open(configPath, "rb")
    local text = file and file:read("a") or nil
    if file then
        file:close()
    end
    if not text then
        SaveProblem("it cannot be read")
        return
    end
    local new = RewriteConfig(text, Settings)
    if not new or not ConfigHolds(new, Settings) then
        SaveProblem("its text is not the shipped form")
        return
    end
    local out = io.open(configPath, "wb")
    if not out then
        SaveProblem("it cannot be written")
        return
    end
    out:write(new)
    out:close()
    configText = new
    for name, value in pairs(Settings) do
        fileSettings[name] = value
    end
    panel.saveProblem = nil
    panel.saveLogs = panel.saveLogs + 1
    if panel.saveLogs <= PANEL_MAX_SAVE_LOGS then
        Log("Panel: saved to config.lua (" .. table.concat(changed, ", ") .. ").")
    end
end

local textLibrary, fontObject = nil, nil

local function Text(value)
    if not Valid(textLibrary) then
        textLibrary = StaticFindObject(TEXT_LIBRARY)
    end
    if Valid(textLibrary) then
        return textLibrary:Conv_StringToText(value)
    end
    return FText(value)
end

local function Font(size, face)
    if not Valid(fontObject) then
        fontObject = StaticFindObject(FONT_PATH)
        if not Valid(fontObject) and type(LoadAsset) == "function" then
            pcall(LoadAsset, FONT_PATH)
            fontObject = StaticFindObject(FONT_PATH)
        end
    end
    local font = { Size = size, TypefaceFontName = FName(face or "Regular"), LetterSpacing = 0,
        OutlineSettings = { OutlineSize = 1, OutlineColor = { R = 0, G = 0, B = 0, A = 0.6 } } }
    if Valid(fontObject) then
        font.FontObject = fontObject
    end
    return font
end

local function Slate(color)
    return { SpecifiedColor = color, ColorUseRule = 0 }
end

-- Builds the panel's widgets and puts them on the screen; the widget table, or nil and the reason.
local function BuildPanel(now)
    local engine = Engine(now)
    local instance = engine and engine.GameInstance or nil
    if not Valid(instance) then
        return nil, "no game instance yet"
    end
    local classes = {}
    for _, name in ipairs({ "UserWidget", "WidgetTree", "CanvasPanel", "Border", "SizeBox", "VerticalBox",
        "HorizontalBox", "TextBlock" }) do
        classes[name] = StaticFindObject("/Script/UMG." .. name)
        if not Valid(classes[name]) then
            return nil, "the UMG class " .. name .. " is not there"
        end
    end
    panel.builds = panel.builds + 1
    local root = StaticConstructObject(classes.UserWidget, instance,
        FName(string.format("CameraAndImageTweaks_Panel_%d_%d", os.time(), panel.builds)))
    local tree = StaticConstructObject(classes.WidgetTree, root)
    root.WidgetTree = tree
    local canvas = StaticConstructObject(classes.CanvasPanel, tree)
    tree.RootWidget = canvas
    local border = StaticConstructObject(classes.Border, tree)
    border:SetBrush({ DrawAs = 4, TintColor = Slate(PANEL_BACK), OutlineSettings = {
        CornerRadii = { X = 2, Y = 2, Z = 2, W = 2 }, Color = Slate(PANEL_EDGE), Width = 1, RoundingType = 0 } })
    border:SetPadding({ Left = 30, Top = 18, Right = 30, Bottom = 18 })
    local canvasSlot = canvas:AddChildToCanvas(border)
    canvasSlot:SetAnchors({ Minimum = { X = 0, Y = 0.5 }, Maximum = { X = 0, Y = 0.5 } })
    canvasSlot:SetAlignment({ X = 0, Y = 0.5 })
    canvasSlot:SetPosition({ X = 80, Y = -10 })
    canvasSlot:SetAutoSize(true)
    local size = StaticConstructObject(classes.SizeBox, tree)
    size:SetWidthOverride(PANEL_WIDTH)
    border:SetContent(size)
    local box = StaticConstructObject(classes.VerticalBox, tree)
    size:SetContent(box)

    local function NewText(size, face, color)
        local block = StaticConstructObject(classes.TextBlock, tree)
        block:SetFont(Font(size, face))
        block:SetColorAndOpacity(Slate(color or COLORS.text))
        return block
    end
    local function Add(widget, top)
        local slot = box:AddChildToVerticalBox(widget)
        slot:SetPadding({ Left = 0, Top = top or 3, Right = 0, Bottom = 0 })
        slot:SetHorizontalAlignment(0)
    end
    local function AddToRow(line, widget, fill)
        local slot = line:AddChildToHorizontalBox(widget)
        slot:SetSize({ SizeRule = fill and 1 or 0, Value = 1.0 })
        slot:SetVerticalAlignment(2)
    end

    local widgets = { root = root, border = border, rows = {} }
    widgets.title = NewText(30, "Bold", COLORS.selected)
    Add(widgets.title, 0)
    widgets.status = NewText(19, "Regular", COLORS.good)
    widgets.status:SetAutoWrapText(true)
    Add(widgets.status, 2)
    for i, row in ipairs(ROWS) do
        local line = StaticConstructObject(classes.HorizontalBox, tree)
        local entry = { label = NewText(25, "Regular"), value = NewText(25, "Bold"), fill = NewText(19, "Bold"),
            rest = NewText(19, "Bold", COLORS.empty), gapAfterValue = NewText(19, "Regular") }
        AddToRow(line, entry.label, true)
        AddToRow(line, entry.value)
        AddToRow(line, entry.gapAfterValue)
        AddToRow(line, entry.fill)
        AddToRow(line, entry.rest)
        Add(line, (i == 1 and 10) or ((i == 2 or row.gap) and 12) or 1)
        widgets.rows[i] = entry
    end
    widgets.help = NewText(20, "Regular", COLORS.dim)
    widgets.help:SetAutoWrapText(true)
    Add(widgets.help, 12)
    widgets.footer = NewText(18, "Regular", COLORS.dim)
    widgets.footer:SetAutoWrapText(true)
    Add(widgets.footer, 8)
    root:AddToViewport(PANEL_Z_ORDER)
    root:SetVisibility(VISIBLE_NO_MOUSE)
    return widgets
end

-- About PANEL_HEIGHT_SHARE of the screen's height, whatever the game's UI scale.
local function FitPanel(widgets, world)
    local ok, err = pcall(function()
        if not Valid(widgetLibrary) then
            widgetLibrary = StaticFindObject(WIDGET_LIBRARY)
        end
        local view = widgetLibrary:GetViewportSize(world)
        local dpi = widgetLibrary:GetViewportScale(world)
        if not (view and type(view.Y) == "number" and view.Y > 0 and type(dpi) == "number" and dpi > 0) then
            return
        end
        widgets.root:ForceLayoutPrepass()
        local desired = widgets.border:GetDesiredSize()
        local height = (desired and type(desired.Y) == "number" and desired.Y > 100) and desired.Y or 760
        local scale = math.max(0.3, math.min(1.5, PANEL_HEIGHT_SHARE * (view.Y / dpi) / height))
        widgets.border:SetRenderTransformPivot({ X = 0, Y = 0.5 })
        widgets.border:SetRenderScale({ X = scale, Y = scale })
    end)
    if not ok then
        Detail(function()
            return "Panel: no fit to the screen (" .. FirstLine(err) .. ")."
        end)
    end
end

-- Sets a text or colour only when it changed, so an open panel costs little.
local function SetText(key, block, value)
    if panel.cache[key] ~= value then
        panel.cache[key] = value
        block:SetText(Text(value))
    end
end

local function SetColor(key, block, color)
    if panel.cache[key] ~= color then
        panel.cache[key] = color
        block:SetColorAndOpacity(Slate(color))
    end
end

local function RefreshPanel()
    local widgets = panel.widgets
    SetText("title", widgets.title, "CAMERA AND IMAGE TWEAKS " .. VERSION)
    for i, row in ipairs(ROWS) do
        local entry = widgets.rows[i]
        local value = Settings[row.setting]
        local selected = i == panel.selected
        local color = COLORS.text
        if selected then
            color = COLORS.selected
        elseif row.setting ~= "Enable" and not Settings.Enable then
            color = COLORS.dim
        elseif not SameValue(value, DEFAULTS[row.setting]) then
            color = COLORS.changed
        end
        SetText("label" .. i, entry.label, (selected and "> " or "   ") .. row.label)
        SetText("value" .. i, entry.value, ValueText(row, value))
        local filled, rest = BarParts(row, value)
        SetText("gap" .. i, entry.gapAfterValue, (filled ~= "" or rest ~= "") and "   " or "")
        SetText("fill" .. i, entry.fill, filled)
        SetText("rest" .. i, entry.rest, rest)
        SetColor("labelColor" .. i, entry.label, color)
        SetColor("valueColor" .. i, entry.value, color)
        SetColor("fillColor" .. i, entry.fill, color)
    end
    local row = ROWS[panel.selected]
    SetText("status", widgets.status, StatusText(row))
    SetText("help", widgets.help, row.help)
    SetText("footer", widgets.footer, "Up/Down: choose    Left/Right: change (Shift: bigger steps)    Home: the "
        .. "game's value (again: undo)\n" .. Settings.PanelKey .. ": close    Changes are saved to config.lua."
        .. (panel.saveProblem and ("\nNot saved: " .. panel.saveProblem .. ".") or ""))
end

-- The loop saves a change in the same tick, once the panel is closed.
local function ClosePanel(reason)
    local widgets = panel.widgets
    panel.visible, panel.widgets, panel.world, panel.cache, panel.undo = false, nil, nil, {}, nil
    if widgets and Valid(widgets.root) then
        pcall(function()
            widgets.root:RemoveFromParent()
        end)
    end
    Detail(function()
        return "Panel: closed (" .. reason .. ")."
    end)
end

local function OpenPanel(now)
    local world = World(now)
    local ok, widgets, why = pcall(BuildPanel, now)
    if not ok or not widgets then
        panel.failLogs = panel.failLogs + 1
        if panel.failLogs <= PANEL_MAX_FAIL_LOGS then
            Log("The panel could not open (" .. FirstLine(ok and why or widgets) .. "); the tweaks in config.lua "
                .. "still work.")
        end
        return
    end
    panel.visible, panel.widgets, panel.world, panel.cache = true, widgets, world and Address(world) or nil, {}
    if world then
        FitPanel(widgets, world)
    end
    RefreshPanel()
    Detail(function()
        return "Panel: open."
    end)
end

local function ChangeRow(dir, big, now)
    local row = ROWS[panel.selected]
    Settings[row.setting] = StepValue(row, Settings[row.setting], dir, big)
    panel.undo = nil
    panelDirtyAt = now
end

-- Home: the game's value; Home again right after (the row still at that value): the value before.
local function ResetRow(now)
    local row = ROWS[panel.selected]
    local default = DEFAULTS[row.setting]
    local undo = panel.undo
    if undo and undo.setting == row.setting and SameValue(Settings[row.setting], default) then
        Settings[row.setting] = undo.value
        panel.undo = nil
    else
        if not SameValue(Settings[row.setting], default) then
            panel.undo = { setting = row.setting, value = Settings[row.setting] }
        end
        Settings[row.setting] = default
    end
    panelDirtyAt = now
end

local function HandleKey(action, now)
    if action == "toggle" then
        if panel.visible then
            ClosePanel("key")
        else
            OpenPanel(now)
        end
        return
    end
    if not panel.visible then
        return
    end
    if action == "up" or action == "down" then
        panel.selected = (panel.selected - 1 + (action == "up" and -1 or 1)) % #ROWS + 1
    elseif action == "home" then
        ResetRow(now)
    else
        ChangeRow((action == "left" or action == "bigleft") and -1 or 1, action == "bigleft" or action == "bigright",
            now)
    end
end

-- Every TICK_MS on the game thread, before the tweaks: the keys, the open panel, the save.
local function PanelTick()
    local now = Now()
    if #keyQueue > 0 then
        local keys = keyQueue
        keyQueue = {}
        for _, action in ipairs(keys) do
            HandleKey(action, now)
        end
    end
    if panel.visible then
        local world = World(now)
        if not Valid(panel.widgets.root) or (world and Address(world) or nil) ~= panel.world then
            ClosePanel("a new world")
        elseif Settings.PanelKey == "Off" then
            ClosePanel("PanelKey = Off")
        else
            RefreshPanel()
        end
    end
    if panelDirtyAt and (not panel.visible or now - panelDirtyAt >= PANEL_SAVE_SECONDS) then
        SaveConfig()
    end
end

-- The keys: every key PanelKey can name (the callback checks the setting, so a new PanelKey works at once), the arrows
-- with and without Shift, and Home.
local function RegisterPanelKeys()
    if type(RegisterKeyBind) ~= "function" or type(Key) ~= "table" then
        Log("This UE4SS has no key binds: the panel is not available; config.lua still works.")
        return
    end
    local wanted, set = 0, 0
    local function Bind(name, shift, callback)
        wanted = wanted + 1
        local key = Key[name]
        if key == nil then
            return
        end
        local ok
        if shift then
            ok = pcall(RegisterKeyBind, key, { shift }, callback)
        else
            ok = pcall(RegisterKeyBind, key, callback)
        end
        if ok then
            set = set + 1
        end
    end
    for _, name in ipairs(PANEL_KEYS) do
        Bind(name, nil, function()
            if Settings.PanelKey == name then
                QueueKey("toggle")
            end
        end)
    end
    local arrows = { { "UP_ARROW", "up" }, { "DOWN_ARROW", "down" }, { "LEFT_ARROW", "left" },
        { "RIGHT_ARROW", "right" }, { "HOME", "home" } }
    for _, pair in ipairs(arrows) do
        Bind(pair[1], nil, function()
            if panel.visible then
                QueueKey(pair[2])
            end
        end)
    end
    local shift = type(ModifierKey) == "table" and ModifierKey.SHIFT or nil
    if shift ~= nil then
        Bind("LEFT_ARROW", shift, function()
            if panel.visible then
                QueueKey("bigleft")
            end
        end)
        Bind("RIGHT_ARROW", shift, function()
            if panel.visible then
                QueueKey("bigright")
            end
        end)
    end
    if set < wanted then
        Log(string.format("Key binds: %d of %d set.", set, wanted))
    end
end

---------------------------------------------------------------------------------------------------------------------
-- The loop
---------------------------------------------------------------------------------------------------------------------

local lastWorld = nil
local quietUntil = -math.huge

-- A new world: the old world's cameras and HUD are gone (nothing to put back on them); the cameras we changed wait in
-- `previous` for KEEP_PREVIOUS_SECONDS, in case the world check only saw a moment without a world. The camera modes
-- are kept by name (CollectModes finds the ones loaded again). The records of the local player and the camera manager
-- (Hold), distance and lock-on keep their state per object: a new object has another address.
local function OnWorldChanged(now)
    camera.pawn, camera.kept = nil, nil
    fov.count, fov.factor, fov.lastCheck = 0, nil, -math.huge
    for _, part in ipairs({ ultrawide, image }) do
        for address, entry in pairs(part.previous) do
            if not NamedAlive(entry) then
                part.previous[address] = nil
            end
        end
        for address, entry in pairs(part.touched) do
            part.previous[address] = entry
        end
        part.touched = {}
    end
    previousUntil = now + KEEP_PREVIOUS_SECONDS
    ultrawide.scanned = false
    image.lastScan = -math.huge
    hud.root, hud.widgets, hud.moved = nil, nil, {}
    hud.lastFind, hud.lastCheck = -math.huge, -math.huge
    pending = {}
    quietUntil = now + SETTLE_SECONDS
    Detail(function()
        return "A new world: the tweaks are applied again in " .. SETTLE_SECONDS .. " s."
    end)
end

-- Whether each tweak is set or still has something of ours to put back.
local function CameraBusy()
    return (Settings.Enable and (Settings.FieldOfView > 0 or Settings.CameraDistance ~= 0
        or Settings.LockOnHeight ~= 0)) or fov.scaled or distance.applied ~= 0 or lock.applied ~= 0
end

local function UltrawideBusy()
    return (Settings.Enable and Settings.UltrawideFix ~= "Off") or ultrawide.on or ultrawide.player ~= nil
        or next(ultrawide.previous) ~= nil
end

local function HudBusy()
    return (Settings.Enable and Settings.UltrawideHUD ~= "Off") or next(hud.moved) ~= nil
end

local function ImageBusy()
    local fields, aperture = ImageWanted()
    return next(fields) ~= nil or aperture or next(image.touched) ~= nil or next(image.previous) ~= nil
end

local function Part(part, work, ...)
    local ok, err = pcall(work, ...)
    if not ok then
        LogError("Error in " .. LABELS[part] .. ": " .. FirstLine(err))
    end
end

local idle = true

local function Tick()
    local cameraBusy, ultrawideBusy, hudBusy, imageBusy = CameraBusy(), UltrawideBusy(), HudBusy(), ImageBusy()
    if not (cameraBusy or ultrawideBusy or hudBusy or imageBusy) then
        -- Nothing set and nothing of ours in the game: no reads at all. The kept objects are dropped, so the next
        -- tweak finds everything again.
        if not idle then
            idle = true
            camera.pawn, camera.kept = nil, nil
            fov.modes, fov.count, fov.factor, fov.lastCheck = {}, 0, nil, -math.huge
            hud.root, hud.widgets = nil, nil
            pending = {}
        end
        image.active = false
        return
    end
    idle = false
    local now = Now()
    local world = World(now)
    local worldAddress = world and Address(world) or nil
    if worldAddress ~= lastWorld then
        lastWorld = worldAddress
        OnWorldChanged(now)
    end
    if now < quietUntil then
        return
    end
    local aspect = (ultrawideBusy or hudBusy) and ViewportAspect(world) or nil
    if cameraBusy then
        local found, component = pcall(PlayerCamera, now)
        if not found then
            LogError("Error while looking for the player's camera: " .. FirstLine(component))
            component = nil
        end
        Part("fov", TickFieldOfView, component, now)
        Part("distance", TickDistance, component, now)
        Part("lockon", TickLockOn, component)
    end
    if ultrawideBusy then
        Part("ultrawide", TickUltrawide, now, aspect)
    end
    if hudBusy then
        Part("hud", TickHud, now, aspect)
    end
    Part("image", TakeNewCameras, now)
    if imageBusy then
        Part("image", TickImage, now)
    else
        image.active = false
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Start
---------------------------------------------------------------------------------------------------------------------

Settings = CopyDefaults()
Log(VERSION .. " loaded.")
local read, problem = pcall(ReadConfig)
if not read then
    LogError("Error while reading config.lua: " .. tostring(problem))
end
if not Settings.Enable then
    Log("Enable = false in config.lua: the mod changes nothing until it is true.")
end

-- New camera components (cutscene cameras are usually made when the cutscene starts). Registered here, in the main
-- chunk: UE4SS refuses it inside a game-thread callback.
local noticed, failure = pcall(NotifyOnNewObject, NEW_CAMERA_CLASS, OnNewCamera)
newCameraNotice = noticed
if not noticed then
    Log("No notice of new cameras (" .. FirstLine(failure) .. "): the mod finds them by a search every "
        .. IMAGE_RESCAN_SECONDS .. " s.")
end

RegisterPanelKeys()

local function TickStep()
    local okPanel, panelError = pcall(PanelTick)
    if not okPanel then
        LogError("Error in the panel: " .. FirstLine(panelError))
        pcall(ClosePanel, "error")
        panel.visible, panel.widgets = false, nil
    end
    local ok, err = pcall(Tick)
    if not ok then
        LogError("Error: " .. FirstLine(err))
    end
end

local function ConfigStep()
    local ok, err = pcall(ReadConfig)
    if not ok then
        LogError("Error while reading config.lua: " .. tostring(err))
    end
end

-- Both loops run on the game thread (UE4SS's Delayed Action API): no Lua on a second thread (Witch Time's crash
-- lesson). A UE4SS without it gets the old LoopAsync loops, and the log says so.
if type(LoopInGameThreadWithDelay) == "function" then
    LoopInGameThreadWithDelay(TICK_MS, TickStep)
    LoopInGameThreadWithDelay(CONFIG_INTERVAL_MS, ConfigStep)
else
    Log("This UE4SS has no game-thread loops (LoopInGameThreadWithDelay): the older LoopAsync is used; a newer UE4SS "
        .. "is safer.")
    LoopAsync(TICK_MS, function()
        ExecuteInGameThread(TickStep)
        -- false keeps the loop running.
        return false
    end)
    LoopAsync(CONFIG_INTERVAL_MS, function()
        ExecuteInGameThread(ConfigStep)
        return false
    end)
end
