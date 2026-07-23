import Vue from 'vue';

// Single source of truth for "are we on a phone-sized viewport". Kept as
// a shared observable (not per-component matchMedia listeners) so every
// component flips together and tests can stub one place. Must match
// $mobile-breakpoint in styles/shared/variables.scss.
const MOBILE_QUERY = '(max-width: 768px)';

const mq = window.matchMedia(MOBILE_QUERY);

const viewport = Vue.observable({
  isMobile: mq.matches,
});

const onChange = (e) => { viewport.isMobile = e.matches; };

if (typeof mq.addEventListener === 'function') {
  mq.addEventListener('change', onChange);
} else {
  // Safari < 14
  mq.addListener(onChange);
}

export default viewport;
