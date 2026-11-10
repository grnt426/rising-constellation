import { cardArtSrcset, prefersLowData } from '@/utils/card-art';
import { portraitSrcFor } from '@/utils/portraits';

// The global <card-art>: a card illustration as
//   <picture>
//     <source type="image/webp" srcset="x.webp 400w, x@2x.webp 800w" sizes="304px">
//     <img src="x.jpg" loading="lazy" decoding="async">
//   </picture>
// so each screen downloads the smallest file that is sharp on it (see
// utils/card-art.js). Anything that is not card art renders as the plain
// <img>. Class, style and other attributes land on the <img>, so existing
// `.card-illustration img` rules keep applying.
//
// Props:
//   src    the JPEG's URL (unchanged from the old <img :src>)
//   sizes  CSS width the art is drawn at; default 304px, the card's
//   eager  load at once (always-visible art: the navbar avatar, a page's
//          hero portrait); otherwise lazy, which matters in long lists
//          like the patent tree and the avatar picker
//
// Player portraits: an AI-generated portrait shows as its classic stand-in
// unless this viewer opted in (settings.aigc_portraits; utils/portraits.js).
// Every portrait on screen renders through here, so this is the one place
// that rule lives. Reading the store inside a functional render ties it to
// the parent's render, so flipping the setting updates every portrait.
const LOW_DATA = prefersLowData();

function showAigc(parent) {
  const store = parent && parent.$store;
  return Boolean(store && store.state.portal.settings.aigc_portraits);
}

export default {
  name: 'card-art',
  functional: true,
  props: {
    src: String,
    alt: { type: String, default: '' },
    sizes: { type: String, default: '304px' },
    eager: Boolean,
  },
  render(h, { props, data, parent }) {
    const src = portraitSrcFor(props.src, showAigc(parent));
    const img = h('img', {
      ...data,
      attrs: {
        ...data.attrs,
        src,
        alt: props.alt,
        loading: props.eager ? 'eager' : 'lazy',
        decoding: 'async',
      },
    });

    const srcset = cardArtSrcset(src, { lowData: LOW_DATA });
    if (!srcset) return img;

    return h('picture', [
      h('source', { attrs: { type: 'image/webp', srcset, sizes: props.sizes } }),
      img,
    ]);
  },
};
