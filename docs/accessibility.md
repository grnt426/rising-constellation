# Accessibility

Status: **2026-10-02**. Covers the game client and the website. §1 is what a
keyboard or screen-reader player can do today; §2 is the toolkit and the
rules new UI should follow; §3 is the road from here to a game a blind player
can finish; §4 is the website.

## 1. What works today (game)

A screen-reader player can, without the galaxy map:

- **Walk their empire.** The bottom-left systems/dominions list and the
  bottom-right agents list are labelled regions. Every card is a focusable
  button whose name says what its icons show (queued orders, fleet size,
  exposed Erased, siege, foreign agents present). Toolbars have named
  toggle buttons (filters, sorts, grouping, search); the resize grip is a
  splitter driven by the arrow keys.
- **Hear an agent.** Opening an agent (from a list, a hotkey group, or
  another faction's agent card) moves focus to a one-paragraph summary:
  identity, status, XP, protection, determination, salary, skills (the
  specialization marked), origin, and one sentence saying a fleet exists if
  it does. The fleet is a separate region (*Fleet of …*) holding a
  ship-by-ship list; it is read only when the player moves into it.
- **Give orders.** `G` (or the ☰ button in the agent panel) opens the
  **agent orders list**: every reachable system ranked by travel time from
  the end of the agent's plan, filterable by name/owner/sector, owner
  relation, available order and sector, with one button per order. Orders
  go through the same path as the map (`map:addAction`), are announced when
  sent, and the list re-ranks from the new plan end. Orders that target
  another agent (fight, removal, sabotage, seduction, armadas) live in the
  system briefing below.
- **Run a system.** The **system briefing** (§1.1) is the system view for
  the keyboard and screen readers.
- **Survey the galaxy.** The Galactic Survey is a real data table: caption,
  row and column headers, `aria-sort`, spoken text for every icon and `?`,
  labelled filters, a live result count, and an Agents column (who stands
  where, by faction, under the usual intel rules).
- **Hear what happens.** Every toast is spoken (errors assertively).
- **Use the side panels.** Their tab buttons have names and pressed states.
- **Choose how shortcuts work** (Help → Keyboard shortcuts, §1.2).

### 1.1 The system briefing

`SystemBriefing.vue`, wording in `game/a11y/system-brief.js` (plain-node
tests in `game/a11y/__tests__`). First in the system view's DOM, a labelled
region, visually hidden until keyboard focus enters it; then it shows as a
panel over the left of the system view. Mouse play never sees it.

**Design: a short lead, then pull.** Screen-reader users don't expect a
screen's full contents read out when it opens; they expect its name, what
needs attention now, and a structure to pull the rest from (headings,
lists, expandable sections). So when a system is opened from the keyboard
or a screen reader's activate command (`lastInputWasKeyboard()`; a mouse
open leaves focus alone), focus lands on one paragraph:

1. the system and its owner (*Khesia, your system*);
2. critical alerts: a siege (conquest, pillage, bombardment) with the agent
   and time left, a Siderian taking control of your dominion, an exposed
   Erased (yours, or an enemy's: another faction's Erased only reaches the
   client once its cover is blown);
3. who is here (*4 enemy agents, 3 of yours*);
4. for your own systems, what needs doing: empty construction queue,
   damaged buildings, a workforce shortage (with the output penalty),
   unrest.

A critical alert that appears while the system is open is announced
immediately. Below the lead, four collapsible sections (open/closed state is
remembered while the page lives), each with a one-line summary that is
always present:

- **Agents**: enemies, yours, factionmates. Your own agents carry status,
  queued orders, fleet size, exposure, resting Siderian. A Select / Open
  card button per agent (an agent's card then reads as in §1; the fleet
  reader is there). With one of your agents selected: the orders it can
  give on the system and on each agent present, unavailable ones with
  their reasons.
- **Overview**: governor, then (enemy) defense, intelligence,
  cybersecurity, income, or (yours) income, stability, workforce. Expanded:
  every stat the player can see, each with its breakdown on demand.
- **Construction queue** (your systems): each item with its finish time;
  move up / move down (the keyboard path for drag reordering, with the
  progress-reset warning) and cancel.
- **Buildings**: planets, then moons and asteroids; per body the slots
  built and open, potentials and population. Expanded: each slot, with
  Details (effects at its level, workforce, what it adds to the system),
  Upgrade (with cost), Repair, Destroy (two presses), or Build here (the
  buildable list with cost, workforce and effects; locked slots say why).

`B` jumps back to the briefing from anywhere while a system is open (for
example after opening an agent's card from it).

### 1.2 Keyboard shortcuts

A page can't tell that a screen reader is running (browsers don't expose
it, on purpose), so the choices are explicit, in Help → Keyboard shortcuts,
saved on the account:

- **Game keyboard shortcuts on / off.** Off leaves only Esc (not a
  character key, and the keyboard's only way to close what is open).
- **Shortcut set.** *Standard* is single keys. *Screen reader* is Alt +
  Shift + a letter: NVDA, JAWS and Narrator keep single letters for their
  own navigation in browse mode, so single keys only reach the game in
  focus mode, while Alt + Shift combinations get through either way.
  Camera and map-drawing actions and the agent groups have no key in that
  set (any action can be given one); letters avoid Chrome's own Alt + Shift
  A, I and T. Each set keeps its own changes (`hotkeys`,
  `hotkeys_screen_reader` in Account.settings).
- **Tab, Enter and the arrows can't be shortcuts**, with or without
  modifiers: the game's hotkey library cancels a bound key before any
  control sees it, so binding one broke keyboard navigation everywhere.
  Bindings saved before this rule fall back to the default.
- **The editor works without a mouse.** A row waiting for its key is a
  text field (screen readers switch to focus mode on one, so the key
  reaches the page); Tab moves on to Default / Remove / Cancel; every
  change and refusal is announced; each binding button names its action.

## 2. Toolkit and rules for new UI

### Building blocks

| What | Where | Use |
| --- | --- | --- |
| `.sr-only` | `styles/shared/a11y.scss` | Text for screen readers only. |
| `.bare-button` | same | A `<button>` with no browser chrome, so it can replace a clickable `<div>` without a visual change. |
| `:focus-visible` ring | same | Global keyboard focus ring; mouse focus stays ring-free. |
| `this.$announce(text, { assertive })` | `plugins/a11y.js` | Speak a state change. Polite by default. |
| `v-press` / `v-press="{ disabled: true }"` | same | Makes an existing clickable `<div>`/`<span>`/`<svgicon>` a keyboard button. Prefer a real `<button class="bare-button">` in new markup. |
| `game/a11y/describe.js` | | Spoken descriptions of agents and fleets. Add new describers here so every surface words things the same way. |
| `a11y.*` strings | `locales/*/game.json` | en + fr; de falls back to en. |

### Rules

1. **A tooltip is not a name.** `v-tooltip` text never reaches a screen
   reader. Every icon-only control gets an `aria-label`; decorative icons get
   `aria-hidden="true"`.
2. **Clickable means focusable.** If it has `@click`, it is a `<button>` or
   carries `v-press`. Row clicks are fine as a mouse shortcut as long as the
   row also contains a real button for the same action.
3. **Summarize, then hide the drawing.** Visual widgets built from icons,
   pips and bars (cards, fleet grids) get one spoken summary, and their
   drawing gets `aria-hidden`. Never hide something focusable.
4. **Move focus only when the player opened something**, and give it back on
   close. Announce everything else.
5. **The hotkey library eats keys.** `vue-shortkey` listens on `document` in
   the capture phase and cancels every mapped key unless focus is in an
   `input`, `textarea`, `select` or the chat composer. Consequences:
   - Space is mapped (center on agent). `plugins/a11y.js` hands Space back to
     a button that has *keyboard* focus from a window-capture listener; a
     button the mouse just clicked keeps focus too, and Space still centers
     the map for that player. `hasKeyboardFocus()` tells the two apart by
     where focus came from (`:focus-visible` can't: Chrome sets it on the
     focused element at the first key press). Don't map Enter.
   - Esc is mapped. An overlay's own `@keydown.esc` only fires while focus
     is in one of its inputs; overlays must also close from the `escape`
     branch of `Game.vue`'s `onShortkey`, topmost first.
   - Home is mapped (first system); don't use it inside widgets.
6. **Tables are tables.** `<caption>`, `scope="col"`, a row header
   (`<th scope="row">`), `aria-sort` on the active sort column only.

## 3. Road to blind play

Ordered by how much of a game a blind player can't do without it.

1. **What the system briefing doesn't cover yet**: building ships for a
   Navarch (its fleet's empty slots open the visual production palette),
   the faction station box, turning a system into a dominion and back or
   abandoning it, and the map markers. The briefing doesn't hide the visual
   view, so all of these stay reachable for keyboard users, just not
   readable.
2. **Feedback from blind players** on the briefing's order and wording:
   the lead is deliberately short; whether it should also name the
   besieging agent's owner, or read income, is theirs to say.
3. **Agent plans.** The plan editor (`AgentPlan.vue`) needs a list form:
   stops in order, remove / move buttons, ETA as text.
4. **Events as speech.** New events (attacks on your systems, finished
   constructions, agents arriving or caught) announced politely, with a
   verbosity setting; the event panel as a list.
5. **Shortcut feedback.** The screen-reader set's letters are untested
   with real NVDA / JAWS installs; a blind tester should confirm none
   collide with their reader or browser.
6. **Hover-only information.** Resource breakdowns, building cards, ship
   cards and patent/lex trees live in hover popovers. Each needs a focus
   trigger or a text equivalent.
7. **Market, patents, lexes, doctrines.** Card grids: same treatment as the
   agent card (summary + buttons).
8. **Fight reports** as tables; **chat** as a `role="log"` region, opt-in
   live.
9. **Reduced motion.** GSAP panel slides and camera tweens ignore
   `prefers-reduced-motion`.
10. **Testing.** axe-core checks in the Playwright e2e suite; a manual NVDA +
    Firefox pass per release on the flows in §1.

## 4. Website

An audit of the public Phoenix pages and the Vue portal (WCAG 2.2 AA) found
keyboard dead ends (lobby faction pick, Exit/logout, profiles, fight
simulator), no visible keyboard focus anywhere in the SPA, silent form
errors, one page title for every page, no landmarks, and many unnamed icon
buttons and form fields. All of that is fixed; see the two `feat(a11y)`
website commits for the detail. The building blocks in §2 apply there too;
the Phoenix pages have their own copies (`.sr-only`, `.bare-button`, the
focus ring) in `assets/css/_generic.scss` and an `announce()` in
`assets/js/app.js`. Portal strings live under `a11y_portal` (en messages are
merged shallowly with `game.json`, which owns `a11y`).

Still open:

- **Custom scrollbars** (`<v-scrollbar>`, 59 places, portal and game):
  perfect-scrollbar forces `overflow: hidden` and only scrolls from the
  keyboard while hovered, so text-only panels can't be scrolled by keyboard.
  A fix touches every scroller; it needs its own pass.
- **Reflow at 200% zoom**: fixed-width landing/about/patch-notes sections
  (800/600/720 px) and fixed-height card rows clip.
- **Archive charts** are unlabelled SVG; their values are hover-only.
- Heading order (several h1s on About / Patch notes; pages without an h1),
  the remaining label tooltips in the Map/Scenario editors, landing skill
  meters, layout tables without headers, "I accept the terms" as a link
  rather than a checkbox (changes the signup flow, so left alone).
- The global right-click block (`main.js`) and text-selection block
  (`selection.scss`) get in the way of some assistive tools.
