// Rendering for serialized `Core.Bonus` values.
//
// Faction tradition bonuses used to hardcode their number in the locale
// files ("Production: +30"), which let the copy drift from the engine
// content in lib/data/game/content/faction.ex — synelle_early advertised
// +30 while the engine actually granted +20. The locale now carries only
// the label and the number is derived from the bonus the backend already
// serializes, so that class of bug can't recur.

import format from '@/utils/format';

// Targets whose stored value is a rate/coefficient in 0..1 rather than a
// whole resource amount. An additive bonus on one of these reads naturally
// as a percentage (`dominion_rate` +0.1 is "+10%", not "+0.1"). Derived
// from the pipeline metadata rather than an enumerated list so coefficients
// added later are covered without touching this file.
const isRateTarget = (target) => /_(coef|rate)$/.test(target?.to_key || '');

// `bonusOut` is the `bonus_pipeline_out` content list, present on both the
// game store (state.game.data) and the portal store (state.portal.data).
export function formatBonusValue(bonus, bonusOut = []) {
  if (!bonus || typeof bonus.value !== 'number') return '';

  const target = bonusOut.find((b) => b.key === bonus.to);

  // `mul` bonuses are always a fraction of some base value, and so are
  // additive bonuses aimed at a rate target. Both read as percentages.
  if (bonus.type === 'mul' || isRateTarget(target)) {
    // Scale before rounding: 0.15 * 100 is 15.000000000000002 in binary
    // floating point and the stray digits would otherwise reach the UI.
    const percent = Math.round(bonus.value * 1000) / 10;
    return `${format.mixed(percent, 1, true)}%`;
  }

  return format.mixed(bonus.value, 1, true);
}

export default { formatBonusValue };
