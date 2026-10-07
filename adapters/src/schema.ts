import { z } from "zod";
import { Input, Response } from "./index.ts";
import { AuthInput, AuthEvent } from "./auth.ts";

for (const [name, schema] of Object.entries({ input: Input, response: Response, "auth-input": AuthInput, "auth-event": AuthEvent })) {
  await Bun.write(new URL(`../${name}.schema.json`, import.meta.url), JSON.stringify(z.toJSONSchema(schema), null, 2) + "\n");
}
