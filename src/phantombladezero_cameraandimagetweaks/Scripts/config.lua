-- Settings of Camera and Image Tweaks. Change a value and save the file: the mod reads it again every 5 seconds, so the
-- change shows in the game without a restart. A file it cannot read (for example while it is saved) keeps the last
-- settings. A setting that this file does not have keeps its default, so an older copy of the file still works after
-- an update. Every default below leaves the game as it is.
return {
    Enable = true,               -- false: every tweak off, the game's own look (to compare)

    -- Camera
    FieldOfView = 0,             -- 0 = the game's own (75 in the normal view), else 50 to 130; combat, lock-on and
                                 -- special-move views keep their zoom in proportion; cutscenes keep their framing
    CameraDistance = 0,          -- added to the camera distance in every view: -150 (closer) to 500 (further back);
                                 -- the normal distance is 350
    LockOnHeight = 0,            -- only while locked on: -150 (lower) to 100 (higher), in cm; experimental

    -- Wide screens (wider than 16:9)
    UltrawideFix = "Off",        -- "Off", "On", or "Auto" (on for screens wider than 1.9:1): cutscene cameras no
                                 -- longer box the picture with black bars
    UltrawideHUD = "Off",        -- "Off", "Edges" or "Halfway": the health bar, quick slots and buffs move out to the
                                 -- left, the weapons to the right; tips, boss bar, subtitles and menus stay centred

    -- Image effects: true = as in the game, false = off
    ChromaticAberration = true,  -- colour fringes towards the screen edges
    Vignette = true,             -- darkened screen edges; false also turns film grain off
    DepthOfField = true,         -- background blur; false stops every cutscene camera down to its highest f-number
    LensFlares = true,           -- flare sprites from bright lights
    Bloom = true,                -- glow around bright light; false is crisper but flatter, especially in HDR

    -- The in-game panel: this key opens it over the game. Up/Down choose a row, Left/Right change it (Shift: bigger
    -- steps), Home sets the game's value (again: undo). Every change works at once and is saved into this file.
    PanelKey = "F9",             -- "F1" to "F12" (not "F10", UE4SS's console key), or "Off"

    LogDetail = false,           -- true: ue4ss\UE4SS.log names more of what the mod does (for tests)
}
