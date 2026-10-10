// Publish at https://fkherb.github.io/repo-redirect.js during the cutover.
// Fixed destination; query parameters cannot redirect to another domain.
(() => {
  const url = new URL(location.href);
  const oldRoot = '/mirrorball-fantasy-league';
  if (url.origin !== 'https://fkherb.github.io' ||
      !(url.pathname === oldRoot || url.pathname.startsWith(`${oldRoot}/`))) return;
  const suffix = url.pathname.slice(oldRoot.length);
  url.pathname = `/mirrorball-fantasy${suffix || '/'}`;
  const link = document.querySelector('#migrationDestination');
  if (link) link.href = url.href;
  location.replace(url.href);
})();
