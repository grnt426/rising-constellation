import {
  FileLoader,
  FontLoader,
  ImageLoader,
  Texture,
} from 'three';

// Every file the galaxy map downloads (sprites, fonts, the skydome) goes
// through here. They used to load once with no error handler: one dropped
// request (a network blip, a 502 mid-deploy) left its texture without an
// image, which three.js draws fully transparent, so e.g. every system dot
// vanished for the whole session with nothing in the UI to say why. Loads
// now retry with backoff, and a file that never arrives is handed to
// `onFailure(url, error)` so the map can tell the player to reload.

// Wait before each retry; three retries, ~13s in all before giving up.
const RETRY_DELAYS_MS = [1000, 3000, 9000];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Retries carry a cache-busting query so a stale or errored cache entry
// can't answer them.
function attemptUrl(url, attempt) {
  if (attempt === 0) return url;
  return `${url}${url.includes('?') ? '&' : '?'}retry=${attempt}`;
}

// Runs `attempt(url)` (a function returning a Promise) until it resolves.
// Rejects with the last error once the retries are used up, after
// reporting it to onFailure.
async function withRetry(url, attempt, onFailure) {
  for (let n = 0; ; n += 1) {
    try {
      // eslint-disable-next-line no-await-in-loop
      return await attempt(attemptUrl(url, n));
    } catch (error) {
      if (n >= RETRY_DELAYS_MS.length) {
        onFailure(url, error);
        throw error;
      }
      // eslint-disable-next-line no-await-in-loop
      await sleep(RETRY_DELAYS_MS[n]);
    }
  }
}

// Any three.js loader with the standard load(url, onLoad, onProgress,
// onError) signature (ImageLoader, MTLLoader, OBJLoader, ...).
export function loadAsset(loader, url, onFailure) {
  return withRetry(
    url,
    (src) => new Promise((resolve, reject) => loader.load(src, resolve, undefined, reject)),
    onFailure,
  );
}

const imageLoader = new ImageLoader();

// Drop-in for TextureLoader#load: returns the Texture right away and fills
// in its image once a load succeeds, so materials built from it show the
// image on the next render, even when that is after a retry.
export function loadTexture(url, onFailure) {
  const texture = new Texture();
  loadAsset(imageLoader, url, onFailure)
    .then((image) => {
      texture.image = image;
      texture.needsUpdate = true;
    })
    .catch(() => {}); // already reported by withRetry
  return texture;
}

const fontFileLoader = new FileLoader();
const fontParser = new FontLoader();

// Not loadAsset(new FontLoader(), ...): FontLoader parses inside
// FileLoader's success callback without catching, so a body that isn't
// JSON (an HTML error page served as 200) throws there and never reaches
// onError; the load would hang instead of retrying. Parse here instead.
export function loadFont(url, onFailure) {
  return withRetry(
    url,
    (src) => new Promise((resolve, reject) => {
      fontFileLoader.load(src, (text) => {
        try {
          resolve(fontParser.parse(JSON.parse(text)));
        } catch (error) {
          reject(error);
        }
      }, undefined, reject);
    }),
    onFailure,
  );
}
