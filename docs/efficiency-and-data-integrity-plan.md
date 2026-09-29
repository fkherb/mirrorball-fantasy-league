# Live-season efficiency and data-integrity plan

This plan reviews the 2026-09-29 audit against the current repository. Keep the original league on its existing scoring path until the season ends; a mid-season migration risks changing historical standings. The two league models are a temporary, documented boundary, not a pattern for new features.

## Implemented locally in this pass

- Pin the browser Supabase client to an exact version (F14).
- Fix Stars showing Past wins in secondary-league profiles (F1 symptom).
- Make Edit rates independent of loading the Dances view (F11).
- Cache original-league roster data while searching and filtering; invalidate after cast/week changes (F5).
- Show SQLSTATE `P0001` validation messages for confirmations and trades, while keeping other errors generic (F7).
- Run the three previously omitted checks in CI (F21).
- Add a repeatable cache-key bump command and use it for this deploy (F15).
- Keep inactive partnerships in historical scoring, dance names, and profile links. A new SQL patch flips `active` off on elimination, retains the relationship row, and prevents later edits from accidentally reactivating an eliminated couple.
- Remove the commissioner's ability to change another manager's display name in both the UI and a database patch. Managers retain their own account-profile editor.
- Add a separate database patch to restrict profile-directory reads to the account owner, current league peers, and owners viewing their pending invitees (F12). Public league rosters still come from `list_league_members`.

The SQL files are **prepared, not applied**. Apply and verify them separately in a controlled Supabase session; do not assume a front-end deploy installs database changes.

## Database deployment order and checks

1. Save a verified schema-only dump from the **repository root** to `supabase/migrations/` as the authoritative baseline (F3). Check that it is nonempty and includes `complete_week`, profile policies, and the current league functions. Do not reconstruct production from the old `schema.sql`. The audit's claimed nested zero-byte `supabase/supabase` directory is not present in the current checkout; the missing baseline is still real.
2. Apply `supabase/align-eliminated-partnerships-and-member-names.sql`. Before and after, record the IDs and count of pairs whose star or pro has an eliminated role but `active=true`. The after count must be zero; the count of partnership rows and historical competitive dances must be unchanged. Verify a completed week's fantasy totals, an eliminated cast profile/partner link, and the current prediction filter. Confirm that a commissioner cannot call `update_team_profile_from_profile` with someone else's ID or use the legacy wrapper to change their display name.
3. Apply `supabase/restrict-profile-directory.sql`. From an anonymous session, `profiles` and `profile_directory` must return no rows. From a member account, test self, a league peer, and a non-peer. From an owner account, test a pending invitee. Test exact-username invitations and public league member display via `list_league_members`. Confirm a user can still save their own account profile through `update_my_profile` but cannot PATCH `profiles` directly.
4. Count private snapshots with `select league_id, count(*) from public.league_weekly_roster_snapshots group by league_id;` in the owner SQL editor; public-key access is correctly denied. The public counts on 2026-09-29 were 108 `dance_appearances`, 90 `dance_judge_scores`, 55 `dances`, and 88 `weekly_roster_snapshots`. These are not near 1,000. Add pagination before any individual read approaches ~600, and repeat the check monthly (F4).

## Next live-season improvements, in payoff order

1. **Images (F16, F17):** generate ~320 px WebP cast thumbnails, use full portraits only in profile heroes, add lazy loading to offscreen tiles, and compress dance images to ~1600 px WebP. Measure transfer size on a phone before/after. Use a generated dance-photo manifest keyed by stable dance IDs once IDs can be maintained safely; defer a Storage/admin upload UI until it actually saves time. Do not rewrite existing Git history just to shrink old photos.
2. **Scoring confidence (F2, F21):** extract the secondary league's `scoreLeague` into a pure module and add fixture tests covering competitive scores, appearances, eliminated-role rates beginning the next week, guest judges, frozen roster/rate snapshots, and a missing snapshot. Add a parity fixture for original-league totals without replacing that live path. Keep SQL rate snapshots: they freeze historical rates and are not redundant scoring code.
3. **Privacy and avatars (F13):** after checking all existing avatar URLs, restrict new URLs to owned Storage paths (or a known first-party cast origin). Use a fixed/upserted avatar path or remove the old object after a successful replacement. This is worthwhile but lower urgency than directory enumeration.
4. **Small operational cleanup (F6, F7, F11):** measure the 30-second workspace refresh before splitting it; avoid refreshing snapshots on every view if triggers and week completion fully cover capture. Move remaining `P0001` handling into one helper and replace the legacy alert override gradually. Remove only proven-dead migration probes/RPCs.

## Season-end architecture decision

After the finale, freeze writes and export week/team totals. Choose either a read-only archive of the original league or a backfill into `league_*`; if backfilling, compare every team's weekly and season total before changing the route (F1). Then remove the old-only RPCs/columns and duplicate score path (F2, F9, F11), decide how `seasons` scope weeks/cast/leagues before entering the next cast (F18), and make platform-default rates separate from one league's rates if those defaults are not intentionally shared (F23).

Do not split `app.js` (F8), add a session module (F19), move all rules/scoring to SQL (F10/F2B), or delete broad CSS groups (F20) merely for architectural tidiness during this live season. Those changes become smaller or unnecessary after the original path is retired. Keep the present Score Desk direct-write/RPC mix (F22) unless a concrete failed validation appears; then add a targeted database constraint or RPC. For iOS/passkeys, revisit shared rule/scoring APIs and move to a custom domain before issuing domain-bound passkeys.
