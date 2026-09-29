import type { ToolDates } from './gitHistory';
import type { Tool } from './tools';

export type SortField = 'default' | 'added' | 'updated';
export type SortDirection = 'newest' | 'oldest';

export const SORT_OPTIONS: readonly { value: SortField; label: string }[] = [
  { value: 'default', label: 'Default' },
  { value: 'added', label: 'Date added' },
  { value: 'updated', label: 'Date updated' },
];

/**
 * Orders tools by when they were added or last updated. `default` keeps the
 * hand-picked order from tools.ts. Tools without dates always go last.
 */
export function sortTools(
  toolList: readonly Tool[],
  dates: Readonly<Record<string, ToolDates>>,
  field: SortField,
  direction: SortDirection,
): Tool[] {
  if (field === 'default') return [...toolList];

  const timeOf = (tool: Tool): number | undefined => {
    const iso = dates[tool.name]?.[field];
    return iso ? Date.parse(iso) : undefined;
  };

  return [...toolList].sort((a, b) => {
    const timeA = timeOf(a);
    const timeB = timeOf(b);
    if (timeA === undefined || timeB === undefined) {
      return (timeA === undefined ? 1 : 0) - (timeB === undefined ? 1 : 0);
    }
    return direction === 'newest' ? timeB - timeA : timeA - timeB;
  });
}

// Fixed names, because en-AU mixes "Apr" with "June" and "Sept".
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** Formats a date as "29 Sep 2026" in the viewer's time zone, or the one given. */
export function formatToolDate(iso: string, timeZone?: string): string {
  const parts = new Intl.DateTimeFormat('en-AU', {
    day: 'numeric',
    month: 'numeric',
    year: 'numeric',
    timeZone,
  }).formatToParts(new Date(iso));
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find(item => item.type === type)?.value ?? '';

  return `${part('day')} ${MONTHS[Number(part('month')) - 1]} ${part('year')}`;
}
