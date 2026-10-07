import { createServer, type ServerResponse } from "node:http";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { AdapterError, FailureCode, z } from "./index.ts";
import { bytes } from "./http.ts";

export const AuthInput = z.strictObject({ version: z.literal(1), request: z.discriminatedUnion("operation", [
  z.strictObject({ operation: z.literal("auth.login"), configuration: z.record(z.string(), z.string()) }),
  z.strictObject({ operation: z.literal("auth.refresh"), state: z.json() }),
]) });
export const Authorization = z.strictObject({
  fields: z.record(z.string().min(1), z.string().min(1)),
  state: z.json(), expires_at: z.number().int().positive().nullable(),
});
export type Authorization = z.infer<typeof Authorization>;
export const AuthEvent = z.strictObject({ version: z.literal(1), event: z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("progress"), stage: z.enum(["waiting", "verifying"]) }),
  z.strictObject({ kind: z.literal("open"), url: z.url() }),
  Authorization.extend({ kind: z.literal("connected") }),
  z.strictObject({ kind: z.literal("error"), code: FailureCode }),
]) });
export type AuthInput = z.infer<typeof AuthInput>;
export type AuthEvent = z.infer<typeof AuthEvent>;
export type AuthHandlers = {
  login: (configuration: Record<string, string>) => Promise<Authorization>;
  refresh: (state: z.infer<ReturnType<typeof z.json>>) => Promise<Authorization>;
};

function emit(event: z.infer<typeof AuthEvent>["event"]): void {
  process.stdout.write(JSON.stringify(AuthEvent.parse({ version: 1, event })) + "\n");
}

export function openBrowser(url: string): void {
  emit({ kind: "open", url });
}

export function progress(stage: "waiting" | "verifying"): void {
  emit({ kind: "progress", stage });
}

export async function serveAuth(handlers: AuthHandlers): Promise<void> {
  try {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of process.stdin) {
      const value = Buffer.from(chunk);
      size += value.length;
      if (size > 1024 * 1024) throw new AdapterError("invalid_request");
      chunks.push(value);
    }
    let decoded: unknown;
    try { decoded = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
    catch { throw new AdapterError("invalid_request"); }
    const input = AuthInput.safeParse(decoded);
    if (!input.success) throw new AdapterError("invalid_request");
    const request = input.data.request;
    const result = request.operation === "auth.login"
      ? await handlers.login(request.configuration) : await handlers.refresh(request.state);
    emit({ kind: "connected", ...Authorization.parse(result) });
  } catch (error) {
    emit({ kind: "error", code: error instanceof AdapterError ? error.code : "invalid_response" });
  }
}

export function required(configuration: Record<string, string>, key: string): string {
  const value = configuration[key];
  if (!value?.trim()) throw new AdapterError("invalid_request");
  return value;
}

export async function post<T extends z.ZodType>(endpoint: string, body: URLSearchParams | object, schema: T): Promise<z.output<T>> {
  let response: Response;
  try {
    response = await fetch(endpoint, {
      method: "POST", redirect: "manual", signal: AbortSignal.timeout(30000),
      headers: { Accept: "application/json", "Content-Type": body instanceof URLSearchParams ? "application/x-www-form-urlencoded" : "application/json" },
      body: body instanceof URLSearchParams ? body : JSON.stringify(body),
    });
  } catch { throw new AdapterError("unavailable"); }
  if (!response.ok) { await response.body?.cancel(); throw new AdapterError("unauthorized"); }
  const result = schema.safeParse(JSON.parse((await bytes(response, 65536)).toString("utf8")));
  if (!result.success) throw new AdapterError("invalid_response");
  return result.data;
}

type Choice = { id: string; label: string };
type Selection = { choices: Choice[]; select: (id: string) => Authorization };
type Callback = { code: string; verifier: string; redirect: string };
const escape = (value: string) => value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] ?? ""));

export async function authorize(
  url: URL,
  complete: (callback: Callback) => Promise<Authorization | Selection>,
  options: { port?: number; host?: "localhost" | "127.0.0.1"; path?: string } = {},
): Promise<Authorization> {
  const state = randomBytes(32).toString("base64url");
  const verifier = randomBytes(32).toString("base64url");
  const path = options.path ?? "/";
  let selection: Selection | undefined;
  let consumed = false;
  let settle!: (value: Authorization) => void;
  let refuse!: (error: unknown) => void;
  const result = new Promise<Authorization>((resolve, reject) => { settle = resolve; refuse = reject; });
  let redirect = "";
  function respond(response: ServerResponse, status: number, body: string): void {
    response.writeHead(status, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "Content-Security-Policy": "default-src 'none'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'", Connection: "close" });
    response.end(body);
  }
  const server = createServer(async (request, response) => {
    try {
      const current = new URL(request.url ?? "", redirect);
      if (request.headers.host !== new URL(redirect).host || current.pathname !== path) {
        respond(response, 404, "Not found"); return;
      }
      let parameters = current.searchParams;
      if (request.method === "POST" && selection) {
        if (request.headers.origin && request.headers.origin !== new URL(redirect).origin) {
          respond(response, 403, "Invalid origin"); return;
        }
        const chunks: Buffer[] = [];
        let size = 0;
        for await (const chunk of request) {
          size += chunk.length;
          if (size > 8192) throw new AdapterError("invalid_request");
          chunks.push(Buffer.from(chunk));
        }
        parameters = new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
      } else if (request.method !== "GET") { respond(response, 405, "Method not allowed"); return; }
      const returned = parameters.get("state") ?? "";
      if (parameters.getAll("state").length !== 1 || returned.length !== state.length || !timingSafeEqual(Buffer.from(returned), Buffer.from(state))) {
        respond(response, 403, "This sign-in does not match. Return to Ryra."); return;
      }
      if (selection && request.method === "POST") {
        const id = parameters.get("account") ?? "";
        if (!selection.choices.some((choice) => choice.id === id)) { respond(response, 400, "Choose an account"); return; }
        const authorization = selection.select(id);
        selection = undefined;
        respond(response, 200, "Connected. Return to Ryra.");
        settle(authorization); return;
      }
      if (consumed) { respond(response, 409, "This sign-in has already returned"); return; }
      consumed = true;
      if (parameters.has("error")) throw new AdapterError("denied");
      const code = parameters.get("code");
      if (!code || code.length > 8192 || parameters.getAll("code").length !== 1) throw new AdapterError("invalid_request");
      progress("verifying");
      const authorization = await complete({ code, verifier, redirect });
      if ("choices" in authorization) {
        if (!authorization.choices.length) throw new AdapterError("denied");
        selection = authorization;
        progress("waiting");
        respond(response, 200, `<h1>Choose an account</h1><form method="post" action="${escape(path)}"><input type="hidden" name="state" value="${state}">${selection.choices.map((choice) => `<p><button name="account" value="${escape(choice.id)}">${escape(choice.label)}</button></p>`).join("")}</form>`);
      } else { respond(response, 200, "Connected. Return to Ryra."); settle(authorization); }
    } catch (error) { respond(response, 400, "Sign-in could not be completed. Return to Ryra."); refuse(error); }
  });
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(options.port ?? 0, "127.0.0.1", resolve); });
    const address = server.address();
    if (!address || typeof address === "string") throw new AdapterError("unavailable");
    redirect = `http://${options.host ?? "127.0.0.1"}:${address.port}${path}`;
    url.searchParams.set("redirect_uri", redirect);
    url.searchParams.set("state", state);
    url.searchParams.set("code_challenge", createHash("sha256").update(verifier).digest("base64url"));
    url.searchParams.set("code_challenge_method", "S256");
    openBrowser(url.toString());
    timer = setTimeout(() => refuse(new AdapterError("unavailable")), 295000);
    return await result;
  } finally {
    clearTimeout(timer);
    server.close();
    server.closeIdleConnections();
  }
}
