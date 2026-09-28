// Beta feature flags: whether a given key is ON for this account.
//
// The backend stores one row per (account, feature) and returns a
// %{key => bool} map, so a key is simply ABSENT until the account has
// ever touched its toggle. That absence is what this module resolves:
// each key has a default, and only an explicit row overrides it.
//
// Most betas default off — they ship dark and you opt in. `mobile_ui`
// graduated: it is the standard phone layout now, so it defaults ON and
// the Beta Features toggle is an opt-OUT. Accounts that had already
// turned it off keep an explicit `false` row and stay off.
const DEFAULTS = Object.freeze({
  agent_fan_display: false,
  mobile_ui: true,
  slim_sync: false,
  help_manual: false,
});

export function featureDefault(key) {
  return DEFAULTS[key] === true;
}

// `features` is the raw map from the store (may be empty during boot).
export function isFeatureOn(features, key) {
  const explicit = (features || {})[key];
  return typeof explicit === 'boolean' ? explicit : featureDefault(key);
}

export default { featureDefault, isFeatureOn };
