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

  updateSystems(systems, contacts) {
    const ownFaction = store.state.game.player.faction;

    this.systems = this.systems.map((s) => {
      let system = systems.find((s2) => s.id === s2.id);

      // merge new version with old one if found
      if (system) {
        system = { ...s, ...system };
      } else {
        system = { ...s };
      }

      // update systems contacts if found
      if (contacts[system.id]) {
        system.visibility = contacts[system.id].value;
      }

      // override visibility for own systems
      if (system.faction === ownFaction) {
        system.visibility = 5;
      }

      if (JSON.stringify(system) !== JSON.stringify(s)) {
        this.systemsToRepaint.add(system.id);
      }

      return system;
    });
    // this.systems holds fresh object refs after the map() above, so
    // the index has to be rebuilt to point at the new ones.
    this.systemsById = new Map(this.systems.map((s) => [s.id, s]));
  }

  updateSectors(sectors) {
    hashObject(sectors).then((hash) => {
      if (hash !== this.sectorHash) {
        this.sectors = sectors;
        this.hasToRepaintSectors = true;
      }
    });
  }

  updateRadars(radars) {
    hashObject(radars).then((hash) => {
      if (hash !== this.radarsHash) {
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
