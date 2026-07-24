import Vue from 'vue';
import store from '@/store';

// Single source of truth for "should the mobile UI be active".
//
// Two gates, both required:
//   1. the viewport is phone-sized (must match $mobile-breakpoint in
//      styles/shared/variables.scss), and
//   2. the account opted into the `mobile_ui` beta feature
//      (Account → Beta Features; default off).
//
// JS consumers read the `viewport.isMobile` observable; CSS consumers
// key off the `is-mobile-ui` class this module maintains on <body> —
// every mobile stylesheet block is scoped `body.is-mobile-ui`.
const MOBILE_QUERY = '(max-width: 768px)';

const mq = window.matchMedia(MOBILE_QUERY);

const viewport = Vue.observable({
  isMobile: false,
});

const update = () => {
  const features = (store.state.portal && store.state.portal.features) || {};
  const active = mq.matches && features.mobile_ui === true;
  viewport.isMobile = active;
  if (document.body) {
    document.body.classList.toggle('is-mobile-ui', active);
  }
};

if (typeof mq.addEventListener === 'function') {
  mq.addEventListener('change', update);
} else {
  // Safari < 14
  mq.addListener(update);
}

// Features arrive async (portal boot) and can change from the Beta
// Features tab at any time.
store.watch((state) => state.portal.features, update);

update();

export default viewport;
