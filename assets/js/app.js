// We need to import the CSS so that webpack will load it.
// The MiniCssExtractPlugin is used to separate it out into
// its own CSS file.
import '../css/app.scss';

// webpack automatically bundles all modules in your
// entry points. Those entry points can be configured
// in "webpack.config.js".
//
// Import deps with the dep name or local files with a relative path, for example:
//
//     import {Socket} from "phoenix"
//     import socket from "./socket"
//
import 'phoenix_html';
import { Socket } from 'phoenix';
import NProgress from 'nprogress';
import { LiveSocket } from 'phoenix_live_view';
import statsCharts from './stats_charts';

const Hooks = {};

// Help manual width: normal → wide → full, remembered in this browser. It
// lives on <html> so LiveView patches of the page never reset it, and it is
// applied here at load so the page does not jump after mount.
const HELP_WIDTHS = ['normal', 'wide', 'full'];
const HELP_WIDTH_LABELS = { normal: 'Wider', wide: 'Full width', full: 'Narrower' };

function currentHelpWidth() {
  return document.documentElement.dataset.helpWidth || 'normal';
}

try {
  const saved = window.localStorage.getItem('helpWidth');
  if (HELP_WIDTHS.includes(saved)) document.documentElement.dataset.helpWidth = saved;
} catch (e) {
  // Storage blocked: the default width is fine.
}

Hooks.helpWidth = {
  mounted() {
    this.sync();
    this.el.addEventListener('click', () => {
      const next = HELP_WIDTHS[(HELP_WIDTHS.indexOf(currentHelpWidth()) + 1) % HELP_WIDTHS.length];
      document.documentElement.dataset.helpWidth = next;
      try {
        window.localStorage.setItem('helpWidth', next);
      } catch (e) {
        // Storage blocked: the choice lasts for this page only.
      }
      this.sync();
    });
  },
  updated() {
    this.sync();
  },
  sync() {
    const label = HELP_WIDTH_LABELS[currentHelpWidth()];
    this.el.querySelector('.help-width-label').textContent = label;
    this.el.setAttribute('title', label);
  },
};

// Help manual rate unit: the header's per tick / per hour switch. The unit
// lives in the URL (?unit=, patched by the "set_unit" event) so the page and
// its links agree; this hook remembers the choice for the next visit. The
// links still work without JS.
function saveHelpUnit(unit) {
  try {
    window.localStorage.setItem('helpUnit', unit);
  } catch (e) {
    // Storage blocked: the choice lasts for this visit only.
  }
}

Hooks.helpUnit = {
  mounted() {
    const fromUrl = new URLSearchParams(window.location.search).get('unit');
    let saved = null;
    try {
      saved = window.localStorage.getItem('helpUnit');
    } catch (e) {
      saved = null;
    }

    if (fromUrl === 'tick' || fromUrl === 'hour') {
      saveHelpUnit(fromUrl);
    } else if (saved === 'hour' && this.el.dataset.unit !== 'hour') {
      this.pushEvent('set_unit', { unit: 'hour' });
    }

    this.el.addEventListener('click', (event) => {
      const link = event.target.closest('a[data-unit]');
      if (!link) return;
      event.preventDefault();
      saveHelpUnit(link.dataset.unit);
      if (link.dataset.unit !== this.el.dataset.unit) this.pushEvent('set_unit', { unit: link.dataset.unit });
    });
  },
};

// Help manual cards with levels (a patent's levels): each level's radio pip
// carries the level's anchor as its id, so a link to `…#level-3` opens the
// card on that level. The browser scrolls to the anchor by itself; picking
// the level needs this hook. Without JS the card opens on its first level and
// the pips still work (they are plain radio inputs).
function selectHelpLevel(root) {
  const id = decodeURIComponent(window.location.hash.slice(1));
  if (!id) return;
  const target = document.getElementById(id);
  if (target && target.type === 'radio' && root.contains(target)) target.checked = true;
}

Hooks.helpAnchor = {
  mounted() {
    selectHelpLevel(this.el);
    this.onHashChange = () => selectHelpLevel(this.el);
    window.addEventListener('hashchange', this.onHashChange);
  },
  // A patch re-renders the body with the first level checked again.
  updated() {
    selectHelpLevel(this.el);
  },
  destroyed() {
    window.removeEventListener('hashchange', this.onHashChange);
  },
};

const APIHeaders = {
  Accept: 'application/json',
  'Content-Type': 'application/json',
};

// Screen-reader announcements through the root layout's live regions
// (#a11y-status, #a11y-alert). Clear first, then set on a later task:
// repeating the same message is otherwise not a change and stays silent.
let announceTimer = null;
function announce(message, { assertive = false } = {}) {
  const region = document.getElementById(assertive ? 'a11y-alert' : 'a11y-status');
  const text = (message || '').trim();
  if (!region || !text) return;
  region.textContent = '';
  clearTimeout(announceTimer);
  announceTimer = setTimeout(() => { region.textContent = text; }, 60);
}

// The public forms report through a hidden #info-container box. Showing
// it is silent to assistive tech, so the text is also announced, and an
// error marks the fields it is about (aria-invalid, described by the box)
// and moves focus to the first of them.
function showInfo(html, { error = false, fields = [] } = {}) {
  const infoContainer = document.getElementById('info-container');
  const info = document.getElementById('info');
  infoContainer.style.display = 'block';
  info.innerHTML = html;
  announce(info.textContent, { assertive: error });

  document.querySelectorAll('input[aria-describedby="info"]').forEach((input) => {
    input.removeAttribute('aria-invalid');
    input.removeAttribute('aria-describedby');
  });
  const inputs = fields.map((id) => document.getElementById(id)).filter(Boolean);
  inputs.forEach((input) => {
    input.setAttribute('aria-invalid', 'true');
    input.setAttribute('aria-describedby', 'info');
  });
  if (inputs.length) inputs[0].focus();
}

// Busy state for submit buttons. aria-disabled + the .disabled look, not
// the disabled property: a disabled button drops keyboard focus to
// <body>, so after an error the user had to tab back through the page.
// The submit handlers ignore submits while the button is busy.
function setBusy(button, busy) {
  button.classList.toggle('disabled', busy);
  button.setAttribute('aria-disabled', busy ? 'true' : 'false');
}

function isBusy(button) {
  return button.getAttribute('aria-disabled') === 'true';
}

// ALTCHA-protocol proof-of-work: fetch a challenge from the backend and
// brute-force the number whose SHA-256(salt + number) matches it, then
// return the base64 payload the backend verifies (see Portal.Captcha).
// Returns null when the server reports the captcha disabled (dev, or prod
// without a key). Runs as an async loop so the page stays responsive
// while the "Validating…" spinner shows.
async function solveCaptcha() {
  const resp = await fetch('/api/captcha', { headers: APIHeaders });
  if (!resp.ok) throw new Error('captcha_unavailable');

  const challenge = await resp.json();
  if (!challenge.enabled) return null;

  // Hash in concurrent batches: the await round-trip, not SHA-256 itself,
  // dominates a serial loop (~5x slower). 32 in flight keeps the page
  // responsive while cutting the solve to a couple of seconds worst case.
  const encoder = new TextEncoder();
  const started = Date.now();
  const batchSize = 32;
  for (let base = 0; base <= challenge.maxnumber; base += batchSize) {
    const count = Math.min(batchSize, challenge.maxnumber - base + 1);
    /* eslint-disable-next-line no-await-in-loop */
    const digests = await Promise.all(Array.from(
      { length: count },
      (_, i) => crypto.subtle.digest('SHA-256', encoder.encode(challenge.salt + (base + i))),
    ));
    for (let i = 0; i < count; i += 1) {
      const hex = Array.from(new Uint8Array(digests[i]), (b) => b.toString(16).padStart(2, '0')).join('');
      if (hex === challenge.challenge) {
        return btoa(JSON.stringify({
          algorithm: challenge.algorithm,
          challenge: challenge.challenge,
          number: base + i,
          salt: challenge.salt,
          signature: challenge.signature,
          took: Date.now() - started,
        }));
      }
    }
  }
  throw new Error('captcha_unsolvable');
}

// Friendly wait estimate for 429 responses, from the Retry-After header
// the rate-limit plug always sets.
function retryAfterMessage(resp) {
  const seconds = parseInt(resp.headers.get('retry-after'), 10);
  const wait = Number.isNaN(seconds)
    ? 'a little while'
    : `about ${Math.max(1, Math.ceil(seconds / 60))} minute(s)`;
  return `Too many attempts. Please try again in ${wait}.`;
}

Hooks.login = {
  async mounted() {
    const url = new URL(window.location.href);
    const action = url.searchParams.get('action');
    const token = url.searchParams.get('token');

    if (action === 'validate-registration' && token) {
      try {
        await fetch('/api/accounts/validate', {
          method: 'POST',
          headers: APIHeaders,
          body: JSON.stringify({ token }),
        });

        showInfo('Your account has been validated.');
      } catch (_err) {
        showInfo('Account confirmation error.', { error: true });
      }
    }

    // Account deletion is confirmed by an explicit button press (never on
    // page load, so an email scanner following the link cannot trigger it).
    if (action === 'confirm-deletion' && token) {
      const container = document.getElementById('deletion-confirm-container');
      const body = document.getElementById('deletion-confirm-body');
      const button = document.getElementById('deletion-confirm-button');
      container.style.display = 'block';

      // The button disappears with the answer, so focus moves to the text
      // that replaced it (rather than falling back to <body>), which also
      // has a screen reader read it.
      const showResult = (html) => {
        button.style.display = 'none';
        body.innerHTML = html;
        body.setAttribute('tabindex', '-1');
        body.focus();
      };

      button.addEventListener('click', async () => {
        if (isBusy(button)) return;
        setBusy(button, true);
        try {
          const resp = await fetch('/api/accounts/confirm-deletion', {
            method: 'POST',
            headers: APIHeaders,
            body: JSON.stringify({ token }),
          });
          const data = await resp.json();
          if (!resp.ok) throw new Error(data.message || 'error');
          showResult(`<p>Your account is now locked and will be permanently deleted in ${data.grace_days} days.</p>`
            + '<p>You can log back in at any time before then to cancel the deletion.</p>');
        } catch (_err) {
          showResult('<p>This deletion link is invalid or has expired.</p>'
            + '<p>If you still want to delete your account, log in and request deletion again.</p>');
        }
      });
    }
  },
};

Hooks.signup = {
  mounted() {
    this.el.addEventListener('submit', async (e) => {
      e.preventDefault();

      const infoContainer = document.getElementById('info-container');
      const button = document.getElementById('button');

      if (isBusy(button)) return;
      setBusy(button, true);

      const email = document.getElementById('email').value;
      const name = document.getElementById('name').value;
      const password1 = document.getElementById('password1').value;
      const password2 = document.getElementById('password2').value;
      const inviteToken = this.el.dataset.inviteToken;

      const errors = [];
      const invalid = [];
      if (!email) { errors.push('Email address is required.'); invalid.push('email'); }
      if (!name) { errors.push('Name is required.'); invalid.push('name'); }
      if (!password1) {
        errors.push('Password is required.');
        invalid.push('password1');
      } else if (password1 !== password2) {
        errors.push('Passwords do not match.');
        invalid.push('password2');
      }

      const showError = (html, fields = []) => {
        infoContainer.classList.remove('is-success');
        infoContainer.classList.add('is-error');
        showInfo(html, { error: true, fields });
        setBusy(button, false);
      };

      if (errors.length === 0) {
        const password = password1;

        try {
          // Deliberately vague: the user just sees a short "Validating…"
          // while the proof-of-work challenge is being solved.
          infoContainer.classList.remove('is-error', 'is-success');
          showInfo('<span class="pow-spinner" aria-hidden="true"></span> Validating…');

          const captcha = await solveCaptcha();

          const resp = await fetch('/api/accounts', {
            method: 'POST',
            headers: APIHeaders,
            body: JSON.stringify({
              account: { email, name, password },
              invite_token: inviteToken,
              captcha,
            }),
          });

          const { message } = await resp.json();

          const successMessages = {
            signup_complete: 'Your account has been created. Check your email for the confirmation link that activates it.',
          };

          const errorMessages = {
            signup_disabled: 'Account creation is temporarily disabled. Please try again later.',
            captcha_failed: 'We could not validate your request. Please try again.',
            rate_limited: retryAfterMessage(resp),
            email_send_failed: 'Please try again later, as we could not send a confirmation email '
              + 'to that address. No account was created.',
          };

          if (successMessages[message]) {
            infoContainer.classList.remove('is-error');
            infoContainer.classList.add('is-success');
            showInfo(successMessages[message]);
            document.getElementById('email').value = '';
            document.getElementById('name').value = '';
            document.getElementById('password1').value = '';
            document.getElementById('password2').value = '';
          } else if (errorMessages[message]) {
            showError(errorMessages[message]);
          } else if (message && typeof message === 'object') {
            // Changeset field errors: {"email": ["has invalid format"], ...}
            const fieldIds = { email: 'email', name: 'name', password: 'password1' };
            showError(
              Object.entries(message)
                .map(([field, msgs]) => `${field} ${Array.isArray(msgs) ? msgs.join(', ') : msgs}`)
                .join('<br>'),
              Object.keys(message).map((field) => fieldIds[field]).filter(Boolean),
            );
          } else if (resp.status >= 500) {
            showError(`Something went wrong on our side (error ${resp.status}). `
              + 'Please try again later.');
          } else {
            showError('Account creation failed. Please check the form and try again.');
          }
        } catch (_err) {
          showError('Internal error (contact the site administrators).');
        }
      } else {
        showError(errors.join('<br>'), invalid);
      }
    });
  },
};

Hooks.requestPassword = {
  mounted() {
    this.el.addEventListener('submit', async (e) => {
      e.preventDefault();

      const button = document.getElementById('button');
      if (isBusy(button)) return;

      const email = document.getElementById('email').value;

      if (email !== '') {
        setBusy(button, true);
        try {
          const resp = await fetch('/api/accounts/request-password-reset', {
            method: 'POST',
            headers: APIHeaders,
            body: JSON.stringify({ email }),
          });

          if (resp.status === 429) {
            showInfo(retryAfterMessage(resp), { error: true });
            setBusy(button, false);
          } else {
            // Uniform wording — the backend answers the same whether or
            // not the address has an account (no enumeration).
            showInfo('If an account exists for this address, a password reset link is on its way.');
          }
        } catch (_err) {
          showInfo('Error in the request.', { error: true });
          setBusy(button, false);
        }
      } else {
        showInfo('Email address is required.', { error: true, fields: ['email'] });
      }
    });
  },
};

let validateTokenPassword = null;
Hooks.validateTokenPassword = {
  mounted() {
    const url = new URL(window.location.href);
    validateTokenPassword = url.searchParams.get('token');
  },
};

Hooks.resetPassword = {
  mounted() {
    this.el.addEventListener('submit', async (e) => {
      e.preventDefault();

      const button = document.getElementById('button');
      if (isBusy(button)) return;

      const password = document.getElementById('password').value;

      if (password) {
        setBusy(button, true);
        try {
          const resp = await fetch('/api/accounts/reset-password', {
            method: 'POST',
            headers: APIHeaders,
            body: JSON.stringify({ token: validateTokenPassword, new_password: password }),
          });
          if (!resp.ok) {
            throw new Error('Error');
          }
          showInfo('Your password has been changed. Taking you to the login page…');
          setTimeout(() => {
            const url = new URL(window.location.href);
            url.pathname = '/login';

            window.location.replace(url.href);
          }, 2000);
        } catch (_err) {
          showInfo('Error in the request.', { error: true });
          setBusy(button, false);
        }
      } else {
        showInfo('Password is required.', { error: true, fields: ['password'] });
      }
    });
  },
};

// The confirm button used to stay disabled until both fields matched,
// which left keyboard and screen-reader users with an unexplained dead
// button. It now always submits and says what is wrong.
Hooks.webBind = {
  mounted() {
    const button = document.getElementById('button');

    this.el.addEventListener('submit', async (e) => {
      e.preventDefault();
      if (isBusy(button)) return;

      const password = document.getElementById('password').value;
      const confirmation = document.getElementById('password-confirmation').value;

      if (!password) {
        showInfo('Password is required.', { error: true, fields: ['password'] });
      } else if (password !== confirmation) {
        showInfo('Passwords do not match.', { error: true, fields: ['password-confirmation'] });
      } else {
        setBusy(button, true);
        try {
          const resp = await fetch('/api/accounts/bind', {
            method: 'POST',
            headers: APIHeaders,
            body: JSON.stringify({ token: validateTokenPassword, new_password: password }),
          });
          if (!resp.ok) {
            throw new Error('Error');
          }
          showInfo('Your password has been saved. Taking you to the login page…');

          setTimeout(() => {
            const url = new URL(window.location.href);
            url.pathname = '/login';

            window.location.replace(url.href);
          }, 2000);
        } catch (_err) {
          showInfo('Error in the request.', { error: true });
          setBusy(button, false);
        }
      }
    });
  },
};

// Landing-page videos: the markup is a self-hosted poster linking to the
// video on YouTube (works without JS). On click, swap in the
// youtube-nocookie player, autoplaying since the click is the user
// gesture. Until then the page contacts no third party at all. The
// element carries phx-update="ignore", so LiveView patches leave the
// player alone.
Hooks.videoFacade = {
  mounted() {
    const link = this.el.querySelector('.video-facade-link');
    if (!link) return;
    link.addEventListener('click', (event) => {
      event.preventDefault();
      const { videoId, videoTitle } = this.el.dataset;
      const iframe = document.createElement('iframe');
      iframe.src = `https://www.youtube-nocookie.com/embed/${encodeURIComponent(videoId)}?autoplay=1&color=white&rel=0`;
      iframe.title = videoTitle;
      iframe.allow = 'autoplay; encrypted-media; picture-in-picture';
      iframe.allowFullscreen = true;
      this.el.innerHTML = '';
      this.el.appendChild(iframe);
      iframe.focus();
    });
  },
};

Hooks.statsCharts = {
  mounted() {
    statsCharts.call(this);
    this.handleEvent('stats', (stats) => statsCharts.call(this, stats));
  },
};

const tokenMeta = document.querySelector("meta[name='csrf-token']");
const csrfToken = tokenMeta && tokenMeta.getAttribute('content');
const liveSocket = new LiveSocket('/live', Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
  dom: {
    // Password-manager extensions (Dashlane, 1Password, Bitwarden, ...)
    // stamp their own data-* attributes onto inputs they have classified.
    // morphdom would strip those on every LiveView patch, making the
    // extension lose track of fields it already analyzed — carry over any
    // data-* attribute the incoming server render doesn't manage itself.
    onBeforeElUpdated(from, to) {
      for (const attr of from.attributes) {
        if (attr.name.startsWith('data-') && !attr.name.startsWith('data-phx') && !to.hasAttribute(attr.name)) {
          to.setAttribute(attr.name, attr.value);
        }
      }
      return true;
    },
  },
});

// Show progress bar on live navigation and form submits
window.addEventListener('phx:page-loading-start', (_info) => NProgress.start());
window.addEventListener('phx:page-loading-stop', (_info) => NProgress.done());

// Live navigation swaps the page without a load: a screen reader hears
// nothing and keyboard focus stays on the clicked link. When the path
// changes, focus the new page's heading (or <main>) so reading starts
// there. Same-path patches (the help unit switch, search) keep focus.
let lastPath = window.location.pathname;
window.addEventListener('phx:navigate', () => {
  const path = window.location.pathname;
  if (path === lastPath) return;
  lastPath = path;
  requestAnimationFrame(() => {
    const main = document.getElementById('main');
    const target = (main && main.querySelector('h1')) || main;
    if (!target) return;
    if (!target.hasAttribute('tabindex')) target.setAttribute('tabindex', '-1');
    // A link to an anchor (help #level-3) keeps its scroll position.
    target.focus({ preventScroll: !!window.location.hash });
  });
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
window.liveSocket = liveSocket;
