export function el<T extends HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`Element #${id} not found in DOM`);
  return element as T;
}

export function setStatus(text: string): void {
  el("status").textContent = text;
}

export function hideOverlay(): void {
  el("overlay").classList.add("hidden");
}

export function showError(message: string): void {
  setStatus(message);
  const spinner = document.querySelector<HTMLElement>(".spinner");
  if (spinner) spinner.style.display = "none";
}
