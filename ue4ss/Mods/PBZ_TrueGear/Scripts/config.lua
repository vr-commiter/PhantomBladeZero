return {

    Version = "1.0.0",

    AppId = "4115450", -- Local Steam appmanifest_4115450.acf, build 26266538.

    GameName = "Phantom Blade Zero",

    Enabled = true,

    Debug = false, -- Enable per-event diagnostics and successful SDK submissions.

    PollMs = 50,

    QueueLimit = 128,

    -- Named playback requires these resources in the TrueGear client app.

    Events = {

        PlayerDamage = true, PlayerHeal = true, PlayerDeath = true,

        MeleeAttack = true, MeleeHit = true, Parry = true, PerfectParry = true,

        LeftHandLadder = true, RightHandLadder = true,

        SlideStart = true, CutRope = true,

        PlayerJump = true, PlayerLand = true, HardLanding = false,

        PlayerCrouch = true, WallClimbStart = true, ItemCollected = true,

        ShieldHit = true, ShieldBreak = true, LowHealthWarning = true,

        WeaponSwitch = true, WeaponDraw = false, WeaponSheathe = false,

        -- User preference: no extra execution intro or execution strength boost.
        -- Original game rumble still follows the generic 8..28 envelope.
        ProjectileLaunch = true, ExecutionStart = false,

        CombatArtSuccess = true, HeavyWeaponCharge1 = true, HeavyWeaponCharge2 = true,

        GuardHold = true, SlideLoop = true,

        UltimateChargeGained = false, UltimateChargeSpent = true, AwakeningReady = true,

        ShachiLow = true, ShachiDepleted = true,

        IgniteBuildup = true, PoisonBuildup = true, FrostBuildup = true,

        ThunderBuildup = true, BleedBuildup = true,

        ControllerRumble = true,

    },

    Attributes = {

        LowHealthRatio = 0.25, LowResourceRatio = 0.20,

        -- Drop height is unverified; all landings use PlayerLand.

        BuildupEvents = {ignite="IgniteBuildup",poison="PoisonBuildup",frost="FrostBuildup",thunder="ThunderBuildup",bleed="BleedBuildup"},

    },

    Healing = {QuietGapSeconds = 1.0}, -- One cue per continuous healing series.

    Combat = {PreferContactNotifications = true, PreferImpactNotifications = true},

    Damage = {

        LowDamageRatio = 0.05, HighDamageRatio = 0.15,

        -- Scale the complete direct-hit pattern by actual HP loss, not fixed low/high levels.
        MinimumIntensity = 70, ShakePeak = 100, ElectricalPeak = 100,
        ElectricalOnce = "False", ElectricalInterval = 10,
        PeriodicIntensity = 50, PeriodicElectricalInterval = 1,

        -- Exact game cause tags; user includes Bleed in the periodic feedback policy.

        DotCauses = {["Damage.Cause.StatusInfliction.Ignite"]=true,["Damage.Cause.StatusInfliction.Poison"]=true,["Damage.Cause.StatusInfliction.Bleed"]=true,
            ["TrueGear.Policy.UnclassifiedGameplayEffect"]=true},

        -- User-authorized feedback policy for the exact source class observed in the log.
        -- This internal key is not a game-provided Bleed tag.
        UnclassifiedEffectPolicies = {
            ["/Script/SGameCombatSystem.DamageSource_GameplayEffect"] = "TrueGear.Policy.UnclassifiedGameplayEffect",
        },

        -- Exact class of this damage source or its owning GE, never the pawn's active status.
        EffectCauses = {
            ["/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_BleedSmall.GE_BleedSmall_C"] = "Damage.Cause.StatusInfliction.Bleed",
            ["/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_BleedBurst.GE_BleedBurst_C"] = "Damage.Cause.StatusInfliction.Bleed",
            ["/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_Ignite_Dot.GE_Ignite_Dot_C"] = "Damage.Cause.StatusInfliction.Ignite",
            ["/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_Poison_Dot_Phase1.GE_Poison_Dot_Phase1_C"] = "Damage.Cause.StatusInfliction.Poison",
            ["/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_Poison_Dot_Phase2.GE_Poison_Dot_Phase2_C"] = "Damage.Cause.StatusInfliction.Poison",
            ["/PBZCombatAsset/Prototypes/GameplayEffects/Inflictions/GE_Poison_Dot_Phase3.GE_Poison_Dot_Phase3_C"] = "Damage.Cause.StatusInfliction.Poison",
        },

    },

    Inventory = {SampleMs = 250, LegacyGrantFallback = false},

    Rumble = {

        Enabled = true,

        -- Mirror every positive amplitude; zero still means stop, never the band minimum.
        SliceMs = 100, ContinuationMs = 200, Deadzone = 0, MediumRangeAt = 0.25, FullRangeAt = 0.65,

        MirrorWhilePaused = false, MaxStreams = 32,

        -- A numeric-only UE request has no action label. Set false to exclude that unknown route.

        MirrorUnknownDynamic = true,

        -- Exact exclusions: weapon take-out and the weak door-interaction cue.
        ExcludedAssets = {
            ["/PBZCombatAsset/ActorData/Players/Hun/ForceFeedback/BrutalAxe/ForceFeedback_BrutalAxe_TakeOut.ForceFeedback_BrutalAxe_TakeOut"]=true,
            ["/Game/PBZContent/Blueprint/ForceFeedbacks/FFB_DoubleDoor_Weak.FFB_DoubleDoor_Weak"]=true,
        },

        -- Mirror game requests for the vest even when controller motors are disabled.

        MirrorWhenGameFeedbackDisabled = true,

        -- User tuning: generic controller mirror at 40% of the former 20..70 envelope.
        Bands = {generic={8,28},interaction={20,40},attack={50,70}},

    },

}

