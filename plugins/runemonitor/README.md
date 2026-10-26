# RuneMonitor (v1.0.0)

RuneMonitor is a local, read-only phone companion proof of concept. It publishes
the current client's visible status to the PC relay and uses an in-game QR code
to pair a phone on the same trusted Wi-Fi. It does not send game input or ask
for Jagex credentials.

It is a personal tool, not a Plugin Hub submission. Unmoderated plugins load
only on the developer beta worlds, so it monitors beta-world characters, not
live ones.

## Monitoring features

- Live HP/prayer points, run energy (0–100%), paired characters, and reconnect recovery.
- A fixed portrait RuneX frame uses original locally extracted sprites and
  bitmap number glyphs. HP is shown as current points ÷100, prayer ÷10, and
  run energy as its unscaled percentage. Orb fills use current/max ratios.
  The two left utility orbs are removed; XP and unused tabs are decorative.
  The bag opens a blank 4×7 inventory of recent kill drops; drops of the same
  item stack in one slot with their quantities and values added. Stack sizes
  use the game's font and colours: yellow below 100,000, white K below 10
  million, green M above. Door opens
  character selection, unpairing and dashboard logout; wrench opens settings.
- The two lower orbs show special attack and familiar spell points.
  Special attack reads `SA_ENERGY` divided by ten (raw 1000 is 100%, confirmed
  in game). The summoning orb shows familiar spell (special move) points from
  `LORE_SPELL_POINTS`, as whole points out of 60 (raw 59 matched the game's
  59/60 on 2026-10-25). Summoning points are not shown.
  One raw diagnostic is printed after a valid profile sample. Unavailable
  counters display `--`. No tracking permission or native UI reads are used.
- An always-north-up terrain map and centred own-character marker. Own tile
  coordinates/floor are read from the valid player entity. There are no map
  click handlers or game commands. Stale/non-game data blanks the map and HUD.
  Inside instances, the plugin maps your tile back to the world area the
  instance was copied from (`World.GetRegionSourceForCoordGrid`) and shows
  that terrain. Instances can rotate copied 8×8 pieces, which the API does not
  reveal, so positions there may be a few tiles off. Instances with no known
  source, and areas without terrain, show an unavailable message.
- Observed inactivity from game-window keyboard and focused mouse movement.
  This is an estimate, not the server's AFK/logout deadline. The documented
  API does not expose that deadline. No keys, typed text, or mouse coordinates
  are uploaded; only elapsed inactivity is published.
- Announcement alerts about your own character only: system/broadcast
  messages that name your display name, requiring optional `chatAccess`.
  Broadcasts about other players, and private, general, and clan chat, are
  never sent, since exporting other players' information is prohibited.
- Kill drops: owned ground items (`isOwner=true`) that land within two tiles
  of an NPC's footprint within five seconds of it despawning (familiars
  excluded). Items you dropped earlier and walk past are ignored. Drops come
  with asynchronous estimated
  GE guide prices from the official RuneScape ItemDB. The relay caches prices
  for 15 minutes; unknown prices stay unknown. The configured item value is
  labeled separately and never presented as a GE price.
- A configurable drop-value threshold, announcement/drop toggles, visible
  cross-character alert popups, and opt-in sound while the phone page is open.
- Phone alerts, each with its limit in settings (0 turns one off): low HP and
  low prayer (percent of maximum), no XP gained for a number of seconds (your
  character may have stopped), and a warning before the idle logout (default
  one minute before). Each fires once when crossed and re-arms when the
  reading recovers.
- The idle logout timer is worked out per character: RS3 logs you out after 5
  minutes without keyboard or mouse input, 5 more with a Jagex Account and 5
  more for members, so 15 minutes for most members. The plugin publishes
  `World.IsMembers()`; the game cannot report a Jagex Account, so that is a
  phone setting (on by default). On a free world a member's timer is counted
  as non-member, which warns early rather than late.
- Loot beams and new collection log entries, each with its own toggle. Both
  come from the game's own chat messages about your items; only sender-less
  game messages count, so other players' chat cannot trigger them.
  They show while the dashboard is open, with sound if enabled and vibration
  where the phone supports it; a locked phone or closed page gets nothing.
- Landscape uses an RS3-style layout: vitals bars across the top (lifepoints
  and prayer as full points, adrenaline as a percentage, familiar points), a
  rectangular north-up minimap with compass and run energy, a Metrics panel
  (XP, XP/h and time to the next level per skill, then the value of logged
  drops and GP/h), and the backpack with a bar of buttons for drops,
  characters and settings plus a pouch total. Coins count at face value; other
  drops need a GE price. Portrait keeps the Old School layout. Icons are the
  existing RuneX sprites in RS3-style frames, not extracted RS3 art.
- An XP tracker on the stats tab (the bar-chart icon): XP gained per skill and
  XP/hr since the first reading or **Reset tracker**. XP is sent once the
  character has been in game for ten seconds, so a login cannot count as a gain.

Kill drops are not a complete loot ledger: loot a boss places away from its
body, and chest or autoloot rewards, may not appear. If a despawned NPC's tile
cannot be read, the console says so once and no drops are logged. The plugin suppresses the first ten seconds after
entering a game/profile and deduplicates recent observations. Notifications
while the browser is closed or the phone is locked are not implemented.

API contracts: [events](https://developer.runescape.com/rs/core/events.html),
[chat types](https://developer.runescape.com/rs/game/chat.html),
[mouse](https://developer.runescape.com/rs/core/mouse.html), and an
[official item-price response](https://secure.runescape.com/m=itemdb_rs/api/catalogue/detail.json?item=4151).
Map source: [RuneApps / Skillbert](https://runeapps.org/map_app), whose top-down
RS3 terrain and original static destination icons are used by the dashboard.
Small position changes pan smoothly; teleports, floor/character changes and
stale readings snap or clear immediately. Nearby terrain is cached ahead of
movement, and the system reduced-motion setting is respected.
This is terrain plus a position marker and static destination icons,
not a screenshot of the client's actual minimap or a nearby-player/NPC feed.
The terrain stays RS3 so own-player coordinates refer to the correct world;
the authentic OSRS assets supply the portrait interface graphics. Original
OSRS terrain is not substituted for RS3 geography.
RuneApps is the only active terrain provider. It stores an upper floor's tile
only where that floor differs from the one below, so a missing upper-floor tile
shows the nearest lower floor (for example Prifddinas floor 1 shows floor 0). Its static destination list is
not a complete live map of every bank, staircase or new-area landmark; it does
not claim a character has unlocked teleports or owns the corresponding items.
Havenhythe terrain and matching player position were confirmed by the user.

## Setup

Start the local relay first; see [the relay README](../../relay/README.md).
No key or local settings file is needed: the plugin registers with the relay on
the same PC by itself. The in-game panel is shown by default; a developer can
hide it with `enableUI=false` in an ignored `local_settings.lua`.

In the developer client console (Alt + backtick), on the beta world:

```text
plugins_setpath <full path to this source's plugins folder>
prf
pon runemonitor
plugins_permissions_request runemonitor
plugins_permissions_enable runemonitor httpAccess
plugins_permissions_enable runemonitor chatAccess
```

HTTP is optional in the manifest so the plugin can load; grant it explicitly
with the full commands above. Use `prl runemonitor` after an edit only when
needed. To stop it during recovery, run `poff runemonitor`.
After a reload the grants can drop (the load line shows `HTTP=false`); run all
three permission commands again, starting with `plugins_permissions_request
runemonitor`, which was needed on 2026-10-26. The Plugin Hub's permissions
window could not change them for this developer plugin ("That permission
could not be changed").
Chat access is needed only for announcements, loot beams and collection log
entries; declining it leaves vitals, owned-item observations, and activity
estimates available.

Never grant `trackingAccess`. Enabling it caused a native client crash during
testing, so RuneMonitor deliberately does not use the tracking-ID API.

Open RuneMonitor's ribbon or settings panel and first check that its controls
remain stable. Then select **Link phone**, scan the QR
with the phone camera, and tap **Pair character** in the browser. Scanning a
second running client's QR adds its character to that browser's selector.
The in-game panel and actual phone scan passed the first-character test.

## In-game acceptance checklist

Already confirmed in the real client: loopback HTTP, QR pairing, live HP and
prayer, reconnect after `prl`/`pon`, and own-character map position. These
still need checking in the beta client, with the relay running and the phone
dashboard open:

1. **Requests (v0.7.1):** after `prl runemonitor` and granting HTTP, the console
   prints `PASS: Loopback GET and POST passed.` and the phone resumes. Requests
   now start only from the plugin's Logic tick, never inside another request's
   callback, which other developers saw crash the client.
2. **Familiar spell points on the phone:** the scale is confirmed (raw 59 =
   59/60), as is special attack (`SA_ENERGY=1000 -> 100`). With a familiar
   summoned, use a special move and check the phone's summoning orb drops by
   the same amount and refills as the points regenerate.
3. **HP and prayer changes:** take damage, heal, and drain and restore prayer.
   Confirm the phone follows within a few seconds.
4. **Inactivity:** stop using the keyboard and mouse for a minute, then resume.
   Confirm the phone's inactivity estimate rises and resets.
5. **Kill drops:** kill something that drops an item. Confirm it appears in
   the phone's bag with a GE guide price, and that a second drop of the same
   item adds to that slot. Then drop an item yourself, walk away and back past
   it, and confirm it does not appear.
   Confirmed 2026-10-26 with `!hitall` in an instance (after the fix below).
   Turn `!godmode` off first: with it on, the plugin never sees the monsters
   die, so their loot waits for a kill that never comes. The console prints
   why each of the first 15 ground items was or was not logged.
6. **Instances:** enter an instance (for example a boss instance) and confirm
   the phone shows terrain with your marker where you stand. Instances can sit
   past the 12,799-tile world map (one tested at x 13,589); v0.7.6 converts
   them to world tiles and prints `Map position: …` in the console when it
   cannot.
7. **Announcements:** with `chatAccess` granted, a broadcast that names your
   character (for example a rare drop or level milestone) should appear on the
   phone, and broadcasts about other players should not.
8. **XP:** the console prints `XP check: Constitution level <L>, XP <N>` once.
   Confirmed 2026-10-26: whole XP points (a 200M Constitution read
   `XP 200000000`, not tenths), so no conversion is needed. Train for a few
   minutes and confirm the stats tab shows gains and a sensible XP/hr.
9. **Phone alerts:** with the dashboard open, drop below the HP and prayer
   limits, stop training, and stop touching the keyboard and mouse; confirm
   each alert appears once. Settings should show the idle time "of 15:00" on a
   members world (with Jagex Account ticked), and the logout warning should
   arrive at about 14:00 without input.
10. **Landscape:** turn the phone sideways and confirm the vitals bars, map,
    Metrics and backpack fit without scrolling, and that ETAs look sensible
    (they assume XP is whole points; see the XP step).
11. **Two characters:** when a second client is available, pair both and
   confirm switching keeps their readings separate.
12. **Loot beam:** get a drop above your in-game loot beam value. The phone
    should show "Loot beam" with the game's "You receive: ..." line.
    Confirmed 2026-10-26, including a cosmetic beam ("A flower blooms over one
    of your items").
13. **Collection log:** unlock a new collection log item. The phone should show
    "Collection log" with the game's own message. The RS3 wording is not
    documented, so if nothing arrives, note the exact chat line so the match
    can be fixed. Confirmed working 2026-10-26 (reward caskets spawned with
    `!give trail17_reward_casket_master`); the console prints each collection
    message it sees.

## Observed acceptance and limits

Loopback HTTP passed in the official developer client (`rs2client 951-1`, world
205): both `/health` and `/api/probe` returned their expected responses. No
firewall rules were changed; only approve a private-network prompt if you intend
to use a phone on that network.

Identity is a local `name:<display name>` profile key, not a verified Jagex
identifier. The plugin saves a separate publishing credential for each profile
on this PC. World hops, lobby/logout transitions, and plugin reloads retain
that credential and resume the existing phone link when the same name returns.
Unavailable states clear readings without exposing another character's points.

A renamed/new character needs a fresh pairing. Losing local credentials causes
fresh registration, which invalidates the old phone grant. A rejected or revoked
publishing credential stops automatic retries until **Link phone** explicitly
starts pairing again. This local-name fallback cannot verify ownership of a
recycled display name; keep the local plugin data private and revoke obsolete
profiles when changing who uses this PC.

Headless telemetry has received raw HP `10949/10395` and raw prayer `8350`.
The user confirmed raw prayer `8350` corresponds to the visible `835/990` bar.
The sampler divides this fixed-point counter by ten and floors it for display.
Normal prayer maximum uses capped base level × 10. Damage/healing, prayer
drain/restoration, and boosts still need comparison, so readings remain
experimental.

The plugin-owned PrettyUI panel opened and remained stable in the real client.
The beta client sent empty-body pairing POST requests as GET; v0.3.2 supplies a
nonempty form body for pairing and revocation. On 2026-10-25, the user scanned
the actual in-game QR, paired the phone, and confirmed the character and live
readings appeared. Subsequent relay snapshots showed HP `10949/10395`, prayer
`766/990`, and observation ages below one second. This measures relay freshness,
not end-to-end phone latency.

The user subsequently confirmed the phone updates as the game readings change,
with a few seconds' delay. Uploads run about once per second and the phone polls
every two seconds. This is a qualitative latency observation; the four-second
target has not been measured, and damage/healing and restoration accuracy have
not been separately confirmed.

The v0.4.0 reconnect changes pass simulated reload, world-hop, lobby, and relogin
tests. Refresh the phone dashboard once and reload the plugin to apply both
changes. Developer HTTP permission may need granting again after a plugin reload.

Real relog result on 2026-10-25: the user's `plist` screenshot showed
`runemonitor` still present but without `[ENABLED]`, while PrettyUI remained
enabled. `prl runemonitor` restored it, and the user confirmed the existing
phone pairing resumed live readings without another QR scan. Saved-link
continuity is therefore confirmed after a manual reload. In a follow-up control
test, the user enabled Hello World (which only prints once), Performance Overlay,
and RuneMonitor before relogging. They reported that all local plugins became
disabled after relogging, while installed PrettyUI (`6398181`) remained enabled.
This isolates an activation reset affecting local plugins in this developer
client rather than a RuneMonitor-specific reconnect failure. Automatic local
plugin activation remains a developer-client limitation; a disabled plugin
cannot execute its reconnect logic or re-enable itself.
Use `pon runemonitor` to enable a listed, disabled plugin; grant HTTP if its
status requests it. The existing phone pairing should resume without rescanning.

Only one real character was available for acceptance. Two-character pairing,
switching, and isolation are implemented and tested with simulated characters;
verification with two simultaneous real clients is deferred until a second is
available. Exact AFK/logout countdowns, locked-phone notifications, native
mobile apps, and public release remain outside this local version.

Automated checks: relay/dashboard/map tests and five Lua test files pass. Browser tests
with explicitly simulated characters covered claiming two characters, switching
views, and disconnected readings. These simulations do not prove two real game
clients or the four-second phone update target. The physical scan result above
comes from the user's real-client test.

The v0.5.0 browser fixture additionally verifies threshold filtering, settings
persistence, two-character roster switching, and a new alert from Main while
Alt is selected. All those fixture characters/events are explicitly simulated.
The official guide-price endpoint was also queried successfully from the PC.
Historical v0.6 orientation checks (superseded by the portrait-only v0.7 frame) ran the actual dashboard at 390×844 portrait
and 844×390 landscape. It confirms current-only scaled values and percentage
orbs in portrait, full RS3 pairs in landscape, and rotation of the same frame
without reloading or resetting its selected character. Fixture readings are
explicitly simulated.
Real-client acceptance of the new keyboard/mouse, announcement, and owned-item
callbacks remains pending; it is separate from the earlier successful vitals
and QR tests. Alert history is memory-only and clears when the relay restarts.
The v0.6.0 map preview fetched real RS3 terrain and used explicitly simulated
coordinates/readings to verify the former supplied frame, top-of-phone layout,
percentage orbs, energy, and north-up movement. Actual in-game location and
energy counters still require the next developer-client acceptance test.
During the subsequent Havenhythe check, real telemetry included fresh own-player
coordinates `(3486,1511,0)` and run energy `100`. The primary Wiki tile source
returned 404 for all four local tiles. The fallback was browser-verified with
real RuneApps images at those coordinates and explicitly simulated character
readings. Exact terrain alignment against the game and energy drain still need
user comparison. Readout styling now uses larger uncompressed digits on a
neutral backing instead of the previous small bold text on green blocks.
