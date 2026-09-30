const CDN_ASSET_REF = import.meta.env.VITE_GITHUB_SHA || 'main';

/** Pins jsDelivr repo assets to the deployed commit, so the CDN cache can't serve stale images. */
export function versionedAsset(url: string): string {
  if (!url.includes('cdn.jsdelivr.net/gh/mikecann/mikerosoft@main/')) return url;
  return url.replace('@main/', `@${CDN_ASSET_REF}/`);
}
