// Agent training (docs/agent-training.md): what the client needs to know
// about a student's `training` map — the server's
// Instance.Character.Training, read-only here.

import { liveElapsed, UNIT_MS } from '@/game/clock';

// The building that hosts each school. The Polytech takes every agent
// type; a university takes the agents of its own type.
export const SCHOOL_BUILDINGS = {
  polytech: 'university_open',
  admiral: 'military_school_dome',
  spy: 'counterintelligence_open',
  speaker: 'monument_dome',
};

const FEE_RESOURCES = { admiral: 'technology', spy: 'credit', speaker: 'ideology' };

export function schoolBuilding(character) {
  if (!character.training) return null;
  return character.training.school === 'polytech' ? SCHOOL_BUILDINGS.polytech : SCHOOL_BUILDINGS[character.type];
}

// Settling in or on its course: the agent holds a seat, pays its fee and
// defends itself with a cut protection and determination.
export function inClass(training) {
  return !!training && (training.phase === 'settling' || training.phase === 'active');
}

// A university student that is settling in, as it stands right now:
// { total, elapsed, remaining } in ticks, `progress` in [0, 1] and `until`,
// the moment it is over (ms, null when the clock is unknown). null for
// anyone who is not settling in. `time` is the store's game time and
// `speedFactor` its effective speed factor (see game/clock.js).
export function settling(training, constant, time, speedFactor, wallNow = Date.now()) {
  if (!training || training.school !== 'university' || training.phase !== 'settling') return null;

  const total = constant.university_settle_time;
  const elapsed = Math.min(liveElapsed(training.elapsed, training.at, time, speedFactor, wallNow), total);
  const remaining = Math.max(total - elapsed, 0);

  return {
    total,
    elapsed,
    remaining,
    progress: total > 0 ? elapsed / total : 1,
    until: speedFactor ? wallNow + ((remaining * UNIT_MS) / speedFactor) : null,
  };
}

// Multiplier on the governor's passive experience rate.
export function xpFactor(training, constant) {
  if (!training || training.phase !== 'active') return 0;
  return training.school === 'polytech' ? constant.polytech_xp_factor : constant.university_xp_factor;
}

// { resource, amount } per tick, or null when the agent pays nothing.
export function fee(character, constant) {
  const { training } = character;
  if (!training || training.school !== 'university' || !inClass(training)) return null;

  const resource = FEE_RESOURCES[character.type];
  return { resource, amount: constant[`university_fee_${resource}`] * character.level };
}

// One line saying where a student stands, for tooltips and cards.
export function trainingStatus(vm, character) {
  const { training } = character;
  if (!training) return '';

  if (training.school === 'polytech') return vm.$t('galaxy.school.status_polytech');
  if (training.phase === 'settling') return vm.$t('galaxy.school.status_settling');
  if (training.phase === 'active') return vm.$t('galaxy.school.status_active');

  // a course that is over: the agent is on its way back to the deck
  return training.ended === 'unpaid'
    ? vm.$t('galaxy.school.status_unpaid')
    : vm.$t('galaxy.school.status_completed');
}

// The wait of a deck agent queued for a seat (the deck entry's `queue`):
// `until` is the latest moment it is seated, as a timestamp, or null behind
// a Polytech student, who never has to leave.
export function seatWait(queue, receivedAt, tickToMilisecondFactor, now = Date.now()) {
  if (!queue) return null;
  if (!queue.wait || typeof queue.wait.value !== 'number') return { until: null, hours: null, minutes: null };

  const until = (receivedAt || now) + (queue.wait.value * tickToMilisecondFactor);
  const minutes = Math.max(Math.ceil((until - now) / 60000), 0);

  return { until, minutes, hours: Math.round(minutes / 60) };
}

// Mirrors Training.check_reallocation/5: null when `draft` is a legal
// reallocation of `skills`, otherwise the reason it is not.
export function reallocationProblem(skills, draft, mainIndex, held, maxSkill = 12) {
  const raised = draft.map((value, i) => value - skills[i]).filter((delta) => delta > 0);
  const moved = raised.reduce((sum, delta) => sum + delta, 0);
  const total = (list) => list.reduce((sum, value) => sum + value, 0);

  if (total(draft) !== total(skills)) return 'unplaced';
  if (moved === 0) return 'nothing';
  if (moved > held) return 'short';
  if (draft.some((value, i) => value > skills[i] && value > maxSkill)) return 'maximum';
  if (draft.some((value, i) => value > skills[i] && i !== mainIndex && value > draft[mainIndex])) return 'main';

  return null;
}
