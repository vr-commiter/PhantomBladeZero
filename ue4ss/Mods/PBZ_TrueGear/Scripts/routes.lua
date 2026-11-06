local routes={}
local function game(asset,name,kind)
    routes["/Game/PBZContent/Blueprint/ForceFeedbacks/"..asset.."."..asset]={name=name,kind=kind}
end
local function combat(folder,asset,name,kind)
    routes["/PBZCombatAsset/ActorData/Players/Hun/ForceFeedback/"..folder..asset.."."..asset]={name=name,kind=kind}
end
game("FFE_ClimbLadder_LeftHand","LeftHandLadder","interaction")
game("FFE_ClimbLadder_RightHand","RightHandLadder","interaction")
game("FFE_DownSlider_Start","SlideStart","interaction")
game("FFE_DownSlider_Loop","SlideLoop","interaction")
game("FFE_CutRope","CutRope","interaction")
combat("","ForceFeedback_CombatArt_Success","CombatArtSuccess","attack")
combat("BrutalAxe/","ForceFeedback_BrutalAxe_Charge1","HeavyWeaponCharge1","attack")
combat("BrutalAxe/","ForceFeedback_BrutalAxe_Charge2","HeavyWeaponCharge2","attack")
combat("","ForceFeedback_HoldDeflect_Loop","GuardHold","attack")
return routes
