import { z, AdapterError, credential, MAX_DOWNLOAD, serve, type File, type FileId, type Handlers } from "../../adapters/src/index.ts";
import { bytes, get, httpsHost, json } from "../../adapters/src/http.ts";

const token = () => credential("GOOGLE_ACCESS_TOKEN");
const base = "https://www.googleapis.com/drive/v3/";
const fields = "id,name,mimeType,size,webViewLink,capabilities(canDownload)";
const Item = z.object({
  id: z.string(), name: z.string(), mimeType: z.string(), size: z.string().optional(),
  webViewLink: z.string().optional(), capabilities: z.object({ canDownload: z.boolean().optional() }).optional(),
});
type Item = z.infer<typeof Item>;

function id(value: FileId): string {
  if (value.drive || !/^[a-zA-Z0-9_-]{1,512}$/.test(value.item)) throw new AdapterError("invalid_request");
  return value.item;
}

function file(item: Item): File {
  const key = { drive: "", item: item.id };
  id(key);
  return {
    id: key, name: item.name, mime: item.mimeType, size: item.size === undefined ? 0 : Number(item.size),
    kind: item.mimeType === "application/vnd.google-apps.folder" ? "folder" : "file",
    source_url: item.webViewLink && httpsHost(item.webViewLink, (h) => ["drive.google.com", "docs.google.com"].includes(h))
      ? item.webViewLink : `https://drive.google.com/file/d/${item.id}/view`,
  };
}

const exports: Record<string, [string, string]> = {
  "application/vnd.google-apps.document": ["docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
  "application/vnd.google-apps.spreadsheet": ["xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
  "application/vnd.google-apps.presentation": ["pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"],
};

const handlers: Handlers = {
  "files.list": async ({ location, next }) => {
    let q: string;
    switch (location.kind) {
      case "root": q = "trashed = false"; break;
      case "folder": q = `trashed = false and '${id(location.id)}' in parents`; break;
      default: throw new AdapterError("invalid_request");
    }
    const url = new URL("files", base);
    url.search = new URLSearchParams({ q, fields: `nextPageToken,files(${fields})`, pageSize: "100", spaces: "drive", supportsAllDrives: "true", includeItemsFromAllDrives: "true" }).toString();
    if (next) url.searchParams.set("pageToken", next);
    const page = await json(url, token(), z.object({ files: z.array(Item), nextPageToken: z.string().optional() }));
    return { operation: "files.list", files: page.files.map(file), next: page.nextPageToken ?? null };
  },
  "files.download": async ({ id: key }) => {
    const itemId = id(key);
    const meta = new URL(`files/${itemId}`, base);
    meta.search = new URLSearchParams({ fields, supportsAllDrives: "true" }).toString();
    const item = await json(meta, token(), Item);
    if (item.id !== itemId) throw new AdapterError("invalid_response");
    if (item.capabilities?.canDownload !== true) throw new AdapterError("denied");
    const selected = file(item);
    if (selected.size > MAX_DOWNLOAD) throw new AdapterError("too_large");
    const conversion = exports[item.mimeType];
    if (!conversion && item.mimeType.startsWith("application/vnd.google-apps.")) throw new AdapterError("invalid_request");
    const url = new URL(`files/${itemId}${conversion ? "/export" : ""}`, base);
    if (conversion) {
      const [extension, mime] = conversion;
      url.searchParams.set("mimeType", mime);
      selected.mime = mime;
      if (!selected.name.toLowerCase().endsWith(`.${extension}`)) selected.name += `.${extension}`;
    } else {
      url.searchParams.set("alt", "media");
      url.searchParams.set("supportsAllDrives", "true");
    }
    const response = await get(url, token());
    if (!response.ok) { await response.body?.cancel(); throw new AdapterError("invalid_response"); }
    return { operation: "files.download", name: selected.name, mime: selected.mime, source_url: selected.source_url, data: (await bytes(response, MAX_DOWNLOAD)).toString("base64") };
  },
  "directory.read": async () => {
    const identity = await json(new URL("https://openidconnect.googleapis.com/v1/userinfo"), token(), z.object({ email: z.string(), email_verified: z.literal(true), hd: z.string().min(1) }));
    const Person = z.object({
      primaryEmail: z.string().optional(), name: z.object({ fullName: z.string().optional() }).optional(),
      suspended: z.boolean().optional(), archived: z.boolean().optional(),
    });
    const people: { name: string; email: string; active: boolean }[] = [];
    const seen = new Set<string>();
    let next: string | undefined;
    for (let page = 0; page < 100; page++) {
      const url = new URL("https://admin.googleapis.com/admin/directory/v1/users");
      url.search = new URLSearchParams({ customer: "my_customer", maxResults: "500", projection: "basic", viewType: "admin_view" }).toString();
      if (next) url.searchParams.set("pageToken", next);
      const data = await json(url, token(), z.object({ users: z.array(Person).optional(), nextPageToken: z.string().max(8192).optional() }));
      people.push(...(data.users ?? []).map((p) => ({ name: p.name?.fullName ?? "", email: p.primaryEmail ?? "", active: !p.suspended && !p.archived })));
      if (people.length > 20000) throw new AdapterError("too_large");
      next = data.nextPageToken;
      if (!next) return { operation: "directory.read", signed_in_as: identity.email, people };
      if (seen.has(next)) throw new AdapterError("invalid_response");
      seen.add(next);
    }
    throw new AdapterError("too_large");
  },
};

await serve(handlers);
