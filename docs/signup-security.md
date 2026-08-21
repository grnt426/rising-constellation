# Signup & email security — posture and remaining work

Status as of 2026-08-20 (second pass — the deferred backlog from the
open-signup checkpoint is now implemented, except where noted under
"Remaining"). First section is the implemented posture (quick reference);
second is the deploy-time ops checklist for the new pieces; third is what
deliberately remains.

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
| Proof-of-work captcha on signup (ALTCHA protocol, self-hosted) | `Portal.Captcha` + `GET /api/captcha` + solver in `assets/js/app.js`; enabled by `CAPTCHA_HMAC_KEY` |
| Per-IP signup limit (10/hour) | `Portal.Plug.RateLimit` in `AccountController` |
| Per-IP reset/resend limit (5/hour, shared bucket) | same |
| Per-IP captcha-challenge limit (30/hour) | `CaptchaController` |
| Per-recipient email cap (3/address/day on reset + resend + collision emails) | `AccountController.recipient_allowed?/1` |
| Unverified-account expiry (7 days, frees squatted emails/names) | `RC.Accounts.purge_stale_unverified_accounts/0`, run by `DeletionSweeper`; `config :rc, RC.Accounts, unverified_expiry_days:` |
| Reclaim-unverified-on-signup (no 7-day wait for the real owner) | `RC.Accounts.run_reclaim_signup_transaction/4` |
| Enumeration hardening (uniform responses on signup/reset/resend) | `AccountController` — see below |
| Single-use, short-lived tokens (2h verification, 1h deletion) | `AccountToken` + `validity_overrides` |
| Bounce/complaint suppression | SES account-level suppression + config set `rc-transactional` → SNS `rc-mail-events` |
| Bounce feedback into the app (hard bounce → banner switch) | `POST /api/mail/events` (`Portal.MailEventsController` + `Portal.SnsMessage`), `accounts.email_delivery_failed_at` |
| Session revocation on password change/ban/deletion | `token_version` ("tv") claim |

### Proof-of-work captcha (replaces the old Turnstile plan)

Cloudflare Turnstile was dropped over data-sharing concerns; the
replacement is fully self-hosted (ALTCHA protocol, official `altcha` hex
lib server-side, ~30 lines of SubtleCrypto in the signup hook client-side
— no widget, no external calls, no cookies). Flow:

1. Signup hook shows "Validating…" and fetches `GET /api/captcha`
   (`{"enabled": false}` when off → hook skips straight to the POST).
2. Browser brute-forces SHA-256(salt+number) == challenge in concurrent
   batches (max_number 50k ≈ 1.2s average on desktop), POSTs the base64
   payload as `captcha`.
3. `Portal.Captcha.verify/1` checks well-formedness (key whitelist —
   guards the lib's `String.to_atom`), expiry (in-house — the lib's V1
   `check_expires` branch discards its own result), HMAC/hash, then
   claims one-time use in `Portal.Captcha.UsedChallenges` (ETS ledger,
   not Hammer — fixed windows would admit replays across bucket edges).

Tuning: `config :rc, Portal.Captcha` (`max_number`, `expires_s`).
Enabled only when `CAPTCHA_HMAC_KEY` is set; dev/test run with it off.

### Signup collision behavior (enumeration + reclaim)

`POST /api/accounts` answers `:signup_complete` (201) for every valid
submission, taken address or not:

- address free → normal signup;
- address held by an **unverified** (`:registered`, non-Steam, non-bot)
  account → the squatter row is replaced wholesale in one transaction
  (`run_reclaim_signup_transaction/4` — deletes mirroring the purge
  sweep, then the standard signup insert + fresh token + email). The
  mailbox click is the ownership arbiter, so the real owner never waits
  out the 7-day expiry. Accepted edge (2026-08-20): an attacker can
  repeatedly re-reset a not-yet-verified account; livable until abuse is
  seen, and the per-recipient cap bounds the mail volume;
- address held by anything else → courtesy "you already have an account /
  reset your password" email (`:existing_account_template`) to the
  existing owner, same 201 to the caller.

Invalid params return the same changeset errors in every branch (the
collision paths validate first), so error shapes don't leak email state
either. Collision-path emails are attacker-repeatable, so both consume
the 3/day per-recipient cap — once capped, the response stays uniform
but nothing is sent. First-signup verification mail is exempt (bounded
to one send by uniqueness itself).

Reset (`request-password-reset`) and resend (`request-email-verification`)
always answer 200 with their usual message, known address or not; the
LiveView pages phrase it as "if an account exists…". 429s remain (IP /
recipient caps — they reveal request volume, not account existence).

### Bounce feedback

SNS (`rc-mail-events`) posts to `POST /api/mail/events` (`text/plain`
JSON — our Plug.Parsers passes it through; the controller reads the raw
body). Every message must name the configured `topic_arn` AND carry a
valid SNS signature (`Portal.SnsMessage`: cert URL restricted to
`https://sns.*.amazonaws.com`, RSA verify over the canonical string,
cert cached in persistent_term). `SubscriptionConfirmation` is confirmed
automatically (SubscribeURL follows the same AWS-host check). A
`Permanent` bounce stamps `accounts.email_delivery_failed_at`; the
portal's verify-email banner then switches from "resend" to "sign up
again with a working address" (the expiry sweep frees the dead account).
Complaints are logged only.

This makes the app the bounce consumer — the SNS→Gmail email
subscription can be dropped once the HTTPS subscription is live, so
bounce storms never hit a human inbox (the operator concern that
motivated a possible `bounced@` alias; no alias needed).

## Deploy-time ops checklist (one-time)

0. **Get SES out of the sandbox** (`aws sesv2 get-account` →
   `ProductionAccessEnabled` must be true — still false as of
   2026-08-21). In the sandbox SES only delivers to verified
   identities, so every real-world signup's verification email is
   rejected (surfaced as `email_send_failed` / "we could not send the
   confirmation email"). The production-access questionnaire reply is
   drafted — send it. Until approved, test signups only work with
   addresses verified in SES.
1. `CAPTCHA_HMAC_KEY=<long random string>` into `/etc/rc/env`
   (`openssl rand -hex 32`). Unset = captcha silently off.
2. `SNS_MAIL_EVENTS_TOPIC_ARN=<arn of rc-mail-events>` into
   `/etc/rc/env`.
3. Deploy (runs the `email_delivery_failed_at` migration).
4. Create the SNS HTTPS subscription:
   `aws sns subscribe --topic-arn <arn> --protocol https
   --notification-endpoint https://tetrarchyfalls.com/api/mail/events`
   — the app auto-confirms (check logs for "SNS subscription
   confirmed").
5. After a test bounce round-trips, delete the SNS→Gmail email
   subscription for bounces (keep whatever complaint alerting feels
   right — complaints are rare and worth human eyes).

## Remaining

### DMARC: p=none → p=quarantine (calendar item, no code)

`_dmarc.tetrarchyfalls.com` publishes `p=none` (monitor only). The
"~2 weeks" is not a protocol requirement — it's the observation window
for the rua aggregate reports (daily digests from Gmail/Microsoft/etc.)
to prove every legitimate sending path aligns before receivers are told
to junk failures. Our outbound surface is exactly one path (SES with
DKIM), so the risk is low; wait for the first clean reports covering all
mail types (verification, reset, deletion), then flip the TXT record in
Route 53 (zone `Z048433317P04YGE3QXLJ`) to `v=DMARC1; p=quarantine;
rua=...`, later `p=reject`. Earliest sensible flip: ~2026-09-03.

### Smaller items, deliberately kept

- The `auth_pwreset` per-IP bucket stays shared between password-reset
  and resend-verification (decision 2026-08-20: volume doesn't justify
  splitting).
- SPA-side `Retry-After` toast: the public pages (signup, forgotten
  password) now show "try again in ~N minutes" from the header; the
  in-portal resend button still uses the generic error toast.
