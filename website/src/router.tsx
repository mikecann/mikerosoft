import { useSyncExternalStore, type AnchorHTMLAttributes, type MouseEvent } from 'react';
import { parseRoute, type Route } from './toolPages';

const NAVIGATE_EVENT = 'mikerosoft:navigate';

function subscribe(onChange: () => void) {
  window.addEventListener('popstate', onChange);
  window.addEventListener(NAVIGATE_EVENT, onChange);
  return () => {
    window.removeEventListener('popstate', onChange);
    window.removeEventListener(NAVIGATE_EVENT, onChange);
  };
}

export function usePathname(): string {
  return useSyncExternalStore(subscribe, () => window.location.pathname);
}

export function useRoute(): Route {
  return parseRoute(usePathname());
}

export function navigate(path: string) {
  if (path === window.location.pathname) return;
  window.history.pushState(null, '', path);
  window.scrollTo(0, 0);
  window.dispatchEvent(new Event(NAVIGATE_EVENT));
}

/** An anchor that changes page without a reload, unless opened in a new tab. */
export function Link({ href, onClick, ...props }: AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }) {
  function handleClick(event: MouseEvent<HTMLAnchorElement>) {
    onClick?.(event);
    if (
      event.defaultPrevented
      || event.button !== 0
      || event.metaKey
      || event.ctrlKey
      || event.shiftKey
      || event.altKey
    ) return;
    event.preventDefault();
    navigate(href);
  }

  return <a href={href} onClick={handleClick} {...props} />;
}
