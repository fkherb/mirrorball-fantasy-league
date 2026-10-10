// Owner-only presentation; all authorization and scheduling remain in SQL.
export const automationModes = [
  ['pre-show', 'Dance types & songs'], ['live-show', 'Judges’ scores'],
  ['post-show', 'Elimination results'], ['photos', 'Couple photos'],
];
const escape = (value = '') => String(value ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const date = (value) => value ? new Date(value).toLocaleString('en-US', {timeZone:'America/New_York',month:'short',day:'numeric',hour:'numeric',minute:'2-digit'}) + ' ET' : 'Not yet';

export function judgeOrderFields(guest, order = []) {
  if (!guest) return '<p class="sub">Regular judge order: Carrie Ann → Derek → Bruno.</p>';
  const names = ['Carrie Ann', 'Derek', 'Bruno', guest];
  return `<div class="automation-judge-order">${names.map((_, index) => `<label>Judge ${index + 1}<select data-automation-judge><option value="">Select judge</option>${names.map((name) => `<option value="${escape(name)}" ${order[index] === name ? 'selected' : ''}>${escape(name)}</option>`).join('')}</select></label>`).join('')}</div><p class="sub">Match the order of scores in Wikipedia’s table, not the seating order.</p>`;
}

export function automationFields(data, guest) {
  if (!data) return '<section class="week-automation"><p>Automation controls unavailable. Run add-score-desk-automation-controls.sql, then reload.</p></section>';
  const settings = data.settings || {};
  const modes = settings.modes || ['get-weeks', 'pre-show'];
  return `<fieldset class="week-automation"><legend>Automation</legend>
    <label class="check-label"><input id="weekAutomationEnabled" type="checkbox" ${settings.enabled ? 'checked' : ''}> Enable automation for this week</label>
    <div class="automation-mode-grid">${automationModes.map(([mode, label]) => `<label class="check-label"><input data-automation-mode="${mode}" type="checkbox" ${modes.includes(mode) ? 'checked' : ''}> ${label}</label>`).join('')}</div>
    <p class="sub">Saved with the week. Pausing prevents new jobs; an already-running job may finish. Completing the week remains manual.</p>
    <details><summary>Wikipedia source & judge order</summary>
    <label class="check-label"><input id="weekWikiAutomatic" type="checkbox" ${!settings.wiki_tag_override ? 'checked' : ''}> Discover the Wikipedia week tag automatically</label>
    <label id="weekWikiTagField" ${settings.wiki_tag_override ? '' : 'hidden'}>Wikipedia week tag<input id="weekWikiTag" maxlength="250" value="${escape(settings.wiki_tag || '')}" placeholder="#Week_4:_Mariah_Carey_Night"></label>
    <p class="sub">Current tag: ${escape(settings.wiki_tag || 'Waiting for discovery')}</p>
    <div id="weekAutomationJudgeOrder">${judgeOrderFields(guest, settings.judge_order || [])}</div>
    </details></fieldset>`;
}

export function readAutomationFields(root, guest) {
  const automatic = root.querySelector('#weekWikiAutomatic').checked;
  const modes = [...root.querySelectorAll('[data-automation-mode]:checked')].map((input) => input.dataset.automationMode);
  if (automatic) modes.unshift('get-weeks');
  const order = guest ? [...root.querySelectorAll('[data-automation-judge]')].map((input) => input.value) : null;
  const enabled = root.querySelector('#weekAutomationEnabled').checked;
  if (guest && order.some(Boolean) && (new Set(order).size !== 4 || order.some((name) => !name))) throw new Error('Select every judge exactly once in Wikipedia order.');
  if (guest && enabled && modes.includes('live-show') && order.some((name) => !name)) throw new Error('Select Wikipedia’s judge order before enabling guest-judge scores.');
  const tag = root.querySelector('#weekWikiTag').value.trim();
  if (!automatic && !tag) throw new Error('Enter the Wikipedia week tag or use automatic discovery.');
  return {enabled, modes, wiki_tag_override:!automatic, wiki_tag:automatic ? null : tag,
    judge_order:order?.some(Boolean) ? order : null};
}

export function jobStatus(job, data, week, now = Date.now()) {
  const settings = data.settings || {};
  if (week.is_complete) return 'Week complete';
  if (!settings.enabled || !settings.modes?.includes(job.mode)) return 'Paused';
  if (!data.previous_complete) return 'Waiting for previous week completion';
  if (new Date(job.lease_until).getTime() > now) return 'Running';
  if (job.mode === 'get-weeks' && settings.wiki_tag) return 'Tag ready';
  if (job.mode !== 'get-weeks' && job.pending === 0) return 'Done';
  if (job.mode === 'post-show' && (week.is_finale || job.elimination_found)) return week.is_finale ? 'No elimination' : 'Elimination confirmed';
  if (job.mode !== 'photos' && job.mode !== 'get-weeks' && !settings.wiki_tag) return 'Waiting for Wikipedia tag';
  if (['photos','live-show','post-show'].includes(job.mode) && !job.window) return 'Airing window unavailable or ended';
  if (job.mode === 'photos' && new Date(data.worker?.photos_not_before).getTime() > now) return `Cooldown until ${date(data.worker.photos_not_before)}`;
  const due = Math.max(new Date(job.next_run_at).getTime() || 0, new Date(job.window).getTime() || 0);
  return due > now ? `Next check ${date(due)}` : 'Due · awaiting worker';
}

export function photoDiagnosticsMarkup(d) {
  if (!d || typeof d !== 'object') return '';
  const outcomes = {
    rate_limited: 'X/GitHub rate limit; waiting for cooldown', failed: 'Photo run failed',
    uploaded: 'Photos uploaded', partial_upload: 'Some couples uploaded; others still pending',
    already_satisfied: 'Existing photos verified; no download needed', preview_matches: 'Preview found matching posts',
    empty_timeline: 'X returned an empty timeline', no_recent_posts: 'No posts since this week’s airing date',
    no_matching_posts: 'No eligible posts matched both full couple names',
    no_images_downloaded: 'Matching posts found, but downloader produced no images', no_uploads: 'No photos uploaded',
  };
  const number = (key) => Math.max(0, Number(d[key]) || 0);
  return `<small>${escape(outcomes[d.outcome] || 'Photo diagnostics available')} · ${number('pending_couples')} couples pending</small>
    <small>${number('timeline_posts')} posts read · ${number('matched_posts')} matched · ${number('download_attempts')} downloads attempted · ${number('uploaded_files')} files uploaded · ${number('reconciled_couples')} couples verified on GitHub${number('empty_downloads') ? ` · ${number('empty_downloads')} empty downloads` : ''}</small>
    <small>${number('before_since_posts')} older posts · ${number('already_seen_posts')} previously processed · ${number('unmatched_posts')} without both names · ${number('ambiguous_posts')} ambiguous · ${number('non_image_files')} non-image files skipped</small>
    ${Array.isArray(d.warnings) && d.warnings.length ? `<small class="automation-error">Downloader notices: ${escape(d.warnings.join(', '))}</small>` : ''}`;
}

export function automationStatus(data, week) {
  if (!data) return '<details class="week-automation-status"><summary>Automation status unavailable</summary><p>Run add-score-desk-automation-controls.sql in Supabase, then refresh.</p></details>';
  const p = data.progress || {};
  const now = new Date(data.server_time).getTime() || Date.now();
  const heartbeat = new Date(data.worker?.last_heartbeat_at).getTime();
  const workerState = !heartbeat ? 'Not connected yet' : now - heartbeat < 180000 ? 'Connected' : 'Heartbeat stale';
  const names = new Map([['get-weeks','Week discovery'], ...automationModes]);
  return `<details class="week-automation-status"><summary>Automation · ${week.is_complete ? 'Week complete' : data.settings?.enabled ? 'Enabled' : 'Paused'} · ${Number(p.photos || 0)}/${Number(p.total || 0)} couples have photos</summary>
    <div class="automation-progress">${[['dance_types','Dance types'],['songs','Songs'],['scores','Score panels'],['eliminations','Results'],['photos','Photos']].map(([key,label]) => `<span><b>${Number(p[key] || 0)}/${Number(p.total || 0)}</b> ${label}</span>`).join('')}</div>
    <p class="sub">Counts show confirmed fields; unconfirmed imports are already visible. Worker: ${workerState}. Last heartbeat: ${date(data.worker?.last_heartbeat_at)}.</p>
    <div class="automation-jobs">${[...names].map(([mode,label]) => {const job=data.jobs?.find((j)=>j.mode===mode); return `<div><strong>${label}</strong><span>${escape(job ? jobStatus(job,data,week,now) : week.is_complete ? 'Week complete' : data.settings?.enabled && data.settings.modes?.includes(mode) ? 'Awaiting worker scheduling' : 'Paused')}</span>${job?.last_run ? `<small>Last check: ${date(job.last_run.finished_at || job.last_run.started_at)} · ${escape(job.last_run.status)}</small>` : ''}${mode === 'photos' ? photoDiagnosticsMarkup(job?.last_run?.summary?.photo_diagnostics) : ''}${job?.last_error ? `<small class="automation-error">${escape(job.last_error)}</small>` : ''}</div>`;}).join('')}</div>
    <button type="button" class="secondary" id="refreshWeekAutomation">Refresh status</button>
    <p class="sub">Schedule times are ET. Enablement and job choices carry into the next week unless explicitly overridden there.</p></details>`;
}
