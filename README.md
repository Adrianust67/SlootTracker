# ZoneComplete

A location-aware completion tracker for World of Warcraft Retail.

It answers one question continuously: **"given where I am standing right now,
what unfinished content can I clear with the least travel?"**

Built and tested against client **12.1.0 (Midnight)**, Interface `120100`.

---

## Install

Copy the `ZoneComplete` folder into:

```
C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\
```

Then `/reload` or restart the game. The folder name must stay `ZoneComplete`
so it matches the `.toc`.

---

## What it tracks

| Category | Source | Location accuracy |
|---|---|---|
| Quests in your log | quest log API | exact pin |
| Quests offered but not accepted | map quest pins | exact pin |
| World quests / bonus objectives | task quest API | exact pin |
| Zone story progress | zone story achievement | zone |
| Achievements | built zone index (see below) | zone |
| Unexplored subzones | "Explore *Zone*" achievement criteria | zone |
| Treasures, rares, points of interest | area POIs + live vignettes | exact pin |
| Mounts, toys, battle pets | source text parsing | zone, when the source names one |
| Transmog sets, heirlooms, titles | collection APIs | zone or none |

---

## Using it

- `/zc` — open the window (or the minimap button)
- `/zc scan` — force a rescan
- `/zc auto` — scope per category (the default)
- `/zc char` / `/zc account` — force one scope everywhere
- `/zc alert off|all|high|test` — quest alerts (all quests, or level-appropriate only)
- `/zc reach zone|continent|world` — how far out to look
- `/zc route` — print the planned route to chat
- `/zc config` — settings
- `/zc reset` — wipe derived indexes and rebuild

In the list: **left-click** sets a waypoint, **shift-click** links the item in
chat, **right-click** opens a menu (waypoint, open in the game's own UI, track,
ignore, hide the whole category).

TomTom is used for waypoints when present — it is installed on this machine, so
you get proper crazy-arrow guidance. Without it, the built-in map pin is used.

---

## How prioritisation works

Every candidate gets a score:

```
score = category weight  ×  proximity  ×  progress  ×  urgency  ×  points
```

- **proximity** dominates. Same zone is worth roughly 3× the same continent, and
  within a zone the score falls off with distance out to ~600 yards.
- **progress** rewards things you have already started. An achievement sitting
  at 9/10 criteria outranks an untouched one, and "one criterion left" gets an
  extra push.
- **urgency** boosts quests ready to hand in, rares that are up right now, and
  anything on a timer that is about to expire.
- **points** is what makes the list chase achievement score. It uses *points per
  remaining step*, not raw points — a 10-point achievement one criterion from
  done beats a 25-point one needing forty more kills. The slider in settings
  controls how hard it pulls (0 to ignore points entirely).

The footer shows the total achievement points currently within reach, so you can
see what a zone is actually worth before committing to it.

Turn on **Debug output** in settings to see the four factors broken out in each
row's tooltip, so you can tell exactly why something is ranked where it is.

### The route planner

Anything with real map coordinates in your current zone gets fed into a greedy
nearest-first route, weighted by score, so a valuable stop 200 yards out beats a
throwaway one at 60 yards. The route strip at the top of the window shows the
planned stops; click any one to set a waypoint. It recomputes as you move.

---

## Scope

Scope is **per category**, because the game stores each kind of content
differently and one global switch would have to lie about something.

| Category | Default | Why |
|---|---|---|
| Achievements | **per character** | credit is account-wide, but the game records who earned each one |
| Exploration | **per character** | same — each criterion remembers which character found the area |
| Quests | **account-wide** | see the caveat below |
| Mounts, toys, pets, transmog, heirlooms | **account-wide, always** | there is no per-character notion of owning a mount |

The scope button in the window offers *Per category* (default), or a hard
override to force everything to character or account. Each of the three real
choices can also be flipped individually, in that dropdown or in settings.

**Achievements per character** means: hide what this character earned, show what
it hasn't. There's an extra option — *Show achievements earned by other
characters* — that surfaces achievements your account already has but this
character never personally did.

**Exploration per character** means: show subzones *this* character has never
walked into, even if an alt found them. Those rows are marked, so you know the
account already has the credit.

**Collections** are account-wide regardless. The only per-character question is
whether you could go and get the thing right now, which is a separate setting —
*Hide collectibles this character cannot obtain* — so wrong-faction mounts don't
pollute your route. Turn it off to see everything the account is missing.

**The quest caveat.** There is no API to ask "has my alt done this quest". So the
addon records each character's completed quest ids *as you play that character*,
and account-wide quest tracking folds those records together. A character you
haven't logged into since installing contributes nothing. The window shows how
many characters it has on record and warns when that's only one, so you're never
silently reading character data under an account-wide label. You can review and
prune the roster in settings.

Storing completed quest ids makes your SavedVariables file noticeably larger
(tens of thousands of ids per long-lived character). Turn it off in settings if
you don't want account-wide quest tracking.

---

## Quest alerts

Announces quests you left behind in a zone as you walk into it. The low-level
switch decides what counts, and works exactly like the one in the Quests
section:

- **Include low-level quests: on** — every unaccepted or unfinished quest in the
  zone, including the ones you've outlevelled. Those are the quests that quietly
  stop showing on your map, and they're usually why a zone never gets finished.
  The alert calls out how many of the total are low-level.
- **Include low-level quests: off** — only level-appropriate quests.

Both use the same low-level threshold slider as the main quest filter (default:
more than 10 levels below you).

You can independently include quests you haven't picked up yet, quests already
in your log, or both. Output is any combination of an on-screen banner
(right-drag to move it, click to open the list), a chat line, and a sound.

Alerts are throttled per zone (default 5 minutes), never fire in combat, and
wait a few seconds after a zone change so the quest log has settled. `/zc alert
test` fires one immediately for the zone you're standing in.

---

## Known limitations

These are real, and worth knowing before you rely on the numbers.

**Quests that aren't offered to you don't appear.** The client only knows about
quests it is currently willing to hand you. A quest behind an unmet prerequisite,
or one removed from the game, is invisible to every API available to an addon.
Listing *every quest that has ever existed* in a zone requires shipping a static
quest database — that's what AllTheThings (which you already have) does, and
this addon deliberately doesn't duplicate it. What you get here is every quest
you could walk over and pick up right now, which is the set that actually
matters for clearing a zone.

**Achievement-to-zone mapping is a heuristic.** There is no API for "which
achievements belong to this zone". The index is built by matching achievement
category titles, names and descriptions against real map names. Exploration,
zone metas, dungeon and raid achievements land correctly; a minority of oddly
named ones fall into the unzoned bucket and only show at *Everywhere* reach.
They're never given a wrong location.

**Collectible sources are parsed from display text.** Mounts and pets expose a
source blob (`Drop: Attumen the Huntsman / Zone: Karazhan`) which parses cleanly.
Toys expose nothing but tooltip text, so their zone is inferred by scanning for
zone names. Collectibles with no identifiable zone are hidden by default — turn
off *Only show collectibles we can tie to a location* to see them anyway.

**Unexplored areas have no coordinates.** Blizzard exposes explored map overlays
but nothing for the fog you haven't lifted. These entries know their zone but
can't be routed to a pin.

**The Toy Box filter dance.** Enumerating every toy requires temporarily opening
up the Toy Box's filters, because the only iteration API walks the *filtered*
list. The addon snapshots your filters, harvests the ids, restores them, and
caches the result so it happens once per patch. It skips the whole thing if you
have the Toy Box open at the time.

---

## Performance

All indexing is chunked through a task runner with an 8ms-per-frame budget, so
the first-login index build (achievements, exploration, pet species, toys) runs
in the background without a stutter. Everything expensive is cached in
SavedVariables and keyed to the client build, so it rebuilds automatically after
a patch and never otherwise.

---

## File layout

```
ZoneComplete.toc
Core/Init.lua          namespace, saved variables, event bus, task runner
Core/Location.lua      map index, player position, distance, reach
Core/Roster.lua        per-character records, account aggregation
Core/Sources.lua       collectible source text -> zone
Core/Priority.lua      scan orchestration, scoring, route planning
Modules/Achievements.lua
Modules/Exploration.lua
Modules/Collections.lua
Modules/Quests.lua
Modules/Treasures.lua
Modules/Alerts.lua     quest alerts (banner, chat, sound)
UI/Main.lua            window, filters, route strip, list
UI/Config.lua          settings panel
```

Adding a content type means registering one provider with a `Scan(ctx)` that
returns entries — scoring, filtering, routing and display come for free.
