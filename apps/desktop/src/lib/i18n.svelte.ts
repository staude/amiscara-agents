import { de } from "./i18n/de";
import { en, type Messages } from "./i18n/en";

// The texts of the app in German and English (#207). Components call `t`
// with a key of `en`, the catalog every other language must match; `{name}`
// in a text is replaced from `params`. The language follows the system
// unless the settings fix one, and falls back to English.

export type Lang = "de" | "en";
/** The setting: as the system, or fixed. */
export type LangSetting = "system" | Lang;
export type MessageKey = keyof Messages;

const catalogs: Record<Lang, Messages> = { de, en };

/** The system's language if the app has it, else English. */
export function systemLang(): Lang {
  const tags = typeof navigator === "undefined" ? [] : [...(navigator.languages ?? []), navigator.language];
  for (const tag of tags) {
    const lang = tag?.slice(0, 2).toLowerCase();
    if (lang === "de" || lang === "en") return lang;
  }
  return "en";
}

class I18n {
  lang = $state<Lang>(systemLang());
}

export const i18n = new I18n();

/** The text for `key` in the current language, with `{name}` filled in. */
export function t(key: MessageKey, params?: Record<string, string | number>): string {
  const text = catalogs[i18n.lang][key] ?? en[key];
  return params ? text.replace(/\{(\w+)\}/g, (match, name: string) => (name in params ? String(params[name]) : match)) : text;
}

/** `one` for a count of 1, else `other`; `{n}` is the count. */
export function tn(n: number, one: MessageKey, other: MessageKey, params?: Record<string, string | number>): string {
  return t(n === 1 ? one : other, { n, ...params });
}

/** Numbers and dates as the current language writes them. */
export function locale(): string {
  return i18n.lang === "de" ? "de-DE" : "en-US";
}
