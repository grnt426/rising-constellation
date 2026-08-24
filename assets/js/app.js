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
const APIHeaders = {
  Accept: 'application/json',
  'Content-Type': 'application/json',
};

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
      const infoContainer = document.getElementById('info-container');
      const info = document.getElementById('info');
      try {
        await fetch('/api/accounts/validate', {
          method: 'POST',
          headers: APIHeaders,
          body: JSON.stringify({ token }),
        });

        infoContainer.style.display = 'block';
        info.innerHTML = 'Your account has been validated.';
      } catch (_err) {
        infoContainer.style.display = 'block';
        info.innerHTML = 'Account confirmation error.';
      }
    }

    // Account deletion is confirmed by an explicit button press (never on
    // page load, so an email scanner following the link cannot trigger it).
    if (action === 'confirm-deletion' && token) {
      const container = document.getElementById('deletion-confirm-container');
      const body = document.getElementById('deletion-confirm-body');
      const button = document.getElementById('deletion-confirm-button');
      container.style.display = 'block';

      button.addEventListener('click', async () => {
        button.disabled = true;
        try {
          const resp = await fetch('/api/accounts/confirm-deletion', {
            method: 'POST',
            headers: APIHeaders,
            body: JSON.stringify({ token }),
          });
          const data = await resp.json();
          if (!resp.ok) throw new Error(data.message || 'error');
          button.style.display = 'none';
          body.innerHTML = `<p>Your account is now locked and will be permanently deleted in ${data.grace_days} days.</p>`
            + '<p>You can log back in at any time before then to cancel the deletion.</p>';
        } catch (_err) {
          button.style.display = 'none';
          body.innerHTML = '<p>This deletion link is invalid or has expired.</p>'
            + '<p>If you still want to delete your account, log in and request deletion again.</p>';
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
      const info = document.getElementById('info');
      const button = document.getElementById('button');

      button.disabled = true;

      const email = document.getElementById('email').value;
      const name = document.getElementById('name').value;
      const password1 = document.getElementById('password1').value;
      const password2 = document.getElementById('password2').value;
      const inviteToken = this.el.dataset.inviteToken;

      const errors = [];
      if (!email) errors.push('Email address is required.');
      if (!name) errors.push('Name is required.');
      if (!password1) {
        errors.push('Password is required.');
      } else if (password1 !== password2) {
        errors.push('Passwords do not match.');
      }

      if (errors.length === 0) {
        const password = password1;

        try {
          // Deliberately vague: the user just sees a short "Validating…"
          // while the proof-of-work challenge is being solved.
          infoContainer.style.display = 'block';
          infoContainer.classList.remove('is-error', 'is-success');
          info.innerHTML = '<span class="pow-spinner"></span> Validating…';

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
          infoContainer.style.display = 'block';

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
            info.innerHTML = successMessages[message];
            document.getElementById('email').value = '';
            document.getElementById('name').value = '';
            document.getElementById('password1').value = '';
            document.getElementById('password2').value = '';
          } else if (errorMessages[message]) {
            infoContainer.classList.remove('is-success');
            infoContainer.classList.add('is-error');
            info.innerHTML = errorMessages[message];
            button.disabled = false;
          } else {
            infoContainer.classList.remove('is-success');
            infoContainer.classList.add('is-error');
            if (message && typeof message === 'object') {
              // Changeset field errors: {"email": ["has invalid format"], ...}
              info.innerHTML = Object.entries(message)
                .map(([field, msgs]) => `${field} ${Array.isArray(msgs) ? msgs.join(', ') : msgs}`)
                .join('<br>');
            } else if (resp.status >= 500) {
              info.innerHTML = `Something went wrong on our side (error ${resp.status}). `
                + 'Please try again later.';
            } else {
              info.innerHTML = 'Account creation failed. Please check the form and try again.';
            }
            button.disabled = false;
          }
        } catch (_err) {
          infoContainer.style.display = 'block';
          infoContainer.classList.remove('is-success');
          infoContainer.classList.add('is-error');
          info.innerHTML = 'Internal error (contact the site administrators).';
          button.disabled = false;
        }
      } else {
        infoContainer.style.display = 'block';
        infoContainer.classList.add('is-error');
        info.innerHTML = errors.join('<br>');
        button.disabled = false;
      }
    });
  },
};

Hooks.requestPassword = {
  mounted() {
    this.el.addEventListener('submit', async (e) => {
      e.preventDefault();

      const infoContainer = document.getElementById('info-container');
      const info = document.getElementById('info');
      const button = document.getElementById('button');

      button.disabled = true;

      const email = document.getElementById('email').value;

      if (email !== '') {
        try {
          const resp = await fetch('/api/accounts/request-password-reset', {
            method: 'POST',
            headers: APIHeaders,
            body: JSON.stringify({ email }),
          });

          infoContainer.style.display = 'block';
          if (resp.status === 429) {
            info.innerHTML = retryAfterMessage(resp);
            button.disabled = false;
          } else {
            // Uniform wording — the backend answers the same whether or
            // not the address has an account (no enumeration).
            info.innerHTML = 'If an account exists for this address, a password reset link is on its way.';
          }
        } catch (_err) {
          infoContainer.style.display = 'block';
          info.innerHTML = 'Error in the request.';
          button.disabled = false;
        }
      } else {
        button.disabled = false;
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

      const infoContainer = document.getElementById('info-container');
      const info = document.getElementById('info');
      const button = document.getElementById('button');

      button.disabled = true;

      const password = document.getElementById('password').value;

      if (password) {
        try {
          const resp = await fetch('/api/accounts/reset-password', {
            method: 'POST',
            headers: APIHeaders,
            body: JSON.stringify({ token: validateTokenPassword, new_password: password }),
          });
          if (!resp.ok) {
            throw new Error('Error');
          }
          infoContainer.style.display = 'block';
          info.innerHTML = 'Your password has been changed.';
          setTimeout(() => {
            const url = new URL(window.location.href);
            url.pathname = '/login';

            window.location.replace(url.href);
          }, 2000);
        } catch (_err) {
          infoContainer.style.display = 'block';
          info.innerHTML = 'Error in the request.';
          button.disabled = false;
        }
      } else {
        button.disabled = false;
      }
    });
  },
};

Hooks.webBind = {
  mounted() {
    const button = document.getElementById('button');
    button.disabled = true;

    const passwordField = document.getElementById('password');
    const confirmField = document.getElementById('password-confirmation');

    confirmField.addEventListener('keyup', () => {
      if (confirmField.value === passwordField.value) {
        button.disabled = false;
      } else {
        button.disabled = true;
      }
    });

    this.el.addEventListener('submit', async (e) => {
      e.preventDefault();

      const infoContainer = document.getElementById('info-container');
      const info = document.getElementById('info');

      button.disabled = true;

      const password = document.getElementById('password').value;

      if (password) {
        try {
          const resp = await fetch('/api/accounts/bind', {
            method: 'POST',
            headers: APIHeaders,
            body: JSON.stringify({ token: validateTokenPassword, new_password: password }),
          });
          if (!resp.ok) {
            throw new Error('Error');
          }
          infoContainer.style.display = 'block';
          info.innerHTML = 'Your password has been saved.';

          setTimeout(() => {
            const url = new URL(window.location.href);
            url.pathname = '/login';

            window.location.replace(url.href);
          }, 2000);
        } catch (_err) {
          infoContainer.style.display = 'block';
          info.innerHTML = 'Error in the request.';
          button.disabled = false;
        }
      } else {
        button.disabled = false;
      }
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

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
window.liveSocket = liveSocket;
