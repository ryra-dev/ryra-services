import { z, AdapterError, credential, MAX_DOWNLOAD, serve, type File, type Handlers, type Location } from "../../adapters/src/index.ts";
import { bytes, continuation, get, httpsHost, json } from "../../adapters/src/http.ts";

const token = () => credential("MICROSOFT_ACCESS_TOKEN");
const base = "https://graph.microsoft.com/v1.0/";
const sharepoint = (h: string) => h.endsWith(".sharepoint.com");
function endpoint(...parts: string[]): URL {
  if (parts.some((p) => !p || p === "." || p === ".." || /[\x00-\x1f\x7f]/.test(p))) throw new AdapterError("invalid_request");
  return new URL(parts.map(encodeURIComponent).join("/"), base);
}

async function listing(location: Location): Promise<URL> {
  if (location.kind === "site") {
    if (!httpsHost(location.url, sharepoint)) throw new AdapterError("invalid_request");
    const site = new URL(location.url);
    if (site.search || site.hash) throw new AdapterError("invalid_request");
    const parts = site.pathname.split("/").filter(Boolean).map(decodeURIComponent);
    const url = endpoint("sites", site.hostname + (parts.length ? ":" : ""), ...parts);
    url.searchParams.set("$select", "id");
    const found = await json(url, token(), z.object({ id: z.string() }));
    return endpoint("sites", found.id, "drives");
  }
  if (location.kind !== "folder") throw new AdapterError("invalid_request");
  const { drive, item } = location.id;
  return item === "root" ? endpoint("drives", drive, "root", "children") : endpoint("drives", drive, "items", item, "children");
}

const Item = z.object({
  id: z.string(), name: z.string(), webUrl: z.string().optional(), size: z.number().int().nonnegative().optional(),
  folder: z.object({}).optional(), file: z.object({ mimeType: z.string().optional() }).optional(),
  parentReference: z.object({ driveId: z.string().optional() }).optional(),
});
type Item = z.infer<typeof Item>;
function file(item: Item, drive: string, library: boolean): File {
  const source_url = item.webUrl && httpsHost(item.webUrl, sharepoint) ? item.webUrl : "";
  return {
    id: { drive: library ? item.id : item.parentReference?.driveId ?? drive, item: library ? "root" : item.id },
    name: item.name, kind: library || item.folder ? "folder" : "file", size: item.size ?? 0,
    mime: item.file?.mimeType ?? null, source_url,
  };
}

const handlers: Handlers = {
  "files.list": async ({ location, next }) => {
    const expected = await listing(location);
    expected.searchParams.set("$top", "100");
    const url = next ? continuation(expected, next) : expected;
    const page = await json(url, token(), z.object({ value: z.array(Item), "@odata.nextLink": z.string().optional() }));
    const following = page["@odata.nextLink"];
    if (following) continuation(expected, following);
    return {
      operation: "files.list", next: following ?? null,
      files: page.value.map((item) => file(item, location.kind === "folder" ? location.id.drive : "", location.kind === "site")),
    };
  },
  "files.download": async ({ id }) => {
    const meta = endpoint("drives", id.drive, "items", id.item);
    const item = await json(meta, token(), Item);
    if (item.id !== id.item || !item.file || item.folder) throw new AdapterError("invalid_response");
    const selected = file(item, id.drive, false);
    if (selected.size > MAX_DOWNLOAD) throw new AdapterError("too_large");
    let response = await get(endpoint("drives", id.drive, "items", id.item, "content"), token());
    for (let redirects = 0; response.status >= 300 && response.status < 400; redirects++) {
      const location = response.headers.get("location");
      await response.body?.cancel();
      if (redirects >= 3 || !location || !httpsHost(location, (h) => sharepoint(h) || h.endsWith(".files.1drv.com"))) throw new AdapterError("invalid_response");
      response = await get(new URL(location));
    }
    return { operation: "files.download", name: selected.name, mime: selected.mime, source_url: selected.source_url, data: (await bytes(response, MAX_DOWNLOAD)).toString("base64") };
  },
  "directory.read": async () => {
    const Identity = z.object({ mail: z.string().nullable().optional(), userPrincipalName: z.string().optional() });
    const identity = await json(endpoint("me"), token(), Identity);
    const signed_in_as = identity.mail || identity.userPrincipalName;
    if (!signed_in_as) throw new AdapterError("invalid_response");
    const expected = endpoint("users");
    expected.search = new URLSearchParams({ "$select": "displayName,mail,userPrincipalName", "$top": "999" }).toString();
    const Person = Identity.extend({ displayName: z.string().nullable().optional() });
    const people: { name: string; email: string; active: boolean }[] = [];
    const seen = new Set<string>();
    let url = expected;
    for (let page = 0; page < 100; page++) {
      const data = await json(url, token(), z.object({ value: z.array(Person), "@odata.nextLink": z.string().optional() }));
      people.push(...data.value.map((p) => ({ name: p.displayName ?? "", email: p.mail || p.userPrincipalName || "", active: true })));
      if (people.length > 20000) throw new AdapterError("too_large");
      const next = data["@odata.nextLink"];
      if (!next) return { operation: "directory.read", signed_in_as, people };
      if (seen.has(next)) throw new AdapterError("invalid_response");
      seen.add(next);
      url = continuation(expected, next);
    }
    throw new AdapterError("too_large");
  },
};

await serve(handlers);
