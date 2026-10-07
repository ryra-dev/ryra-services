import { AdapterError, z } from "../../adapters/src/index.ts";
import { authorize, post, serveAuth, type Authorization } from "../../adapters/src/auth.ts";
import { json } from "../../adapters/src/http.ts";

const Saved = z.object({ client_id: z.uuid(), refresh_token: z.string().min(1) });
const Tokens = z.object({ access_token: z.string().min(1), token_type: z.string(), scope: z.string(), expires_in: z.number().int().positive(), refresh_token: z.string().min(1) });

async function exchange(client_id: string, form: Record<string, string>): Promise<Authorization> {
  const tokens = await post("https://api.resend.com/oauth/token", new URLSearchParams({ client_id, ...form }), Tokens);
  const scopes = tokens.scope.split(/\s+/);
  if (tokens.token_type.toLowerCase() !== "bearer" || !scopes.includes("full_access") || scopes.some((s) => !["full_access", "emails:send"].includes(s))) throw new AdapterError("denied");
  await json(new URL("https://api.resend.com/domains?limit=1"), tokens.access_token, z.object({ data: z.array(z.unknown()) }));
  return {
    fields: { api_key: tokens.access_token }, state: { client_id, refresh_token: tokens.refresh_token },
    expires_at: Math.floor(Date.now() / 1000) + tokens.expires_in,
  };
}

await serveAuth({
  async login() {
    const { client_id } = await post("https://api.resend.com/oauth/register", {
      client_name: "Ryra", redirect_uris: ["http://127.0.0.1/"], grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"], token_endpoint_auth_method: "none", scope: "full_access",
    }, z.object({ client_id: z.uuid() }));
    const url = new URL("https://api.resend.com/oauth/authorize");
    url.search = new URLSearchParams({ client_id, scope: "full_access", response_type: "code" }).toString();
    return authorize(url, ({ code, verifier, redirect }) => exchange(client_id, { grant_type: "authorization_code", code, code_verifier: verifier, redirect_uri: redirect }));
  },
  async refresh(value) {
    const saved = Saved.parse(value);
    return exchange(saved.client_id, { grant_type: "refresh_token", refresh_token: saved.refresh_token });
  },
});
