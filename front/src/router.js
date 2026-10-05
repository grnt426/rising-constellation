import Vue from 'vue';
import Router from 'vue-router';

import config from '@/config';
import store from '@/store';
import { i18n } from '@/plugins/i18n';
import { announce } from '@/plugins/a11y';

Vue.use(Router);

// Cold-load deep links: guards run before AppLoading's async sign-in
// finishes, so a direct visit to a guarded URL (e.g. a shared
// /create/map/view/… link) used to bounce to the menu and stay there.
// Stash the intended destination; App.vue replays it once loading
// completes (and it survives the /login round-trip for logged-out
// visitors, since sessionStorage is per-tab).
export const DEEP_LINK_KEY = 'rc-deep-link';

const stashDeepLink = (to) => {
  if (to.fullPath && to.fullPath !== '/' && !sessionStorage.getItem(DEEP_LINK_KEY)) {
    sessionStorage.setItem(DEEP_LINK_KEY, to.fullPath);
  }
};

// Forge Stage 2 — the Forge is now open to any logged-in account. The
// admin-only gate this replaced was tied to the original Anthropic-run
// game; the community-run game wants every player to be able to author.
const onlySignedInGuard = (to, from, next) => {
  if (store.state.portal.isSignedIn) {
    next();
  } else {
    stashDeepLink(to);
    next('/');
  }
};

// Admin-only pages. Signed-out visitors (including a cold load, which runs
// before AppLoading's sign-in resolves isAdmin) stash the link like
// onlySignedInGuard does; signed-in non-admins go to the fallback.
const onlyAdminGuard = (fallback) => (to, from, next) => {
  if (store.state.portal.isSignedIn && store.state.portal.isAdmin) {
    next();
  } else if (!store.state.portal.isSignedIn) {
    stashDeepLink(to);
    next('/');
  } else {
    next(fallback(to));
  }
};

const router = new Router({
  mode: config.IS_STEAM ? 'hash' : 'history',
  base: config.IS_STEAM ? '/dist/main/' : process.env.BASE_URL,
  routes: [
    {
      path: '/',
      component: () => import('@/portal/pages/Menu.vue'),
      meta: { titleKey: 'a11y_portal.route.menu' },
    }, {
      path: '/new-player',
      component: () => import('@/portal/pages/NewPlayer.vue'),
      meta: { titleKey: 'a11y_portal.route.new_player' },
    }, {
      path: '/play',
      component: () => import('@/portal/pages/Play.vue'),
      children: [
        {
          path: '', redirect: 'slow',
        }, {
          path: 'fast',
          component: () => import('@/portal/pages/play/Flash.vue'),
          meta: { titleKey: 'a11y_portal.route.play_fast' },
        }, {
          path: 'medium',
          component: () => import('@/portal/pages/play/Tactical.vue'),
          meta: { titleKey: 'a11y_portal.route.play_medium' },
        }, {
          path: 'slow',
          component: () => import('@/portal/pages/play/Legacy.vue'),
          meta: { titleKey: 'a11y_portal.route.play_slow' },
        }, {
          path: 'fast/schedule',
          component: () => import('@/portal/pages/play/FlashSchedule.vue'),
          meta: { titleKey: 'a11y_portal.route.flash_schedule' },
        }, {
          path: 'slow/archive',
          component: () => import('@/portal/pages/play/Archive.vue'),
          meta: { titleKey: 'a11y_portal.route.archive' },
        }, {
          path: 'slow/archive/:id',
          component: () => import('@/portal/pages/play/ArchiveMatch.vue'),
          meta: { titleKey: 'a11y_portal.route.archive_match' },
        }, {
          path: 'tutorial',
          component: () => import('@/portal/pages/play/Tutorial.vue'),
          meta: { titleKey: 'a11y_portal.route.tutorial' },
        }, {
          path: 'daily',
          component: () => import('@/portal/pages/play/Daily.vue'),
          meta: { titleKey: 'a11y_portal.route.daily' },
        }, {
          path: 'from-scenarios/:speed',
          component: () => import('@/portal/pages/play/Scenarios.vue'),
          meta: { titleKey: 'a11y_portal.route.play_scenarios' },
        }, {
          path: 'new/:sid',
          component: () => import('@/portal/pages/play/New.vue'),
          meta: { titleKey: 'a11y_portal.route.new_game' },
        },
      ],
    }, {
      path: '/instance/:iid',
      component: () => import('@/portal/pages/Instance.vue'),
      meta: { titleKey: 'a11y_portal.route.instance' },
    }, {
      // Rebel Defense bot-controller health readout (admins only).
      path: '/instance/:iid/rebellion',
      beforeEnter: onlyAdminGuard((to) => `/instance/${to.params.iid}`),
      component: () => import('@/portal/pages/WaveDiagnostics.vue'),
      meta: { titleKey: 'a11y_portal.route.wave_diagnostics' },
    }, {
      path: '/create',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/Create.vue'),
      children: [
        { path: '', redirect: 'maps' }, {
          path: 'maps',
          component: () => import('@/portal/pages/create/Maps.vue'),
          meta: { titleKey: 'a11y_portal.route.forge_maps' },
        }, {
          path: 'scenarios',
          component: () => import('@/portal/pages/create/Scenarios.vue'),
          meta: { titleKey: 'a11y_portal.route.forge_scenarios' },
        },
      ],
    }, {
      // Read-only share/detail pages. Declared before the editor routes:
      // '/create/scenario/view/:id' would otherwise match the editor's
      // ':mode/:id' pattern with mode = 'view'.
      path: '/create/map/view/:id',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/create/MapDetail.vue'),
      meta: { titleKey: 'a11y_portal.route.map' },
    }, {
      path: '/create/scenario/view/:id',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/create/ScenarioDetail.vue'),
      meta: { titleKey: 'a11y_portal.route.scenario' },
    }, {
      path: '/create/map/:id',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/create/Map.vue'),
      meta: { titleKey: 'a11y_portal.route.map_editor' },
    }, {
      path: '/create/scenario/:mode/:id',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/create/Scenario.vue'),
      meta: { titleKey: 'a11y_portal.route.scenario_editor' },
    }, {
      path: '/account',
      component: () => import('@/portal/pages/Account.vue'),
      children: [
        {
          path: '', redirect: 'info',
        }, {
          path: 'info',
          component: () => import('@/portal/pages/account/Info.vue'),
          meta: { titleKey: 'a11y_portal.route.account' },
        }, {
          path: 'password',
          component: () => import('@/portal/pages/account/Password.vue'),
          meta: { titleKey: 'a11y_portal.route.password' },
        }, {
          path: 'link-discord',
          component: () => import('@/portal/pages/account/LinkDiscord.vue'),
          meta: { titleKey: 'a11y_portal.route.link_discord' },
        }, {
          path: 'beta-features',
          component: () => import('@/portal/pages/account/BetaFeatures.vue'),
          meta: { titleKey: 'a11y_portal.route.beta_features' },
        }, {
          path: 'delete',
          component: () => import('@/portal/pages/account/DeleteAccount.vue'),
          meta: { titleKey: 'a11y_portal.route.delete_account' },
        },
      ],
    }, {
      path: '/profiles',
      component: () => import('@/portal/pages/Profile.vue'),
      children: [
        {
          path: ':pid',
          component: () => import('@/portal/pages/profile/Detail.vue'),
          meta: { titleKey: 'a11y_portal.route.profile' },
        },
      ],
    }, {
      path: '/standings',
      component: () => import('@/portal/pages/Standings.vue'),
      meta: { titleKey: 'a11y_portal.route.standings' },
    }, {
      path: '/invites',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/Invites.vue'),
      meta: { titleKey: 'a11y_portal.route.invites' },
    }, {
      path: '/account-locked',
      component: () => import('@/portal/pages/AccountLocked.vue'),
      meta: { titleKey: 'a11y_portal.route.account_locked' },
    }, {
      path: '/settings',
      component: () => import('@/portal/pages/Settings.vue'),
      meta: { titleKey: 'a11y_portal.route.settings' },
    }, {
      path: '/fight-simulator',
      component: () => import('@/portal/pages/FightSimulator.vue'),
      meta: { titleKey: 'a11y_portal.route.fight_simulator' },
    }, {
      path: '/system-planner',
      component: () => import('@/portal/pages/SystemPlanner.vue'),
      meta: { titleKey: 'a11y_portal.route.system_planner' },
      // the help manual links here with ?preset=<name>, also for visitors
      // who still have to sign in
      beforeEnter: onlySignedInGuard,
    }, {
      path: '/maintenance',
      component: () => import('@/portal/pages/Maintenance.vue'),
      meta: { titleKey: 'a11y_portal.route.maintenance' },
    }, {
      path: '/game',
      component: () => import('@/game/Game.vue'),
      meta: { titleKey: 'a11y_portal.route.game', keepFocus: true },
    }, {
      path: '*',
      component: () => import('@/portal/pages/Menu.vue'),
      meta: { titleKey: 'a11y_portal.route.menu' },
    },
  ],
});

// Pages an account without a profile yet may stay on: the menu (whose
// "create profile" card leads to the new-player flow), that flow itself,
// and the lockout page. Every other page renders inside the portal
// layout, which shows the active profile.
const PROFILELESS_PATHS = ['/', '/menu', '/new-player', '/account-locked'];

// Where a signed-in account has to go instead of `to`, or null.
//
// Shared with App.vue: on a cold load these guards run before AppLoading's
// sign-in resolves (isSignedIn is still null, so every route passes), and
// App applies the same rule to the landing route once it has. Without
// that, a profile-less account opening a deep link rendered the portal
// layout with no profile and crashed to a black screen.
export function signedInRedirect(to) {
  const { account, activeProfile } = store.state.portal;

  // Deletion-pending accounts are locked to the lockout page. The API
  // enforces the same server-side (Portal.Plug.DeletionLock); this just
  // keeps the SPA from rendering pages whose calls would all 403.
  if (account && account.deletion_requested_at && to.path !== '/account-locked') {
    return '/account-locked';
  }

  if (!activeProfile && !PROFILELESS_PATHS.includes(to.path)) return '/';

  return null;
}

router.beforeEach(async (to, from, next) => {
  if (store.state.portal.isSignedIn) {
    const redirect = signedInRedirect(to);
    if (redirect) {
      if (redirect === '/') stashDeepLink(to);
      next(redirect);
      return;
    }

    if (from.path === '/game' && to.path !== '/game') {
      router.app.$socket.leaveGame();
    }
  }

  next();
});

// Page title and focus for each route. A single-page app never loads a
// new document, so without this every page was titled "Tetrarchy Falls"
// and a screen reader heard nothing when the page changed while focus
// stayed on the link that was clicked. The deepest route with a titleKey
// names the page; after it renders, focus goes to its h1 (or its <main>,
// with the title announced). The first load and same-path changes (query
// only, e.g. ?mode=edit) leave focus alone, and so does the game.
const SITE_NAME = 'Tetrarchy Falls';

export function routeTitle(route) {
  const match = [...route.matched].reverse().find((r) => r.meta && r.meta.titleKey);
  return match ? i18n.t(match.meta.titleKey) : null;
}

router.afterEach((to, from) => {
  const title = routeTitle(to);
  document.title = title ? `${title} · ${SITE_NAME}` : SITE_NAME;

  const initial = from.matched.length === 0;
  const keepFocus = to.matched.some((r) => r.meta && r.meta.keepFocus);
  if (initial || keepFocus || to.path === from.path) return;

  Vue.nextTick(() => {
    const page = to.matched[0] && to.matched[0].instances.default;
    const root = page && page.$el && page.$el.querySelector ? page.$el : null;
    if (!root) return;
    const heading = root.querySelector('h1');
    const target = heading || root.querySelector('main') || root;
    if (!target.hasAttribute('tabindex')) target.setAttribute('tabindex', '-1');
    target.focus({ preventScroll: true });
    if (!heading && title) announce(title);
  });
});

export default router;
