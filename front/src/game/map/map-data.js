import stableStringify from 'json-stable-stringify';
import store from '@/store';

async function hashObject(obj) {
  const data = new TextEncoder().encode(stableStringify(obj));
  const hashBuffer = await window.crypto.subtle.digest('SHA-1', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  const hashHex = hashArray.map((b) => b.toString(16).padStart(2, '0')).join('');
  return hashHex;
}

export default class MapData {
  constructor() {
    this.systems = [];
    // O(1) lookup by system id. Rebuilt alongside `this.systems` in
    // createSystem/updateSystems. Hot path: Character._update walks the
    // player's character action queues every 80ms and used to do an
    // Array.find per source/target — O(systems × characters × queue)
    // per tick. Use this Map instead.
    this.systemsById = new Map();
    this.systemsToRepaint = new Set([]);

    this.blackholes = [];

    this.sectors = [];
    this.sectorHash = '';
    this.hasToRepaintSectors = false;

    this.radars = [];
    this.radarsHash = '';
    this.hasToRepaintRadars = false;

    this.detectedObjects = [];
    this.hasToRepaintDetectedObjects = false;

    // Id of the system the cursor is currently hovering on the galaxy map.
    // Updated by map.js showHover/hideHover. Read by keyboard handlers
    // (e.g. the C-key copy action) on demand — not reactive.
    this.hoveredSystemId = null;
  }

  update(data) {
    if (data.global_galaxy) {
      this.createSystem(data.global_galaxy.stellar_systems);
      this.updateSectors(data.global_galaxy.sectors);
      this.blackholes = data.global_galaxy.blackholes;
    }

    if (data.global_galaxy_system) {
      this.updateSystems([data.global_galaxy_system], {});
    }

    if (data.faction_faction) {
      this.updateSystems([], data.faction_faction.contacts);
      this.updateRadars(data.faction_faction.radars);
      // Join reply also embeds the initial radar blips here; without
      // this, the map shows zero detected blips until the first
      // post-join tick (~5s of black radar on every reconnect).
      if (data.faction_faction.detected_objects) {
        this.updateDetectedObjects(data.faction_faction.detected_objects);
      }
    }

    if (data.detected_objects) {
      this.updateDetectedObjects(data.detected_objects);
    }

    if (data.faction_faction_contact) {
      const formatedContact = {
        [data.faction_faction_contact.system_id]: data.faction_faction_contact.contact,
      };

      this.updateSystems([], formatedContact);
    }

    if (data.global_galaxy_sector) {
      this.updateSectors(data.global_galaxy_sector);
    }
  }

  createSystem(systems) {
    this.systems = systems.map((system) => ({ ...system, ...{ visibility: 0 } }));
    this.systemsToRepaint = new Set(systems.map((system) => system.id));
    this.systemsById = new Map(this.systems.map((s) => [s.id, s]));
  }

  // Patches systems in place: a single-system broadcast used to rebuild
  // the whole array (one fresh object per system, two JSON.stringify per
  // system as the dirty check) — at 5k systems that was ~ms of work and
  // hundreds of KB of allocation per message, arriving continuously in
  // bot-heavy games. In-place mutation also keeps systemsById valid
  // without a rebuild. The own-faction sweep stays a full pass because
  // own systems are not guaranteed to appear in `contacts`.
  updateSystems(systems, contacts) {
    const ownFaction = store.state.game.player.faction;
    const incomingById = systems.length ? new Map(systems.map((s) => [s.id, s])) : null;

    for (const system of this.systems) {
      const incoming = incomingById ? incomingById.get(system.id) : undefined;
      if (incoming) {
        // Merge the new server version over the old one. The payload
        // never carries client-only fields (visibility), so they survive.
        // The server only broadcasts on change — repaint unconditionally
        // instead of diffing.
        Object.assign(system, incoming);
        this.systemsToRepaint.add(system.id);
      }

      let visibility = system.visibility;
      if (contacts[system.id]) {
        visibility = contacts[system.id].value;
      }
      if (system.faction === ownFaction) {
        visibility = 5;
      }

      if (visibility !== system.visibility) {
        system.visibility = visibility;
        this.systemsToRepaint.add(system.id);
      }
    }
  }

  updateSectors(sectors) {
    hashObject(sectors).then((hash) => {
      if (hash !== this.sectorHash) {
        this.sectorHash = hash;
        this.sectors = sectors;
        this.hasToRepaintSectors = true;
      }
    });
  }

  updateRadars(radars) {
    hashObject(radars).then((hash) => {
      if (hash !== this.radarsHash) {
        this.radarsHash = hash;
        this.radars = radars;
        this.hasToRepaintRadars = true;
      }
    });
  }

  forceRedrawRadars() {
    this.hasToRepaintRadars = true;
  }

  updateDetectedObjects(detectedObjects) {
    // The server pushes per-recipient sanitized blips with the shape
    // {faction, position, angle} — character_id and owner_player_id
    // are stripped in Portal.Controllers.FactionChannel.handle_out/3
    // before serialization. The viewer's own characters are filtered
    // server-side (by owner_player_id), but faction-mates are kept so
    // their Navarchs render as anonymous faction-colored blips when
    // they enter your S.L.S.D., same as enemy Navarchs.
    this.detectedObjects = detectedObjects;
    this.hasToRepaintDetectedObjects = true;
  }
}
