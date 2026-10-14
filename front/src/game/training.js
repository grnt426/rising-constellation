// Agent training (docs/agent-training.md): what the client needs to know
// about a student's `training` map — the server's
// Instance.Character.Training, read-only here.

import { liveElapsed, UNIT_MS } from '@/game/clock';

// The building that hosts each school. The Polytech, the Citadel and the
// Holodome take every agent type; a university takes the agents of its own
// type.
export const SCHOOL_BUILDINGS = {
  polytech: 'university_open',
  citadel: 'ideo_open',
  holodome: 'ideo_dome',
  admiral: 'military_school_dome',
  spy: 'counterintelligence_open',
  speaker: 'monument_dome',
};

// One seat per building for its owner's agents, and the governor's rate.
export const PASSIVE_SCHOOLS = ['polytech', 'citadel', 'holodome'];

export function isPassive(school) { return PASSIVE_SCHOOLS.includes(school); }

const FEE_RESOURCES = { admiral: 'technology', spy: 'credit', speaker: 'ideology' };

export function schoolBuilding(character) {
  if (!character.training) return null;
  const { school } = character.training;
  return isPassive(school) ? SCHOOL_BUILDINGS[school] : SCHOOL_BUILDINGS[character.type];
}

// What the buildings of its system give a course (Training, "Conditions"):
// a percent of experience, a multiplier on the time a rewire takes, one on
// its fee, and the level of its university. A map from before they existed
// carries none.
export function conditions(training) {
  const read = (key, fallback) => (training && typeof training[key] === 'number' ? training[key] : fallback);

  return {
    xpBonus: read('xp_bonus', 0),
    timeFactor: read('time_factor', 1),
    costFactor: read('cost_factor', 1),
    schoolLevel: read('school_level', 0),
  };
}

// Ticks a rewire takes under the conditions of `training`.
export function reallocationInterval(training, constant) {
  return constant.university_reallocation_interval * conditions(training).timeFactor;
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

  return phaseProgress(training, constant.university_settle_time, time, speedFactor, wallNow);
}

// A university student on its course, as it stands right now in the rewire
// it is earning: the same reading as `settling`, over the time a rewire
// takes in its system. `elapsed` starts again at each rewire earned. null
// for anyone who is not on a course.
export function earning(training, constant, time, speedFactor, wallNow = Date.now()) {
  if (!training || training.school !== 'university' || training.phase !== 'active') return null;

  return phaseProgress(training, reallocationInterval(training, constant), time, speedFactor, wallNow);
}

// how far `training.elapsed` stands in a phase of `total` ticks right now
function phaseProgress(training, total, time, speedFactor, wallNow) {
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

// Multiplier on the governor's passive experience rate: the school's own,
// raised by what the buildings of the system add.
export function xpFactor(training, constant) {
  if (!training || training.phase !== 'active') return 0;
  const base = training.school === 'university' ? constant.university_xp_factor : constant.polytech_xp_factor;
  return base * (1 + (conditions(training).xpBonus / 100));
}

// { resource, amount } per tick, or null when the agent pays nothing: one
// rate per level of the agent and per level of its university, less what
// the Holodomes of the system take off.
export function fee(character, constant) {
  const { training } = character;
  if (!training || training.school !== 'university' || !inClass(training)) return null;

  const resource = FEE_RESOURCES[character.type];
  const { schoolLevel, costFactor } = conditions(training);
  const levels = (character.level + schoolLevel) * costFactor;
  return { resource, amount: constant[`university_fee_${resource}`] * levels };
}

// One line saying where a student stands, for tooltips and cards.
export function trainingStatus(vm, character) {
  const { training } = character;
  if (!training) return '';

  if (isPassive(training.school)) return vm.$t('galaxy.school.status_polytech');
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

// Mirrors Training.reallocation_cost/2: the rewires it takes to turn
// `skills` into `draft`. One per point moved from a skill to another, two
// per point added outright; points gained are paired with the points taken
// first.
export function reallocationCost(skills, draft) {
  const deltas = draft.map((value, i) => value - skills[i]);
  const gained = deltas.filter((delta) => delta > 0).reduce((sum, delta) => sum + delta, 0);
  const taken = -deltas.filter((delta) => delta < 0).reduce((sum, delta) => sum + delta, 0);

  return gained + Math.max(gained - taken, 0);
}

// Mirrors Training.check_reallocation/5: null when `draft` is a legal
// reallocation of `skills`, otherwise the reason it is not.
export function reallocationProblem(skills, draft, mainIndex, held, maxSkill = 12) {
  const total = (list) => list.reduce((sum, value) => sum + value, 0);

  // a point taken has to be placed
  if (total(draft) < total(skills)) return 'unplaced';
  if (!draft.some((value, i) => value > skills[i])) return 'nothing';
  if (reallocationCost(skills, draft) > held) return 'short';
  if (draft.some((value, i) => value > skills[i] && value > maxSkill)) return 'maximum';
  if (draft.some((value, i) => value > skills[i] && i !== mainIndex && value > draft[mainIndex])) return 'main';

  return null;
}
