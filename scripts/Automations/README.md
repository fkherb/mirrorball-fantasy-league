# DWTS automation runner

The `Verify DWTS automation runner` GitHub workflow installs a pinned `gallery-dl`
release on an Ubuntu runner, checks the actual photo worker entry point, and runs
without a secret on pushes to `main`. It does not download or upload photos.

To enable the optional live-source **dry run**, create a fine-grained GitHub personal
access token scoped to `fkherb/mirrorball-fantasy-league` with **Contents: Read and
write**. In the repository on GitHub, open **Settings → Secrets and variables →
Actions → New repository secret**. Name it `DWTS_PHOTOS_GITHUB_TOKEN` and paste the
token there. Never put the token in workflow inputs, a command, or a committed file.
Then open **Actions → Verify DWTS automation runner → Run workflow**, enable
`photo_dry_run`, and enter a week, couple names, and (optionally) the airing date.
The dry run reads X and GitHub but does not upload photos or save script state.

The photo script reads `DWTS_GITHUB_TOKEN` from its environment. The older
`--git-token` argument still works for local callers, but is not used by the
workflow. `dwts-wiki.py` is read-only and does not update Supabase.

This is a runner check, not the unattended show schedule. A hosted runner loses its
local filesystem after each job, so real photo runs must first persist
`DWTS_STATE` somewhere durable. The show scheduler and database ingestion also
need to be implemented and tested before enabling unattended writes.
