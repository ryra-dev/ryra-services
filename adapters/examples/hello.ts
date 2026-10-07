import { serve } from "../src/index.ts";

await serve({
  "files.list": async () => ({
    operation: "files.list",
    files: [{ id: { drive: "", item: "hello" }, name: "Hello.txt", kind: "file", size: 6, mime: "text/plain", source_url: "https://example.com/hello" }],
    next: null,
  }),
  "files.download": async () => ({
    operation: "files.download", name: "Hello.txt", mime: "text/plain",
    source_url: "https://example.com/hello", data: Buffer.from("Hello\n").toString("base64"),
  }),
});
