import { AdapterError, z } from "../../adapters/src/index.ts";
import { authorize, post, required, serveAuth, type Authorization } from "../../adapters/src/auth.ts";
import { bytes } from "../../adapters/src/http.ts";

const Registration = z.object({ client_id: z.string().min(1), client_secret: z.string().min(1) });
const Saved = z.object({ registration: Registration, account_id: z.number().int().positive(), refresh_token: z.string().min(1).nullable() });
const Tokens = z.object({ access_token: z.string().min(1), token_type: z.string(), scope: z.string(), expires_in: z.number().int().positive().optional(), refresh_token: z.string().min(1).optional() });

async function exchange(registration: z.infer<typeof Registration>, form: Record<string, string>, expected?: number): Promise<Authorization> {
  const tokens = await post("https://github.com/login/oauth/access_token", new URLSearchParams({ ...registration, ...form }), Tokens);
  const scopes = tokens.scope.split(/[ ,]+/).filter(Boolean);
  if (tokens.token_type.toLowerCase() !== "bearer" || !scopes.includes("repo") || scopes.some((s) => !["repo", "offline_access"].includes(s))) throw new AdapterError("denied");
  if (!!tokens.expires_in !== !!tokens.refresh_token) throw new AdapterError("invalid_response");
  const response = await fetch("https://api.github.com/user", {
    headers: { Authorization: `Bearer ${tokens.access_token}`, "User-Agent": "Ryra", Accept: "application/vnd.github+json" },
    redirect: "manual", signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) { await response.body?.cancel(); throw new AdapterError("unauthorized"); }
  const identity = z.object({ id: z.number().int().positive() }).parse(JSON.parse((await bytes(response, 65536)).toString("utf8")));
  if (expected && identity.id !== expected) throw new AdapterError("unauthorized");
  return {
    fields: { token: tokens.access_token },
    state: { registration, account_id: identity.id, refresh_token: tokens.refresh_token ?? null },
    expires_at: tokens.expires_in ? Math.floor(Date.now() / 1000) + tokens.expires_in : null,
  };
}

await serveAuth({
  async login(configuration) {
    const registration = { client_id: required(configuration, "client_id"), client_secret: required(configuration, "client_secret") };
    const url = new URL("https://github.com/login/oauth/authorize");
    url.search = new URLSearchParams({ client_id: registration.client_id, scope: "repo", response_type: "code" }).toString();
    return authorize(url, ({ code, verifier, redirect }) => exchange(registration, { code, code_verifier: verifier, redirect_uri: redirect }));
  },
  async refresh(value) {
    const saved = Saved.parse(value);
    if (!saved.refresh_token) throw new AdapterError("unauthorized");
    return exchange(saved.registration, { grant_type: "refresh_token", refresh_token: saved.refresh_token }, saved.account_id);
  },
});
