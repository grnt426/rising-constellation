import { Howl } from 'howler';
import Path from '@/utils/path';
import config from '@/config';

import soundSprite from '@/../public/sound/event-sprite.json';

const soundList = Object.keys(soundSprite).reduce((acc, key) => {
  const name = key.split('_')[0];

  if (!acc[name]) acc[name] = [];
  acc[name].push(key);

  return acc;
}, {});

const activeSounds = new Map();

let timeout = null;
let musicPlayer = null;
let soundPlayer = null;
// let voicePlayer = null;

const contexts = {
  game: {
    current: 0,
    delayBetweenTracks: 30,
    sources: [
      'myrmezirs-law.mp3',
      'dark-side-of-the-ark.mp3',
      'cult-of-cardan.mp3',
      'syns-uprising.mp3',
      'tetra-colossus.mp3',
    ],
  },
  portal: {
    current: 0,
    delayBetweenTracks: 0,
    sources: [
      'main-theme.mp3',
    ],
  },
};

export const ambiance = {
  settings: {
    master: 0.5,
    music: 1.0,
    sound: 1.0,
    voice: 1.0,
  },
  context: 'portal',
  unlocked: false,
  unlockHandler: null,

  async init(settings, context) {
    Object.assign(this.settings, settings);
    if (context) {
      this.context = context;
    }

    if (this.unlocked) {
      return this.play();
    }

    // Browsers refuse audio until the page has seen a user gesture:
    // starting earlier only logs autoplay warnings and burns locked
    // elements from Howler's global HTML5 audio pool. Nothing is audible
    // before the first input anyway, so build the players there. The
    // Steam (NW.js) build has no autoplay policy — start right away to
    // keep the main theme greeting the player at boot.
    if (config.IS_STEAM) {
      this.unlock();
    } else {
      this.armUnlock();
    }
  },

  armUnlock() {
    if (this.unlockHandler) return;

    this.unlockHandler = () => {
      window.removeEventListener('pointerdown', this.unlockHandler, true);
      window.removeEventListener('keydown', this.unlockHandler, true);
      this.unlockHandler = null;
      this.unlock();
    };
    window.addEventListener('pointerdown', this.unlockHandler, true);
    window.addEventListener('keydown', this.unlockHandler, true);
  },

  unlock() {
    this.unlocked = true;

    soundPlayer = new Howl({
      src: [Path.relative('sound/event-sprite.mp3')],
      volume: this.getVolume('sound'),
      sprite: soundSprite,
      onend: (id) => {
        activeSounds.forEach((value, key) => {
          if (value === id) {
            activeSounds.delete(key);
          }
        });
      },
    });

    // TODO: fetch sprite
    /*
    const voiceSprite = null;
    voicePlayer = new Howl({
      src: ['sound/voice.mp3'],
      volume: this.getVolume('voice'),
      sprite: voiceSprite,
    });
    */

    return this.play();
  },

  async play() {
    if (!this.unlocked || musicPlayer) return;
    // Muted via settings: skip the player entirely instead of streaming
    // silence. updateVolume restarts it when the slider leaves zero.
    if (this.getVolume('music') <= 0) return;

    return new Promise((resolve) => {
      clearTimeout(timeout);
      const c = this.context;
      const cursor = contexts[c].current;
      const delay = contexts[c].delayBetweenTracks;
      const source = contexts[c].sources[cursor];
      const filePath = Path.relative(`music/${source}`);

      contexts[c].current = (cursor + 1) % contexts[c].sources.length;

      musicPlayer = new Howl({
        src: [filePath],
        volume: this.getVolume('music'),
        html5: true,
        onend: () => {
          timeout = setTimeout(() => {
            // unload() releases the pooled HTML5 audio element; skipping
            // it leaked one element per track change until Howler's
            // global pool ran dry ("HTML5 Audio pool exhausted").
            if (musicPlayer) {
              musicPlayer.unload();
            }
            musicPlayer = null;
            this.play();
          }, delay * 1000);
        },
        onload: () => {
          musicPlayer.play();
          resolve();
        },
      });
    });
  },

  async pause() {
    if (musicPlayer) {
      clearTimeout(timeout);
      musicPlayer.fade(this.getVolume('music'), 0, 500);

      await new Promise((resolve) => { setTimeout(resolve, 500); });
      musicPlayer.stop();
      musicPlayer.unload();
      musicPlayer = null;
    }
  },

  async changeContext(context) {
    if (context !== this.context) {
      if (!this.unlocked) {
        this.context = context;
        return;
      }
      await this.pause();
      this.context = context;
      return this.play();
    }
  },

  sound(key) {
    if (!soundPlayer) return;

    if (soundList[key]) {
      const sounds = soundList[key];
      const sound = sounds[Math.floor(Math.random() * sounds.length)];
      const id = activeSounds.get(key);
      if (id) {
        soundPlayer.stop(id);
        activeSounds.set(key, soundPlayer.play(sound));
      } else {
        activeSounds.set(key, soundPlayer.play(sound));
      }
    } else {
      // console.log(`sound "${key}" not found`);
    }
  },

  voice(key) {
    console.log(key);
    // play voice
  },

  updateVolume(type, volume) {
    this.settings[type] = volume;

    if (musicPlayer) {
      const music = this.getVolume('music');
      if (music <= 0) {
        // Slider hit zero: release the stream instead of playing silence.
        this.pause();
      } else {
        musicPlayer.volume(music);
      }
    } else if (this.unlocked && this.getVolume('music') > 0) {
      // Music was skipped (or stopped) while muted — start it now.
      this.play();
    }

    if (soundPlayer) {
      soundPlayer.volume(this.getVolume('sound'));
    }
    // voicePlayer.volume(this.getVolume('voice'));
  },

  getVolume(type) {
    return this.settings.master * this.settings[type];
  },
};

export default {
  ambiance,
  install(Vue) {
    Vue.prototype.$ambiance = ambiance;
  },
};
