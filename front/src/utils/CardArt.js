import { cardArtSrcset, prefersLowData } from '@/utils/card-art';

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
const LOW_DATA = prefersLowData();

export default {
  name: 'card-art',
  functional: true,
  props: {
    src: String,
    alt: { type: String, default: '' },
    sizes: { type: String, default: '304px' },
    eager: Boolean,
  },
  render(h, { props, data }) {
    const img = h('img', {
      ...data,
      attrs: {
        ...data.attrs,
        src: props.src,
        alt: props.alt,
        loading: props.eager ? 'eager' : 'lazy',
        decoding: 'async',
      },
    });

    const srcset = cardArtSrcset(props.src, { lowData: LOW_DATA });
    if (!srcset) return img;

    return h('picture', [
      h('source', { attrs: { type: 'image/webp', srcset, sizes: props.sizes } }),
      img,
    ]);
  },
};
