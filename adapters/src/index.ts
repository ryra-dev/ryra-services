import { z } from "zod";
export { z };

export const MAX_DOWNLOAD = 25 * 1024 * 1024;
export const FileId = z.strictObject({ drive: z.string().max(2048), item: z.string().min(1).max(2048) });
export const Location = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("root") }),
  z.strictObject({ kind: z.literal("site"), url: z.string().max(8192) }),
  z.strictObject({ kind: z.literal("folder"), id: FileId }),
]);
export const Request = z.discriminatedUnion("operation", [
  z.strictObject({ operation: z.literal("files.list"), location: Location, next: z.string().max(8192).nullable() }),
  z.strictObject({ operation: z.literal("files.download"), id: FileId }),
  z.strictObject({ operation: z.literal("directory.read") }),
]);
export const Input = z.strictObject({ version: z.literal(1), request: Request });
const sourceUrl = z.union([z.literal(""), z.url().refine((value) => {
  const url = new URL(value);
  return url.protocol === "https:" && !url.username && !url.password;
})]);
export const File = z.strictObject({
  id: FileId,
  name: z.string().min(1).max(4096),
  kind: z.enum(["file", "folder"]),
  size: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  mime: z.string().nullable(),
  source_url: sourceUrl,
});
export const FailureCode = z.enum([
  "unauthorized", "denied", "not_found", "rate_limited", "invalid_request",
  "invalid_response", "too_large", "unavailable",
]);
export const Output = z.discriminatedUnion("operation", [
  z.strictObject({ operation: z.literal("files.list"), files: z.array(File).max(1000), next: z.string().max(8192).nullable() }),
  z.strictObject({
    operation: z.literal("files.download"), name: z.string().min(1).max(4096),
    mime: z.string().nullable(), source_url: sourceUrl,
    data: z.base64().max(Math.ceil(MAX_DOWNLOAD / 3) * 4),
  }),
  z.strictObject({
    operation: z.literal("directory.read"), signed_in_as: z.string().max(320),
    people: z.array(z.strictObject({ name: z.string().max(4096), email: z.string().max(320), active: z.boolean() })).max(20000),
  }),
  z.strictObject({ operation: z.literal("error"), code: FailureCode }),
]);
export const Response = z.strictObject({ version: z.literal(1), result: Output });
export type FileId = z.infer<typeof FileId>;
export type File = z.infer<typeof File>;
export type Location = z.infer<typeof Location>;
export type Request = z.infer<typeof Request>;
export type Output = z.infer<typeof Output>;
export type FailureCode = z.infer<typeof FailureCode>;

type Operation = Request["operation"];
export type Handlers = {
  [K in Operation]?: (request: Extract<Request, { operation: K }>) =>
    Promise<Extract<Output, { operation: K }>>;
};

export class AdapterError extends Error {
  constructor(readonly code: FailureCode) { super(code); }
}

export function credential(name: string): string {
  const value = process.env[name];
  if (!value) throw new AdapterError("unauthorized");
  return value;
}

export async function serve(handlers: Handlers): Promise<void> {
  let result: Output;
  try {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of process.stdin) {
      const bytes = Buffer.from(chunk);
      size += bytes.length;
      if (size > 64 * 1024) throw new AdapterError("invalid_request");
      chunks.push(bytes);
    }
    let decoded: unknown;
    try { decoded = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
    catch { throw new AdapterError("invalid_request"); }
    const input = Input.safeParse(decoded);
    if (!input.success) throw new AdapterError("invalid_request");
    const request = input.data.request;
    switch (request.operation) {
      case "files.list": {
        const handler = handlers[request.operation];
        if (!handler) throw new AdapterError("invalid_request");
        result = await handler(request);
        break;
      }
      case "files.download": {
        const handler = handlers[request.operation];
        if (!handler) throw new AdapterError("invalid_request");
        result = await handler(request);
        break;
      }
      case "directory.read": {
        const handler = handlers[request.operation];
        if (!handler) throw new AdapterError("invalid_request");
        result = await handler(request);
        break;
      }
    }
    const parsed = Output.safeParse(result);
    if (!parsed.success || result.operation !== request.operation) throw new AdapterError("invalid_response");
    result = parsed.data;
  } catch (error) {
    result = { operation: "error", code: error instanceof AdapterError ? error.code : "invalid_response" };
  }
  // Provider responses and exception text may contain credentials or signed URLs.
  process.stdout.write(JSON.stringify({ version: 1, result }) + "\n");
}
