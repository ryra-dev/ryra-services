import { AdapterError, z } from "../../adapters/src/index.ts";
import { authorize, post, required, serveAuth, type Authorization } from "../../adapters/src/auth.ts";
import { json } from "../../adapters/src/http.ts";

const Saved = z.object({ client_id: z.string().min(1), refresh_token: z.string().min(1), account_id: z.string().regex(/^[a-f0-9]{32}$/), scopes: z.string().min(1) });
const Account = z.object({ id: z.string().regex(/^[a-f0-9]{32}$/), name: z.string().min(1) });
const Tokens = z.object({ access_token: z.string().min(1), token_type: z.string(), expires_in: z.number().int().positive(), refresh_token: z.string().min(1).optional(), scope: z.string().optional() });

async function exchange(client_id: string, scopes: string, form: Record<string, string>) {
  const tokens = await post("https://dash.cloudflare.com/oauth2/token", new URLSearchParams({ client_id, ...form }), Tokens);
  if (tokens.token_type.toLowerCase() !== "bearer") throw new AdapterError("invalid_response");
  if (tokens.scope) {
    const wanted = new Set(scopes.split(/\s+/));
    const got = new Set(tokens.scope.split(/\s+/));
    if ([...wanted].some((s) => !got.has(s)) || [...got].some((s) => !wanted.has(s))) throw new AdapterError("denied");
  }
  return tokens;
}

function connected(tokens: z.infer<typeof Tokens>, saved: z.infer<typeof Saved>): Authorization {
  return { fields: { account_id: saved.account_id, api_token: tokens.access_token }, state: saved, expires_at: Math.floor(Date.now() / 1000) + tokens.expires_in };
}

await serveAuth({
  async login(configuration) {
    const client_id = required(configuration, "client_id");
    const selected = required(configuration, "scopes").split(/\s+/).filter(Boolean);
    if (selected.every((s) => s === "offline_access")) throw new AdapterError("invalid_request");
    const scopes = [...new Set([...selected, "offline_access"])].join(" ");
    const url = new URL("https://dash.cloudflare.com/oauth2/auth");
    url.search = new URLSearchParams({ client_id, scope: scopes, response_type: "code" }).toString();
    return authorize(url, async ({ code, verifier, redirect }) => {
      const tokens = await exchange(client_id, scopes, { grant_type: "authorization_code", code, code_verifier: verifier, redirect_uri: redirect });
      const refresh_token = tokens.refresh_token;
      if (!refresh_token) throw new AdapterError("unauthorized");
      const accounts: z.infer<typeof Account>[] = [];
      for (let page = 1; ; page++) {
        if (page > 20) throw new AdapterError("too_large");
        const response = await json(new URL(`https://api.cloudflare.com/client/v4/accounts?per_page=50&page=${page}`), tokens.access_token,
          z.object({ success: z.literal(true), result: z.array(Account), result_info: z.object({ total_pages: z.number().int().nonnegative() }).optional() }));
        accounts.push(...response.result);
        if (response.result.length < 50 || page >= (response.result_info?.total_pages ?? Infinity)) break;
      }
      const select = (account_id: string) => connected(tokens, { client_id, refresh_token, account_id, scopes });
      if (accounts.length === 1 && accounts[0]) return select(accounts[0].id);
      return { choices: accounts.map((account) => ({ id: account.id, label: account.name })), select };
    }, { port: 8977, host: "localhost", path: "/oauth/cloudflare/callback" });
  },
  async refresh(value) {
    const saved = Saved.parse(value);
    const tokens = await exchange(saved.client_id, saved.scopes, { grant_type: "refresh_token", refresh_token: saved.refresh_token });
    const account = await json(new URL(`https://api.cloudflare.com/client/v4/accounts/${saved.account_id}`), tokens.access_token, z.object({ success: z.literal(true), result: Account }));
    if (account.result.id !== saved.account_id) throw new AdapterError("unauthorized");
    return connected(tokens, { ...saved, refresh_token: tokens.refresh_token ?? saved.refresh_token });
  },
});
