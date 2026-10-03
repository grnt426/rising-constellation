import Vue from 'vue';

import VueToasted from 'vue-toasted';
import VueLodash from 'vue-lodash';
import VueConfig from 'vue-config';
import VueSvgIcon from 'vue-svgicon';
import VueShortkey from 'vue-shortkey';
import { VTooltip, VPopover } from 'v-tooltip';
import vSelect from 'vue-select';

import lodash from 'lodash';

import App from '@/App.vue';
import config from '@/config';
import store from '@/store';
import router from '@/router';
import PageFlowScrollbar from '@/utils/PageFlowScrollbar';

import '@/icons';
import '@/plugins/filters';
import '@/assets/fonts/fonts.scss';

// Side-effect import: maintains the `is-mobile-ui` class on <body> (mobile_ui
// beta + phone viewport). Must load with the app shell — importing it only
// from game components leaves portal pages unstamped until a game is opened.
import { onViewportChange } from '@/utils/viewport';

import axios from '@/plugins/axios';
import { i18n } from '@/plugins/i18n';
import Socket from '@/plugins/websockets';
import Ambiance from '@/plugins/ambiance';
import A11y from '@/plugins/a11y';
import { installDiagnostics } from '@/game/debug/collector';

// Help → Debug report: errors, console, socket traffic and performance
// samples are only useful if they cover the time BEFORE the player opens
// the tab, so the (in-memory, capped) collector starts with the app.
installDiagnostics({ Vue, store, router });

Vue.use(Socket);
Vue.use(Ambiance);
// `.chat-composer` is a contenteditable div, which vue-shortkey doesn't
// treat as an input by default. Without it in the prevent list, every
// game hotkey (e.g. A = Active Agents) fires AND eats the keystroke
// while the player is typing in chat.
// `.calc-suppress` marks the calculator surfaces (QuickCalc overlay,
// Empire → Financials tab). The suppression check runs against
// document.activeElement, so the `*` variant covers buttons/chips inside,
// and the surfaces carry tabindex="-1" so clicks on non-focusable parts
// focus the container instead of falling through to <body> (where
// hotkeys would fire again).
// `select`: letter keys pick options in a focused dropdown (the survey
// and agent-orders filters) — without it, typing there also fires game
// hotkeys (A opened Operations mid-selection).
Vue.use(VueShortkey, {
  prevent: ['input', 'textarea', 'select', '.chat-composer', '.calc-suppress', '.calc-suppress *'],
});
Vue.use(VueLodash, { lodash });
Vue.use(axios);
Vue.use(VueConfig, config);
Vue.use(VueSvgIcon, { tagName: 'svgicon' });
// 5 s (was 3): too short to read a long error. Screen readers get the
// text through the a11y plugin either way, and hovering holds a toast.
Vue.use(VueToasted, {
  position: 'bottom-right',
  duration: 5000,
  keepOnHover: true,
});
// After VueToasted: $announce, v-press, and toasts voiced to screen readers.
Vue.use(A11y);

Vue.component('v-scrollbar', PageFlowScrollbar);
Vue.component('v-popover', VPopover);
Vue.component('v-select', vSelect);

Vue.directive('tooltip', VTooltip);

// Touch has no hover. v-tooltip's 'hover' trigger shows on mouseenter
// and hides on click, and a tap fires both back to back — so every
// tooltip flashed and vanished in the same gesture, which is why
// resource figures and icon buttons were unreadable on a phone. At
// phone widths a tap toggles the tooltip instead (a second tap, or a
// tap anywhere else, closes it); the pointer keeps hover.
onViewportChange((isMobile) => {
  VTooltip.options.defaultTrigger = isMobile ? 'click' : 'hover focus';
});

// Vue's dev-mode performance instrumentation wraps every component
// lifecycle hook with performance.mark/measure calls. It's useful for
// the Performance tab in browser devtools, but it has a real cost on
// pages with many reactive computeds (the map editor's step-2/3 in
// particular spent 10%+ of CPU on these markers in profiling). Default
// to OFF; flip back to `isDev` locally when you need Vue lifecycle
// markers visible in a profile session.
Vue.config.performance = false;
Vue.config.productionTip = false;

new Vue({
  i18n,
  router,
  store,
  render: (h) => h(App),
}).$mount('#app');

// remove right click globally
document.addEventListener('contextmenu', (event) => event.preventDefault());
document.addEventListener('click', () => Ambiance.ambiance.sound('click'));
