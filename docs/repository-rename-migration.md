# Repository rename migration

Rename the web repository to `fkherb/mirrorball-fantasy` and the iOS repository
to `fkherb/mirrorball-fantasy-ios`. Prepare compatibility first, then switch the
website and worker together. Do not change the Supabase project or Apple app IDs.

## Addresses and identifiers

| Item | Before | After |
| --- | --- | --- |
| Web repo | `fkherb/mirrorball-fantasy-league` | `fkherb/mirrorball-fantasy` |
| Website | `https://fkherb.github.io/mirrorball-fantasy-league/` | `https://fkherb.github.io/mirrorball-fantasy/` |
| Privacy policy | Old website + `privacy/` | `https://fkherb.github.io/mirrorball-fantasy/privacy/` |
| Beta information | Old website + `beta/` | `https://fkherb.github.io/mirrorball-fantasy/beta/` |
| Root website repo | `fkherb/fkherb.github.io` | Unchanged |
| Supabase project | `mdrrnanxqazecqviaass` | Unchanged |
| Supabase API | `https://mdrrnanxqazecqviaass.supabase.co` | Unchanged |
| Apple app association ID | `5TXGRKPUC4.com.mirrorball-fantasy` | Unchanged |
| iOS bundle ID | `com.mirrorball-fantasy` | Unchanged |

GitHub redirects repository browsing and Git operations, but not the old Pages
website. Do not create a replacement repository named `mirrorball-fantasy-league`:
that would remove GitHub's repository redirect. Serve old website redirects from
the existing `fkherb.github.io` repo instead.
[GitHub rename documentation](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository).

## Prepared changes

- `repository-location.js` selects the new photo repository when deployed under
  `/mirrorball-fantasy/`; the old deployment and local preview keep the old target.
- The photo script and coordinator accept `DWTS_GITHUB_REPOSITORY` from the
  server's environment. Its absent/default value remains the old repo, so merely
  installing the scripts does not prematurely switch uploads.
- `migration/github-user-site/` contains files for the separate root website
  repo, not files that become active just by publishing the web app.
- Three SQL files provide a read-only preflight, a guarded avatar cutover, and
  a guarded rollback. They do not change schema, roles, scores, invitations, or auth.
- `supabase/config.toml` retains its local project label to avoid accidentally
  changing local Docker resources. That label is not the production project ID.

## Before the rename

### Supabase settings

1. Open [Authentication URL Configuration](https://supabase.com/dashboard/project/mdrrnanxqazecqviaass/auth/url-configuration).
2. Under **Redirect URLs**, add both entries and save:
   - `https://fkherb.github.io/mirrorball-fantasy/`
   - `https://fkherb.github.io/mirrorball-fantasy/**`
3. Keep all existing iOS custom-scheme URLs, local development URLs, and old
   website redirect entries. The wildcard above is limited to this project path.
4. Leave **Site URL** on the current working website until cutover.
5. Run `supabase/repo-rename-preflight.sql` in **SQL Editor → New query**.
   The October 9 check found one old profile avatar and one old team avatar;
   affected counts can change as users update their profiles.

The allowed redirect URL must match the destination requested by the client.
The Site URL is the default destination and is also important for confirmation
and password-reset emails.
[Supabase redirect documentation](https://supabase.com/docs/guides/auth/redirect-urls).

### Root website and app links

In **GitHub → fkherb/fkherb.github.io → Code**, publish these prepared files
at the root of that repo, preserving unrelated files:

- `migration/github-user-site/.nojekyll` → `.nojekyll`.
- `migration/github-user-site/.well-known/apple-app-site-association` →
  `.well-known/apple-app-site-association`.

If the live app-link file has acquired other app IDs or rules, merge the two
Mirrorball invite rules rather than replacing those unrelated entries.
In **Settings → Pages**, verify the user site is still deployed from its
existing source. Do not rename this user-site repo.

Check `https://fkherb.github.io/.well-known/apple-app-site-association` returns
JSON containing both `/mirrorball-fantasy-league/*` and `/mirrorball-fantasy/*`,
both restricted to nonempty `join` queries. Apple caches this file; test links
on a physical device and allow for propagation before assuming failure.
[Apple universal-link troubleshooting](https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links).

Prepare, but do not publish the legacy redirect pages until the new site is live.
Publishing them beforehand would send old links to a nonexistent destination.

### Apple Developer settings

No identifier or sign-in-provider change is required for a repository rename.
In **Apple Developer → Certificates, Identifiers & Profiles → Identifiers**,
check, but do not replace:

- **App IDs → com.mirrorball-fantasy**: existing Sign in with Apple and Associated
  Domains capabilities remain enabled.
- **Services IDs → your existing web sign-in service → Sign in with Apple →
  Configure**: retain its primary app, the Supabase domain
  `mdrrnanxqazecqviaass.supabase.co`, and the return URL
  `https://mdrrnanxqazecqviaass.supabase.co/auth/v1/callback`.

Do not change the Services ID, key, Team ID, bundle ID, or Supabase Apple provider
client IDs/secrets. The provider returns to Supabase, not directly to the Pages
path. The web path changes in Supabase's redirect allowlist instead.
[Apple web sign-in setup](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web/).

### iOS release

Give Claude the handoff below. Prefer shipping the version that accepts both
paths before moving the website. Keep generating old invite URLs until the new
site is actually available; then switch invite generation in the release/config
used for cutover. Existing versions that only accept the old path cannot be
made to accept the new one just by changing the website's association file.

## Rename and switch

Choose a quiet period outside the show's automation window.

1. Publish the prepared web changes to the current repo and verify the old site
   still loads correctly. Publish the app-link file described above.
2. On `codys-server`, pause the worker: `sudo systemctl stop mirrorball-dwts-worker`.
   Do not delete its `.env`, `.worker-state`, pending reports, or photo receipts.
3. In **GitHub → web repo → Settings → General → Repository name**, enter
   `mirrorball-fantasy` and click **Rename**. Use the same setting on the iOS repo
   to rename it to `mirrorball-fantasy-ios`.
4. In the web repo's **Settings → Pages**, retain the existing publishing
   source; verify a successful deployment in **Actions**. Do not change the
   branch or folder unnecessarily. If a rebuild is needed, use the existing
   deployment workflow if it supports manual dispatch, or publish a normal commit.
5. Verify the new homepage, `privacy/`, `beta/`, `score-desk/`, `cast-roster/`,
   cast portraits, dance images, Apple/Google sign-in, and an invite link.
6. In the root `fkherb.github.io` repo, publish the remaining contents of
   `migration/github-user-site/`: `repo-redirect.js`, the
   `mirrorball-fantasy-league/` folder, and `404.html`. If a custom `404.html`
   already exists, preserve its content and add the prepared redirect script
   reference instead of overwriting it. The script redirects only the old
   Mirrorball path; it preserves queries and fragments and cannot redirect to
   an arbitrary external host.
7. Recheck an old invite, old privacy URL, and old beta URL in Safari. These are
   browser redirects, not HTTP server redirects. Old image URLs are not fixed by
   redirect HTML; the database URL cutover below fixes the known stored avatars.
8. Update **Supabase → Authentication → URL Configuration → Site URL** to
   `https://fkherb.github.io/mirrorball-fantasy/`, save, and keep both web paths
   and all iOS callbacks in Redirect URLs.
9. In **Authentication → Email Templates**, inspect each customized template.
   Replace literal old website addresses only. Templates using `.SiteURL` or
   `.RedirectTo` should not need a hardcoded URL replacement. Keep the auth
   verification/confirmation links intact.
10. After the new avatar images load, open `supabase/repo-rename-avatar-cutover.sql`
    in **SQL Editor → New query**, change the readiness setting from `'no'` to
    `'yes'`, and run the whole file. It updates only exact old Pages avatar
    prefixes, preserving each image path, query, and fragment. Rerun the preflight;
    old avatar counts should be zero. No other SQL is required for this rename.
11. Install the two updated worker scripts and change its repo setting as below.
12. Update App Store Connect metadata as below and verify the iOS release is
    generating the new invite URLs.

### Server worker

On the server, back up the existing `dwts-photos.py` and `dwts-worker.py` before
replacing them. Keep the existing virtual environment and credentials.
From the web repo on your Mac, copy only these two prepared scripts:

```sh
scp scripts/Automations/dwts-photos.py scripts/Automations/dwts-worker.py fkherb@codys-server:/home/fkherb/scripts/mirrorball-fantasy/
```

On `codys-server`, edit `/home/fkherb/scripts/mirrorball-fantasy/.env` and add or
replace exactly this non-secret setting:

```dotenv
DWTS_GITHUB_REPOSITORY=fkherb/mirrorball-fantasy
```

Keep `SUPABASE_URL`, `DWTS_AUTOMATION_WORKER_SECRET`, `DWTS_PHOTOS_GITHUB_TOKEN`,
and `DWTS_WORKER_NAME` unchanged. In **GitHub → Settings → Developer settings →
Personal access tokens → Fine-grained tokens → your photo token**, verify that
the renamed repository is still selected and **Repository permissions →
Contents** remains **Read and write**. Do not rotate a working token just for
the rename. Verify classic-token access too if that is the token type in use.

On the server:

```sh
/home/fkherb/scripts/mirrorball-fantasy/.venv/bin/python /home/fkherb/scripts/mirrorball-fantasy/dwts-worker.py --check
sudo systemctl start mirrorball-dwts-worker
sudo systemctl status mirrorball-dwts-worker --no-pager
```

The authentication check does not download/upload photos or import wiki data.
Normal jobs remain scheduled and supplied by Supabase. The server folder name
and systemd service name do not need to change. Verify a future real upload
targets the renamed repo; do not force an unnecessary live X scan during cutover.

### Git remotes

Run inside each respective local clone, including any server clones:

```sh
# Web clone
git remote set-url origin https://github.com/fkherb/mirrorball-fantasy.git
# iOS clone
git remote set-url origin https://github.com/fkherb/mirrorball-fantasy-ios.git
```

The local folder names can stay unchanged. Existing repo-level GitHub secrets
do not need to be copied into a new repo because this is a rename, not a new repo.
If Supabase **Project Settings → Integrations** has a GitHub deployment/branching
connection, check its repo selection after the rename; no new Supabase project
is needed. This static website's inspected workflows do not hardcode the old repo.

## App Store Connect settings

After the new URLs load, open **App Store Connect → Apps → your existing app**:

- **App Store → App Privacy → Privacy Policy → Edit**: set Privacy Policy URL
  to `https://fkherb.github.io/mirrorball-fantasy/privacy/`; save. Leave privacy
  disclosure answers unchanged unless the app's data practices actually changed.
- **App Store → iOS app version → localized version information**: update
  Marketing URL to `https://fkherb.github.io/mirrorball-fantasy/` if populated.
  If Support URL already points to the old website, update its path too; use
  `https://fkherb.github.io/mirrorball-fantasy/beta/` if choosing the existing
  beta/help page. Preserve any separately hosted support URL.
- **TestFlight → Test Information**: update Marketing URL, Privacy Policy URL,
  and any old website links in Beta App Description or review notes where
  present. Keep Feedback Email `mirrorball-fantasy@codys-server.net`, demo login
  credentials, and existing tester groups unchanged.
- If **Xcode Cloud** is configured, check its workflow's source-repository
  connection after the rename. Do not create another app record.

[Apple privacy settings](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
and [TestFlight test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/).

For Google sign-in, the Supabase callback and origin remain unchanged. In
**Google Cloud Console → Google Auth Platform → Branding**, update app homepage
or privacy links only if they contain the old path. Do not replace the working
OAuth client or the Supabase callback in **Clients**.

## Claude iOS handoff

Prepare the iOS repo for its rename to `mirrorball-fantasy-ios` and the web repo's
rename from `mirrorball-fantasy-league` to `mirrorball-fantasy`. Do not rename
Apple identifiers or replace backend credentials.

1. Centralize the website base URL. The new base is
   `https://fkherb.github.io/mirrorball-fantasy/`; retain the legacy base for
   invite recognition. Accept only HTTPS links with exact host `fkherb.github.io`,
   a supported Mirrorball project path, and a nonempty `join` parameter. Preserve
   the current token-validation rules; reject lookalike domains, unrelated
   project paths, empty/malformed/ambiguous tokens, and duplicated `join` values.
2. Keep generating working old-path links until cutover; prepare an explicit
   release/config switch to generate new-path invite links after the new site
   is live. Both path formats must remain accepted after that switch. Continue
   to share the full invite message, name, code, and link.
3. Preserve deferred-invite handling through sign-in and profile setup,
   Join/Not now confirmation, and switching to an already-joined league.
   Do not auto-join merely because a URL was opened.
4. Search all source, tests, configuration, assets, and documentation for old
   GitHub Pages, GitHub API, and raw-content URLs. Prepare updates for website,
   privacy, beta/help, cast/dance images, and any repo-based downloads. Use the
   renamed web repo for image URLs at cutover, not the renamed iOS repo.
5. Keep bundle ID `com.mirrorball-fantasy`, Team ID `5TXGRKPUC4`, existing Services
   ID, Sign in with Apple capability, Associated Domains `applinks:fkherb.github.io`,
   URL schemes, keychain groups, and production Supabase URL/keys unchanged.
   Leave all working auth redirect URIs unchanged. If any working auth redirect
   actually uses the old HTTPS website path, report it before changing it.
6. Do not change scoring, dynamic roster limits, draft rules, or database RPCs.
7. Add unit tests for old/new invite URLs, fragments/other query parameters,
   rejected hosts/paths/protocols, empty/duplicate tokens, and generated share
   links before/after the URL switch. Run the existing backend and app tests.
8. Build in Xcode, run tests, bump the build number, and prepare TestFlight.
   Manually test old and new links tapped in Notes/Messages on a physical device,
   signed in/out, before/after profile setup, and already in the league.
   Without the app installed, links must fall back to the website.
9. Update this clone's Git remote to
   `https://github.com/fkherb/mirrorball-fantasy-ios.git` only after its rename.
   Do not publish new-path links before the new site exists. Report any stored
   absolute URLs or build services requiring manual changes.

## Checks and rollback

Run `npm run check`, `npm run check:migration`, `npm run check:automation`, and
the Python automation tests before publishing. Migration tests cover both photo
repo paths, app-link rules, and legacy redirects preserving invite queries and
auth fragments. They do not substitute for device testing or a real photo upload.

For an emergency rollback, first restore the old website/repo name and pause the
worker. Remove/disable the old-path redirect pages in the user-site repo, reset
the worker's `DWTS_GITHUB_REPOSITORY` to `fkherb/mirrorball-fantasy-league`, and
restore the old Supabase Site URL. Leave both app-link/redirect allowlist paths
in place. Only after old avatar images load, set the guard to `'yes'` in
`supabase/repo-rename-avatar-rollback.sql` and run it. It changes only new Pages
avatar prefixes back to old ones; it does not restore unrelated user data.
