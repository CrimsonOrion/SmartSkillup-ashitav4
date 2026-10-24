# SmartSkillup (Ashita v4)

An Ashita v4 port of RolandJ's Windower addon [SmartSkillup](https://github.com/RolandJ/SmartSkillup).

## Instructions
1. Put this addon's files in `Ashita/addons/smartskillup/`. The folder must be named `smartskillup` to match `smartskillup.lua`.
2. Type `/addon load smartskillup` in game.
3. Use the in-game window to add or remove skills and modules, then click **ON** to begin your skillup session.
4. To pause your session manually, click **PAUSE**.
5. For more help, click **HELP** or type `/sms help` in game.

## Disclaimer
1. SmartSkillup is a bot, though without the potential to impede other players (_aside from a few edge cases_), nor can it affect the gil economy.
2. Though it is fairly harmless, please do not use SmartSkillup on servers where it is against the rules.

## Why SmartSkillup?
1. **No more building your own spell lists.** It automatically pulls your known spells that your main job can skill up on and that your main or sub job can cast, then weights them by MP cost and cast time.
    - It excludes spells not meant for skillup: warp, raise, tractor, alexander, etc.
    - It excludes resistable and non-self-stacking spells: poison, paralyze, foe requiem, etc.
    - It excludes Blue Magic spells you know but haven't set.
    - Spells with identical weights are cast in rotation (e.g. Barfire > Barblizzard > Baraero…).
2. **Event pauses.** Casting pauses automatically while running, in cutscenes or NPC menus, while zoning, resting, and more.
3. **An in-game UI.** It shows when an event pause is active, can be dragged, hidden, and scaled, and remembers your preferences.
4. **Combat skills.** Enemy-targeted spells use `<t>`, falling back to `<bt>` for multiboxers. SmartSkillup is not a claim bot and isn't situationally aware: summon your own survival trusts and engage as needed.
5. **Multiple skills per session.** You can mix self-targeted and enemy-targeted skills in one session.
6. **Modules** add extra logic:
    - **MP Limit:** only spells at or below the current limit are cast.
    - **Trust Target:** keeps a targetable trust summoned, since their ilvl boosts skillup rate.
    - **SkillUp Food:** uses the best magic skillup food in your inventory, satchel, sack, or case, moving it into your inventory if needed.
    - **Moogle:** summons the Moogle trust for its refresh and skillup rate boost.
    - **Convert:** uses Convert when MP is below 25%.
    - **Refresh:** casts the most potent refresh available to your main or sub job (Refresh I–III, Battery Charge).
    - **Haste:** casts the most potent haste available to your main or sub job (Haste I–II, Erratic Flutter).
    - **Geo-Refresh:** keeps a Geo-Refresh colure on you.
    - **Sublimation:** activates and completes Sublimation automatically.
    - **Composure** (automatic): applied before Refresh/Haste and removed afterwards on RDM 50+.
    - **Radial Arcana** (automatic): used below 60% MP with a luopan out, on GEO 75+ with the merit.

## Differences from the Windower version
- **UI** rebuilt in ImGui with the same controls. Drag it by any empty space; `uiscale`, `uipos`, `uihide`/`uishow`, and `uidefaults` still work.
- **Commands** use `/sms` in place of `//sms`. `/sms debug off` turns off all debug modes.
- **Skill levels** are read from game memory, so no skill-data requests or initialization retries are needed.
- **Windower events** (buff gain/loss, status, job, level, zone, item moves, newly learned spells) are replaced by per-frame and periodic checks of game state.
- **No `cancel` addon dependency:** buffs are cancelled directly with packet 0x0F1.
- **Timing tuned in game:** 3 secs between a spell completing and the next cast, and 3 secs between a summon completing and releasing the avatar.
- **Fixed:** trust summons now target `<me>`; avatars are released with `/pet "Release" <me>`; party targets use `<pN>`; the Erratic Flutter typo; Refresh/Haste spell priority; NPC pauses no longer get stuck after menus that skip the unlock packet (e.g. Moogle job change).

## Not yet verified in game
- BLU set-spell filtering (memory signature borrowed from Ashita's `blusets`)
- Geo-Refresh colure buff id (541)

## Credit
- **RolandJ:** author of the original Windower SmartSkillup, which this port is based on. Most of its source code was written new.
- **SMD111:** anything credited to SMD111 is from https://github.com/smd111/Gearswap-Skillup/blob/master/skillup.lua
- **GEARSWAP:** its updateVitals code for char update packet parsing (Windower version).
- **AUTO GEO:** its is_moving logic for movement tracking.
- **RUBENATOR:** helped the most by answering questions throughout the original development.
- **ARCHON:** helped with various details about the original UI.
- **KAIN:** for not giving RolandJ an Echad ring until the original was released.
- **Ashita addons:** `blusets` (BLU memory layout), `debuff` (buff cancel packet), `lin` libs (action packet layout), and `imrecast`/`wheel`/`xitools` (event-running memory check), all used as references for the port.
