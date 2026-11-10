// Player portraits and the opt-in AI-generated set.
//
// The classic portraits (avatar[MF]_NNN.jpg) are the original artwork. The
// `portrait*` set was made with AI image generation. A viewer sees it only
// after turning on "AI-generated portraits" in Settings
// (settings.aigc_portraits); everyone else sees the classic stand-in paired
// with it here, and so does every surface with no known viewer (the
// Discord /player card, server side).
//
// Mirrors RC.Portraits (lib/rc/portraits.ex); a node test checks the two
// tables agree. The swap itself happens in <card-art> (utils/CardArt.js),
// which every portrait on screen goes through.
//
// No Vue, no store: runs under plain node.

export const CLASSIC_PORTRAITS = ['M', 'F'].flatMap((g) => [1, 2, 3, 4, 5, 6, 7].map((n) => `avatar${g}_00${n}.jpg`));

// AI portrait -> classic stand-in: a look-alike where there is one (hair,
// age, build), spread so few stand-ins repeat.
export const AIGC_STAND_INS = {
  'portraitF_001.jpg': 'avatarF_006.jpg',
  'portraitF_002.jpg': 'avatarF_004.jpg',
  'portraitF_003.jpg': 'avatarF_002.jpg',
  'portraitF_004.jpg': 'avatarF_003.jpg',
  'portraitF_005.jpg': 'avatarF_001.jpg',
  'portraitF_006.jpg': 'avatarF_005.jpg',
  'portraitF_007.jpg': 'avatarF_007.jpg',
  'portraitF_008.jpg': 'avatarF_003.jpg',
  'portraitM_001.jpg': 'avatarM_001.jpg',
  'portraitM_002.jpg': 'avatarM_007.jpg',
  'portraitM_003.jpg': 'avatarM_004.jpg',
  'portraitM_004.jpg': 'avatarM_003.jpg',
  'portraitM_005.jpg': 'avatarM_005.jpg',
  'portraitM_006.jpg': 'avatarM_006.jpg',
  'portraitM_007.jpg': 'avatarM_002.jpg',
  'portraitM_008.jpg': 'avatarM_004.jpg',
  'portraitR_001.jpg': 'avatarF_002.jpg',
  'portraitR_002.jpg': 'avatarM_002.jpg',
  'portraitR_003.jpg': 'avatarM_006.jpg',
  'portraitR_004.jpg': 'avatarM_005.jpg',
};

export const AIGC_PORTRAITS = Object.keys(AIGC_STAND_INS);

export function isAigcPortrait(file) {
  return Object.prototype.hasOwnProperty.call(AIGC_STAND_INS, file);
}

/** Any portrait a profile may hold, opted in or not. */
export function isKnownPortrait(file) {
  return CLASSIC_PORTRAITS.includes(file) || isAigcPortrait(file);
}

/** The portraits offered in the picker. */
export function pickablePortraits(showAigc) {
  return showAigc ? [...CLASSIC_PORTRAITS, ...AIGC_PORTRAITS] : [...CLASSIC_PORTRAITS];
}

const AVATAR_PATH = /^(.*(?:^|\/)avatars\/)([^/]+)$/;

/**
 * The portrait URL this viewer should load: an AI portrait's URL is
 * rewritten to its classic stand-in unless the viewer opted in. Any other
 * URL comes back unchanged.
 */
export function portraitSrcFor(path, showAigc) {
  if (showAigc || !path) return path;
  const match = AVATAR_PATH.exec(path);
  if (!match || !isAigcPortrait(match[2])) return path;
  return match[1] + AIGC_STAND_INS[match[2]];
}
