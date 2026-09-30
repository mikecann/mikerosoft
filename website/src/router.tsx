import { useEffect, useRef, type AnchorHTMLAttributes, type MouseEvent } from 'react';

const NAVIGATE_EVENT = 'mikerosoft:navigate';

/**
 * Goes to a path without a reload. It always tells listeners, even for the
 * current path, because clicking a closed tool's icon should reopen it.
 */
export function navigate(path: string) {
  if (path !== window.location.pathname) window.history.pushState(null, '', path);
  window.dispatchEvent(new Event(NAVIGATE_EVENT));
}

/** Changes the address bar to match what's on screen, without telling anyone. */
export function replacePath(path: string) {
  if (path !== window.location.pathname) window.history.replaceState(null, '', path);
}

/** Calls back with the path on every navigate() and every back or forward. */
export function useNavigation(onNavigate: (pathname: string) => void) {
  const callback = useRef(onNavigate);
  callback.current = onNavigate;

  useEffect(() => {
    const handle = () => callback.current(window.location.pathname);
    window.addEventListener('popstate', handle);
    window.addEventListener(NAVIGATE_EVENT, handle);
    return () => {
      window.removeEventListener('popstate', handle);
      window.removeEventListener(NAVIGATE_EVENT, handle);
    };
  }, []);
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
