import { z } from "zod";
import { AdapterError } from "./index.ts";

export async function bytes(response: Response, limit: number): Promise<Buffer> {
  if (Number(response.headers.get("content-length")) > limit) throw new AdapterError("too_large");
  const reader = response.body?.getReader();
  if (!reader) throw new AdapterError("invalid_response");
  let size = 0;
  const chunks: Uint8Array[] = [];
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) throw new AdapterError("too_large");
      chunks.push(value);
    }
  } finally { await reader.cancel(); }
  return Buffer.concat(chunks);
}

export async function get(url: URL, token?: string): Promise<Response> {
  const deadline = Date.now() + 30000;
  for (let attempt = 0; ; attempt++) {
    let response: Response | undefined;
    try {
      response = await fetch(url, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
        redirect: "manual", signal: AbortSignal.timeout(Math.max(1, deadline - Date.now())),
      });
    } catch { /* A failed GET can be retried within the same deadline. */ }
    if (response && (response.ok || (response.status >= 300 && response.status < 400))) return response;
    const code = ({ 401: "unauthorized", 403: "denied", 404: "not_found", 429: "rate_limited" } as const)[response?.status as 401 | 403 | 404 | 429] ?? "unavailable";
    const retry = !response || [408, 429, 500, 502, 503, 504].includes(response.status);
    const after = response?.headers.get("retry-after");
    const stated = after ? (/^\d+$/.test(after) ? Number(after) * 1000 : Date.parse(after) - Date.now()) : NaN;
    const delay = Number.isNaN(stated) ? 250 * 2 ** attempt : Math.max(0, stated);
    await response?.body?.cancel();
    if (!retry || attempt >= 3 || Date.now() + delay >= deadline) throw new AdapterError(code);
    await new Promise((resolve) => setTimeout(resolve, delay));
  }
}

export async function json<T extends z.ZodType>(url: URL, token: string, schema: T): Promise<z.output<T>> {
  const response = await get(url, token);
  if (!response.ok) { await response.body?.cancel(); throw new AdapterError("invalid_response"); }
  const value = schema.safeParse(JSON.parse((await bytes(response, 2 * 1024 * 1024)).toString("utf8")));
  if (!value.success) throw new AdapterError("invalid_response");
  return value.data;
}

export function continuation(expected: URL, value: string): URL {
  const next = new URL(value);
  if (next.origin !== expected.origin || next.pathname !== expected.pathname || next.username || next.password || next.hash) {
    throw new AdapterError("invalid_request");
  }
  return next;
}

export function httpsHost(value: string, allowed: (host: string) => boolean): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password && !url.port && allowed(url.hostname);
  } catch { return false; }
}
