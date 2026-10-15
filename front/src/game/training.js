// Agent training (docs/agent-training.md): what the client needs to know
// about a student's `training` map — the server's
// Instance.Character.Training, read-only here.

import { liveElapsed, UNIT_MS } from '@/game/clock';
import format from '@/utils/format';

// The building that hosts each school. The Polytech (basic training)
// takes every agent type; a university (specialized training) takes the
// agents of its own type.
export const SCHOOL_BUILDINGS = {
  polytech: 'university_open',
  admiral: 'military_school_dome',
  spy: 'counterintelligence_open',
  speaker: 'monument_dome',
};

// One seat per building for its owner's agents, the governor's rate, and
// no queue.
export const PASSIVE_SCHOOLS = ['polytech'];

// Mirrors Training.seats/2: the places a university building gives at
// `level`, one at levels 1 and 2, two at 3 and 4, three at 5.
export function universitySeats(level) {
  if (level >= 5) return 3;
  if (level >= 3) return 2;
  return 1;
}

// Mirrors Training.defense_factor/2: the share of its own Protection and
// Determination a student in class keeps. At a university it follows the
// building's level, 40% at level 1 to 80% at level 5; at a Polytech it is
// `training_defense_factor`, a half.
export function defenseFactor(training, constant) {
  const level = training && training.school === 'university' ? training.school_level : null;
  if (typeof level === 'number') return [0.4, 0.5, 0.6, 0.7, 0.8][Math.min(Math.max(level, 1), 5) - 1];
  return constant.training_defense_factor;
}

// A training bonus as the cards print it, signed, with the decimals it has
// (three at most): "+3.75", "−1.875", "0". The caller adds the "%".
export function bonusNumber(value) {
  if (!value) return '0';
  return format.mixed(value, 3, true).replace(/([.,]\d*?)0+$/, '$1').replace(/[.,]$/, '');
}

export function isPassive(school) { return PASSIVE_SCHOOLS.includes(school); }

const FEE_RESOURCES = { admiral: 'technology', spy: 'credit', speaker: 'ideology' };

export function schoolBuilding(character) {
  if (!character.training) return null;
  const { school } = character.training;
  return isPassive(school) ? SCHOOL_BUILDINGS[school] : SCHOOL_BUILDINGS[character.type];
}

// What the buildings of its system give a course (Training, "Conditions"):
// a percent of experience added, percents of the rewire time and of the fee
// taken off (zero or less), and the level of its university. Percentages,
// as the server sends floats rounded to three decimals. A map from before
// they existed carries none.
export function conditions(training) {
  const read = (key, fallback) => (training && typeof training[key] === 'number' ? training[key] : fallback);

  return {
    xpBonus: read('xp_bonus', 0),
    timeBonus: read('time_bonus', 0),
    costBonus: read('cost_bonus', 0),
    schoolLevel: read('school_level', 0),
  };
}

// Ticks a rewire takes under the conditions of `training`.
export function reallocationInterval(training, constant) {
  return constant.university_reallocation_interval * (1 + (conditions(training).timeBonus / 100));
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
  const { schoolLevel, costBonus } = conditions(training);
  const levels = (character.level + schoolLevel) * (1 + (costBonus / 100));
  return { resource, amount: constant[`university_fee_${resource}`] * levels };
}

// Total experience at which an agent reaches `level`
// (Character.get_next_level_experience/1).
export function levelThreshold(level) {
  return Math.round((10 * level) + ((level / 2) ** 2.5));
}

// What a student in class has ahead of it right now, for the Training panel
// beside its card. Moments are wall-clock ms, null where none applies.
//   settle      — as `settling`, while it settles in
//   xpPerUt     — experience per tick once on its course (bonus included)
//   level       — { next, until }: its next level, which adds a skill point
//   rewire      — { next, max, until }: its next rewire
//   extraPoint  — { rewires, until }: when it holds the next even number of
//                 rewires, two of which add a skill point outright
//   courseEnd   — when its last rewire sends it home
// The copy it reads was measured at `training.at`: experience and elapsed
// time are carried forward from there, as `settling` and `earning` do.
export function outlook(character, constant, time, speedFactor, wallNow = Date.now()) {
  const { training } = character;
  if (!training || !inClass(training) || !speedFactor) return null;

  const msPerUt = UNIT_MS / speedFactor;
  const settle = settling(training, constant, time, speedFactor, wallNow);
  const onCourse = training.phase === 'active' ? training : { ...training, phase: 'active' };
  const experience = character.experience || {};
  const change = typeof experience.change === 'number' ? experience.change : 0;
  const xpPerUt = change * xpFactor(onCourse, constant);

  // experience as it stands: nothing is earned while settling in
  const since = settle ? 0 : liveElapsed(0, training.at, time, speedFactor, wallNow);
  const xp = (typeof experience.value === 'number' ? experience.value : 0) + (xpPerUt * since);
  const next = character.level + 1;
  const missing = Math.max(levelThreshold(next) - xp, 0);
  const level = {
    next,
    until: xpPerUt > 0 ? wallNow + (((settle ? settle.remaining : 0) + (missing / xpPerUt)) * msPerUt) : null,
  };

  let rewire = null;
  let extraPoint = null;
  let courseEnd = null;

  if (training.school === 'university' && typeof character.reallocations === 'number') {
    const max = constant.university_max_reallocations;
    const held = character.reallocations;
    const interval = reallocationInterval(training, constant) * msPerUt;
    const current = settle ? null : earning(training, constant, time, speedFactor, wallNow);
    const first = settle ? (settle.until !== null ? settle.until + interval : null) : current && current.until;

    if (held < max && first !== null) {
      // when the n-th rewire of the course is earned
      const at = (n) => first + ((n - held - 1) * interval);
      const even = held % 2 === 0 ? held + 2 : held + 1;

      rewire = { next: held + 1, max, until: at(held + 1) };
      courseEnd = at(max);
      extraPoint = even <= max ? { rewires: even, until: at(even) } : null;
    }
  }

  return {
    settle, xpPerUt, level, rewire, extraPoint, courseEnd, msPerUt,
  };
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
