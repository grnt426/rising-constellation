# Signup & email security — posture and deferred backlog

Status as of 2026-08-20, written at the open-signup checkpoint. The first
section is the implemented posture (quick reference); the second is the
deferred hardening backlog, with enough detail to implement each item in
a fresh session.

## Implemented posture

Open signup flow: `POST /api/accounts` creates the account as
`:registered`, sends a verification email (AWS SES, templates in
`RC.Accounts.Emails`), and the account stays read-only until the link is
clicked (`Portal.Plug.VerificationGate` allows only own-profile CRUD and
account settings). `POST /api/accounts/validate` flips to `:active`.
Invite tokens are optional referral credit only.

| Control | Where |
| --- | --- |
| Password policy (min 8 / max 128, Argon2, length-DoS guard) | `Account.changeset_password` |
| Disposable-email blocklist | `email_guard` inside `Account.validate_email` |
| Per-IP signup limit (10/hour) | `Portal.Plug.RateLimit` in `AccountController` |
| Per-IP reset/resend limit (5/hour, shared bucket) | same |
| Per-recipient email cap (3/address/day on reset + resend) | `AccountController.recipient_allowed?/1` |
| Unverified-account expiry (7 days, frees squatted emails/names) | `RC.Accounts.purge_stale_unverified_accounts/0`, run by `DeletionSweeper`; `config :rc, RC.Accounts, unverified_expiry_days:` |
| Single-use, short-lived tokens (2h verification, 1h deletion) | `AccountToken` + `validity_overrides` |
| Bounce/complaint suppression | SES account-level suppression + config set `rc-transactional` → SNS `rc-mail-events` |
| Session revocation on password change/ban/deletion | `token_version` ("tv") claim |

Threat notes:

- **Pre-registration squatting** (attacker signs up with a victim's
  email): the squatted account is read-only and expires in 7 days, after
  which the real owner can register normally. The verification email
  tells non-requesters to ignore it.
- **Mail bombing third parties through our forms**: signup sends at most
  one email per address (uniqueness), reset/resend are capped at
  3/address/day regardless of source IP.

## Deferred backlog

### 1. Cloudflare Turnstile on the signup form

CAPTCHA replacement; blocks scripts that POST `/api/accounts` directly.
Needs a free Cloudflare account (does NOT require moving DNS): create a
Turnstile widget to get a sitekey (public) and secret key.

Implementation sketch:

- Frontend: add the Turnstile script + widget div to the signup forms in
  `lib/portal/live/public/signup_live.html.leex` and
  `landing_live.html.leex`. The widget drops a `cf-turnstile-response`
  token into the form; `Hooks.signup` in `assets/js/app.js` includes it
  in the POST body.
- Backend: in `AccountController.create`, before the transaction, POST
  `{secret, response, remoteip}` to
  `https://challenges.cloudflare.com/turnstile/v0/siteverify` and check
  `"success": true`. Secret via env (`TURNSTILE_SECRET_KEY`), sitekey
  baked into the page. Skip verification when the secret is unset so dev
  and tests work unchanged; fail closed in prod when it is set.

### 2. DMARC: p=none → p=quarantine (calendar item, no code)

The DNS record `_dmarc.tetrarchyfalls.com` currently publishes `p=none`
(monitor only), so a spoofer sending mail "from" tetrarchyfalls.com is
not yet penalized. After ~2 weeks of clean sending (check the DMARC
reports forwarded to dmarc@ → Gmail), update the TXT record in Route 53
(zone `Z048433317P04YGE3QXLJ`) to `v=DMARC1; p=quarantine; rua=...`,
and later `p=reject`. One `aws route53 change-resource-record-sets`
call.

### 3. Reclaim-unverified-on-signup (optional)

Today a signup colliding with an *unverified* account errors "email has
already been taken" until the 7-day expiry frees it. Stronger variant:
when the only account holding an address is `:registered`, let a new
signup replace it (reset name/password to the new registrant's values,
delete old tokens, issue a fresh verification token). The mailbox click
is the true arbiter of ownership, so this is safe and removes the 7-day
wait for legitimate owners. Touches `AccountController.create` + a
replace transaction in `RC.Accounts`.

### 4. Bounce feedback into the app

Today a bounced verification email is invisible to the app: SES
suppresses the address and SNS notifies the operator's Gmail, but the
user just sees "check your email / resend" forever. Wire it in:

- Subscribe an HTTPS endpoint (e.g. `POST /api/mail/events`) to the SNS
  topic `rc-mail-events` (SNS subscription confirmation handshake, then
  notification JSON with `notificationType: "Bounce" | "Complaint"`).
- On a hard bounce, stamp the account (e.g.
  `email_delivery_failed_at`) and have the portal banner switch from
  "resend" to "we couldn't deliver to this address — sign up again with
  a working one" (the expiry sweep frees the dead account).
- Verify SNS message signatures (or restrict by topic ARN check) before
  trusting payloads.

### 5. Enumeration hardening

`POST /api/accounts` answers "email has already been taken", and
reset/resend responses differ for unknown addresses, so anyone can test
whether an address has an account. Standard fix: uniform "done"
responses everywhere; on signup-collision send an email to the existing
address ("you already have an account, reset your password here")
instead of erroring. Interacts with the per-recipient cap (those
courtesy emails must count against it). Lower priority for a game;
listed for completeness.

### 6. Misc smaller items

- The `auth_pwreset` per-IP bucket is shared between password-reset and
  resend-verification; splitting them gives each 5/hour instead of a
  combined budget.
- `test/portal/controllers/profile_controller_tests.exs` is misnamed
  (`_tests.exs`, never runs) and contains a compile-breaking typo;
  resurrect or delete.
- Consider a `Retry-After`-aware toast in the SPA for 429 responses
  (currently generic error).
