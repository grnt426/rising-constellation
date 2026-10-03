import Vue from 'vue';
import Router from 'vue-router';

import config from '@/config';
import store from '@/store';

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
    }, {
      path: '/new-player',
      component: () => import('@/portal/pages/NewPlayer.vue'),
    }, {
      path: '/play',
      component: () => import('@/portal/pages/Play.vue'),
      children: [
        {
          path: '', redirect: 'slow',
        }, {
          path: 'fast',
          component: () => import('@/portal/pages/play/Flash.vue'),
        }, {
          path: 'medium',
          component: () => import('@/portal/pages/play/Tactical.vue'),
        }, {
          path: 'slow',
          component: () => import('@/portal/pages/play/Legacy.vue'),
        }, {
          path: 'fast/schedule',
          component: () => import('@/portal/pages/play/FlashSchedule.vue'),
        }, {
          path: 'slow/archive',
          component: () => import('@/portal/pages/play/Archive.vue'),
        }, {
          path: 'slow/archive/:id',
          component: () => import('@/portal/pages/play/ArchiveMatch.vue'),
        }, {
          path: 'tutorial',
          component: () => import('@/portal/pages/play/Tutorial.vue'),
        }, {
          path: 'daily',
          component: () => import('@/portal/pages/play/Daily.vue'),
        }, {
          path: 'from-scenarios/:speed',
          component: () => import('@/portal/pages/play/Scenarios.vue'),
        }, {
          path: 'new/:sid',
          component: () => import('@/portal/pages/play/New.vue'),
        },
      ],
    }, {
      path: '/instance/:iid',
      component: () => import('@/portal/pages/Instance.vue'),
    }, {
      // Rebel Defense bot-controller health readout (admins only).
      path: '/instance/:iid/rebellion',
      beforeEnter: onlyAdminGuard((to) => `/instance/${to.params.iid}`),
      component: () => import('@/portal/pages/WaveDiagnostics.vue'),
    }, {
      path: '/create',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/Create.vue'),
      children: [
        { path: '', redirect: 'maps' }, {
          path: 'maps',
          component: () => import('@/portal/pages/create/Maps.vue'),
        }, {
          path: 'scenarios',
          component: () => import('@/portal/pages/create/Scenarios.vue'),
        },
      ],
    }, {
      // Read-only share/detail pages. Declared before the editor routes:
      // '/create/scenario/view/:id' would otherwise match the editor's
      // ':mode/:id' pattern with mode = 'view'.
      path: '/create/map/view/:id',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/create/MapDetail.vue'),
    }, {
      path: '/create/scenario/view/:id',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/create/ScenarioDetail.vue'),
    }, {
      path: '/create/map/:id',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/create/Map.vue'),
    }, {
      path: '/create/scenario/:mode/:id',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/create/Scenario.vue'),
    }, {
      path: '/account',
      component: () => import('@/portal/pages/Account.vue'),
      children: [
        {
          path: '', redirect: 'info',
        }, {
          path: 'info',
          component: () => import('@/portal/pages/account/Info.vue'),
        }, {
          path: 'password',
          component: () => import('@/portal/pages/account/Password.vue'),
        }, {
          path: 'link-discord',
          component: () => import('@/portal/pages/account/LinkDiscord.vue'),
        }, {
          path: 'beta-features',
          component: () => import('@/portal/pages/account/BetaFeatures.vue'),
        }, {
          path: 'delete',
          component: () => import('@/portal/pages/account/DeleteAccount.vue'),
        },
      ],
    }, {
      path: '/profiles',
      component: () => import('@/portal/pages/Profile.vue'),
      children: [
        {
          path: ':pid',
          component: () => import('@/portal/pages/profile/Detail.vue'),
        },
      ],
    }, {
      path: '/standings',
      component: () => import('@/portal/pages/Standings.vue'),
    }, {
      path: '/invites',
      beforeEnter: onlySignedInGuard,
      component: () => import('@/portal/pages/Invites.vue'),
    }, {
      path: '/account-locked',
      component: () => import('@/portal/pages/AccountLocked.vue'),
    }, {
      path: '/settings',
      component: () => import('@/portal/pages/Settings.vue'),
    }, {
      path: '/fight-simulator',
      component: () => import('@/portal/pages/FightSimulator.vue'),
    }, {
      path: '/system-planner',
      component: () => import('@/portal/pages/SystemPlanner.vue'),
    }, {
      path: '/maintenance',
      component: () => import('@/portal/pages/Maintenance.vue'),
    }, {
      path: '/game',
      component: () => import('@/game/Game.vue'),
    }, {
      path: '*',
      component: () => import('@/portal/pages/Menu.vue'),
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

export default router;
