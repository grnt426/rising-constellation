/**
 * Report an enemy to the faction's Spotted channel.
 *
 * The client only points — at a blip on the map, at an agent in a system
 * — and the server decides what is really there to report, posts the
 * chat line and keeps the sighting up to date. The reply names the chat
 * message, freshly posted or already there: either way the chat opens on
 * it, so the player sees what the faction was told.
 *
 * `vm` is any component instance (for $socket, $root, $t and toasts).
 */

function onReply(vm, push) {
  push
    .receive('ok', (reply) => {
      if (reply.duplicate) {
        vm.$toasted.show(vm.$t('in_game_chat.sighting.already_reported'));
      }

      vm.$root.$emit('chat:showMessage', reply.message_id);
    })
    .receive('error', (data) => {
      vm.$toastError((data && data.reason) || 'invalid_payload');
    });
}

// A blip of the S.L.S.D.: blips carry no identity on the wire, so it is
// named by where it was drawn and in which faction's colours.
export function reportFleet(vm, { faction, position }) {
  onReply(vm, vm.$socket.faction.push('report_fleet', {
    x: position.x,
    y: position.y,
    faction,
  }));
}

// An agent of another faction standing in a system the player can see into.
export function reportAgent(vm, systemId, characterId) {
  onReply(vm, vm.$socket.faction.push('report_agent', {
    system_id: systemId,
    character_id: characterId,
  }));
}

// Whether an agent (a system roster entry or a fetched character) can be
// reported: it belongs to another faction. The tutorial is solo and has
// no chat.
export function canReportAgent(vm, character) {
  const { playerFaction, galaxy } = vm.$store.state.game;

  return !!(character && character.owner && playerFaction
    && character.owner.faction !== playerFaction
    && !(galaxy && galaxy.tutorial_id));
}
