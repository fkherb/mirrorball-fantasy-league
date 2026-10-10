// Keep both deployments usable while the repository is being renamed.
// Never take a repository owner/name from an invite or another URL parameter.
export function photoRepositoryFor(pageUrl) {
  const url = new URL(pageUrl);
  const renamed = /^\/mirrorball-fantasy(?:\/|$)/.test(url.pathname);
  return `fkherb/${renamed ? 'mirrorball-fantasy' : 'mirrorball-fantasy-league'}`;
}

export function photoRepositoryEndpoints(pageUrl) {
  const repository = photoRepositoryFor(pageUrl);
  return {
    repository,
    treeUrl: `https://api.github.com/repos/${repository}/git/trees/main?recursive=1`,
    rawRoot: `https://raw.githubusercontent.com/${repository}/main/`,
  };
}
