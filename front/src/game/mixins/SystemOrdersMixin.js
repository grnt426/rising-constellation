import actionValidation from '@/utils/actionValidation';

// The orders the selected agent can be given in the open system: on the
// system itself (`actions`: colonize, conquer, raid, loot, infiltrate,
// take control, destabilize, portal, move) and on each agent present
// (`systemCharacters`: fight, removal, sabotage, seduction, armada).
// Shared by the system view's two agent displays (fan and legacy arc)
// and the screen-reader briefing, which used to carry identical copies.
//
// Needs a `system` prop and `isOwnProperty`.
export default {
  computed: {
    player() { return this.$store.state.game.player; },
    characters() { return this.$store.state.game.player.characters; },
    selectedCharacter() { return this.$store.state.game.selectedCharacter; },
    sectors() { return this.$store.state.game.galaxy.sectors; },
    systemTheme() {
      return this.system.owner
        ? this.getTheme(this.system.owner.faction)
        : null;
    },
    selectedCharacterTheme() {
      return this.selectedCharacter
        ? this.getTheme(this.selectedCharacter.owner.faction)
        : null;
    },
    actions() {
      const actions = [];
      const context = {
        vm: this,
        selectedCharacter: this.selectedCharacter,
        system: this.system,
        sectors: this.sectors,
        themes: {
          system: this.systemTheme,
          character: this.selectedCharacterTheme,
        },
      };

      if (!this.selectedCharacter) {
        return actions;
      }

      if (this.selectedCharacter.type === 'admiral' && !this.isOwnProperty) {
        if (this.system.owner === null && this.system.status === 'uninhabited') {
          actionValidation.colonization(actions, context, this.hasSystemSlot);
        }

        if (['inhabited_neutral', 'inhabited_dominion', 'inhabited_player'].includes(this.system.status)) {
          const defense = this.system.defense ? this.system.defense.value : null;
          const overview = {
            attacker: this.selectedCharacter.army.raid_coef.value,
            attackerIcon: 'ship/raid',
            attackerModifier: this.selectedCharacter.level,
            attackerTheme: context.themes.character,
            defender: defense,
            defenderIcon: 'resource/defense',
            defenderTheme: context.themes.system,
          };

          actionValidation.conquest(actions, context, this.hasSystemSlot, this.systemTheme);
          actionValidation.raid(actions, context, overview);
          actionValidation.loot(actions, context, overview);
        }
      }

      if (this.selectedCharacter.type === 'spy' && !this.isOwnProperty) {
        if (['inhabited_neutral', 'inhabited_dominion', 'inhabited_player'].includes(this.system.status)) {
          actionValidation.infiltrate(actions, context);
        }
      }

      if (this.selectedCharacter.type === 'speaker' && !this.isOwnProperty) {
        if (['inhabited_neutral', 'inhabited_dominion'].includes(this.system.status)) {
          actionValidation.makeDominion(actions, context, this.hasDominionSlot);
        }

        if (['inhabited_neutral', 'inhabited_dominion', 'inhabited_player'].includes(this.system.status)) {
          actionValidation.encourageHate(actions, context);
        }
      }

      // faction gateway: any own agent may portal from a linked, free
      // gateway pair (docs/faction-buildings.md)
      if (this.gatewayAction) {
        actions.push(this.gatewayAction);
      }

      // move action
      if (this.selectedCharacter.actions && this.selectedCharacter.actions.virtual_position !== this.system.id) {
        actions.push({ status: 'available', icon: 'jump', name: 'move', reasons: '' });
      }

      return actions;
    },
    gatewayAction() {
      const faction = this.$store.state.game.faction;
      const government = faction && faction.government;
      if (!government || !this.selectedCharacter) return null;

      const links = government.gateway_links || [];
      const link = links.find((l) => l.endpoints.some((e) => e.system_id === this.system.id));
      if (!link) return null;

      if (link.status !== 'linked') {
        return {
          status: 'unavailable',
          icon: 'gateway_charge',
          name: 'gateway_charge',
          reasons: this.$t('galaxy.system.actions.fail_hint_gateway_not_ready'),
        };
      }
      if (link.transit) {
        return {
          status: 'unavailable',
          icon: 'gateway_charge',
          name: 'gateway_charge',
          reasons: this.$t('galaxy.system.actions.fail_hint_gateway_busy'),
        };
      }
      if (government.station_powered === false) {
        return {
          status: 'unavailable',
          icon: 'gateway_charge',
          name: 'gateway_charge',
          reasons: this.$t('galaxy.system.actions.fail_hint_gateway_unpowered'),
        };
      }

      return { status: 'available', icon: 'gateway_charge', name: 'gateway_charge', reasons: '' };
    },
    systemCharacters() {
      if (this.system.characters) {
        const context = {
          vm: this,
          selectedCharacter: this.selectedCharacter,
          system: this.system,
          characterTheme: this.selectedCharacterTheme,
        };

        return this.system.characters.map((character) => {
          const actions = { character, actions: [] };
          const targetTheme = this.getTheme(character.owner.faction);

          if (!this.selectedCharacter) {
            return actions;
          }

          if (this.selectedCharacter.owner.id !== character.owner.id) {
            if (this.selectedCharacter.type === 'admiral'
              && character.type === 'admiral'
              // A moving or busy Navarch may queue the attack: the map handler
              // prepends the jump path and Fight.start resolves the target at
              // arrival (skipped with a notif if it left). Docking fleets cannot
              // move, so they may only attack where they sit.
              && (this.selectedCharacter.action_status !== 'docking'
                || this.selectedCharacter.system === this.system.id)) {
              actionValidation.fight(actions, context);
            }

            if (this.selectedCharacter.type === 'spy') {
              actionValidation.assassination(actions, context, character, targetTheme);

              if (character.type === 'admiral') {
                actionValidation.sabotage(actions, context, character, targetTheme);
              }
            }

            if (this.selectedCharacter.type === 'speaker') {
              actionValidation.conversion(actions, context, character, this.player, targetTheme);
            }
          } else if (this.selectedCharacter.id !== character.id
            && this.selectedCharacter.type === 'admiral'
            && character.type === 'admiral'
            && character.owner.id === this.player.id) {
            // own admiral pair: offer Form/Join Armada on the target
            actionValidation.armada(actions, context, character, this.characters);
          }

          return actions;
        });
      }

      return [];
    },
    hasSystemSlot() {
      return this.player.stellar_systems.length < this.player.max_systems.value;
    },
    hasDominionSlot() {
      return this.player.dominions.length < this.player.max_dominions.value;
    },
  },
  methods: {
    getTheme(faction) {
      return this.$store.getters['game/themeByKey'](faction);
    },
    // An order on the system itself (the `actions` list).
    orderOnSystem(actionIcon) {
      this.$root.$emit('map:addAction', actionIcon, { system: this.system });
    },
    // An order on an agent present (a `systemCharacters` action). Armada
    // formation is a state change, not a queued action: it goes straight
    // to the player channel, never through the map:addAction
    // itinerary-prepend path.
    orderOnCharacter(action, targetId) {
      if (action.armadaEvent) {
        this.$socket.player.push(action.armadaEvent, action.armadaPayload)
          .receive('error', (data) => { this.$toastError(data.reason); });
        return;
      }

      this.$root.$emit('map:addAction', action.icon, { character: targetId, system: this.system });
    },
  },
};
