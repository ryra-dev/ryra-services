use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

fn call(root: &Path, preload: &Path, service: &str, request: &str) -> String {
    let mut child = Command::new("bun")
        .args(["--no-install", "--preload"])
        .arg(preload).arg(root.join(format!("services/{service}/adapter.ts")))
        .env("GOOGLE_ACCESS_TOKEN", "private-test-token")
        .env("MICROSOFT_ACCESS_TOKEN", "private-test-token")
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().expect("start adapter");
    child.stdin.take().expect("stdin").write_all(request.as_bytes()).expect("request");
    let output = child.wait_with_output().expect("adapter result");
    assert!(output.status.success(), "adapter failed: {}", String::from_utf8_lossy(&output.stderr));
    assert!(output.stderr.is_empty());
    let output = String::from_utf8(output.stdout).expect("JSON");
    if !request.contains("auth.") { assert!(!output.contains("private-test-token")); }
    output
}

fn response(stream: &mut TcpStream, status: &str, extra: &str, body: &str) {
    write!(stream, "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{extra}\r\n{body}", body.len()).expect("HTTP response");
}

#[test]
fn provider_contracts_bound_pages_validate_rows_and_never_forward_redirect_credentials() {
    let root = std::env::current_dir().expect("service checkout");
    let listener = TcpListener::bind("127.0.0.1:0").expect("fixture listener");
    let addr = listener.local_addr().expect("address");
    let path = std::env::temp_dir().join(format!("ryra-adapter-fixture-{}.ts", std::process::id()));
    std::fs::write(&path, format!(r#"import {{ createHash }} from "node:crypto";
const original = globalThis.fetch;
let challenge = "";
globalThis.fetch = async (url, options) => {{
  if (options?.body instanceof URLSearchParams && options.body.has("code")) {{
    if (createHash("sha256").update(options.body.get("code_verifier") ?? "").digest("base64url") !== challenge) process.exit(81);
  }}
  const headers = new Headers(options?.headers);
  headers.set("x-original-url", String(url));
  return original("http://{addr}", {{ ...options, headers }});
}};
const write = process.stdout.write.bind(process.stdout);
process.stdout.write = (chunk, ...args) => {{
  const message = JSON.parse(String(chunk));
  if (message.event?.kind === "open") {{
    const authorize = new URL(message.event.url);
    challenge = authorize.searchParams.get("code_challenge") ?? "";
    if (!challenge || authorize.searchParams.get("code_challenge_method") !== "S256") process.exit(82);
    void (async () => {{
      const callback = new URL(authorize.searchParams.get("redirect_uri"));
      callback.search = new URLSearchParams({{ code: "test-code", state: "wrong" }}).toString();
      if ((await original(callback)).status !== 403) process.exit(83);
      const state = authorize.searchParams.get("state");
      callback.searchParams.set("state", state);
      const response = await original(callback);
      const body = await response.text();
      if (body.includes("<form")) {{
        if (body.includes("<script>")) process.exit(84);
        const selected = await original(callback.origin + callback.pathname, {{
          method: "POST", headers: {{ Origin: callback.origin }},
          body: new URLSearchParams({{ state, account: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }}),
        }});
        if (!selected.ok) process.exit(85);
      }}
    }})().catch(() => process.exit(86));
  }}
  return write(chunk, ...args);
}};
"#)).expect("preload");
    struct Remove(std::path::PathBuf);
    impl Drop for Remove { fn drop(&mut self) { let _ = std::fs::remove_file(&self.0); } }
    let _cleanup = Remove(path.clone());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let requests = seen.clone();
    let task = std::thread::spawn(move || {
        for connection in listener.incoming() {
            let mut stream = connection.expect("fixture connection");
            stream.set_read_timeout(Some(std::time::Duration::from_secs(5))).expect("timeout");
            let mut reader = BufReader::new(stream.try_clone().expect("reader"));
            let mut url = String::new();
            let mut bearer = false;
            let mut length = 0;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).expect("HTTP header") == 0 || line == "\r\n" { break; }
                if let Some(value) = line.strip_prefix("x-original-url: ") { url = value.trim().into(); }
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length: ") { length = value.trim().parse::<usize>().expect("length"); }
                if line.to_ascii_lowercase().starts_with("authorization:") {
                    assert!(line.contains("Bearer private-test-token") || line.contains("Bearer connected-access")); bearer = true;
                }
            }
            if url.is_empty() { break; }
            assert!(length <= 65536);
            let mut body = vec![0; length];
            reader.read_exact(&mut body).expect("request body");
            let body = String::from_utf8(body).expect("UTF-8 body");
            requests.lock().expect("requests").push(url.clone());
            assert!(!url.starts_with("https://attacker.example"));
            if url.ends_with("/oauth/register") {
                assert!(!bearer);
                assert!(body.contains("http://127.0.0.1/"));
                response(&mut stream, "200 OK", "", r#"{"client_id":"11111111-2222-4333-8444-555555555555"}"#);
                continue;
            }
            if url.contains("/oauth/token") || url.contains("/oauth2/token") || url.contains("/oauth/access_token") {
                assert!(!bearer);
                assert!(body.contains("client_id="));
                let scope = if url.contains("github.com") { if body.contains("client_id=broad") { "repo admin:org" } else { "repo" } }
                    else if url.contains("resend.com") { "full_access" } else { "zone:read offline_access" };
                response(&mut stream, "200 OK", "", &format!(r#"{{"access_token":"connected-access","token_type":"bearer","scope":"{scope}","expires_in":3600,"refresh_token":"rotated-refresh"}}"#));
                continue;
            }
            if url == "https://api.github.com/user" {
                assert!(bearer);
                response(&mut stream, "200 OK", "", r#"{"id":7}"#);
                continue;
            }
            if url.contains("api.resend.com/domains") {
                assert!(bearer);
                response(&mut stream, "200 OK", "", r#"{"data":[]}"#);
                continue;
            }
            if url.contains("api.cloudflare.com/client/v4/accounts") {
                assert!(bearer);
                if url.contains("/accounts/") {
                    response(&mut stream, "200 OK", "", r#"{"success":true,"result":{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"Selected"}}"#);
                } else {
                    response(&mut stream, "200 OK", "", r#"{"success":true,"result":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"<script>"},{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","name":"Selected"}]}"#);
                }
                continue;
            }
            if url.starts_with("https://tenant.sharepoint.com/download") {
                assert!(!bearer, "redirect received authorization");
                response(&mut stream, "200 OK", "", "downloaded");
                continue;
            }
            assert!(bearer, "provider request lacked authorization");
            if url.contains("/content") {
                response(&mut stream, "302 Found", "Location: https://tenant.sharepoint.com/download\r\n", "");
            } else if url.contains("/export") {
                assert!(url.contains("wordprocessingml.document"));
                response(&mut stream, "200 OK", "", "exported");
            } else if url.contains("googleapis.com/drive/") {
                if url.contains("/files?") {
                    assert!(url.contains("pageToken=https%3A%2F%2Fattacker.example"));
                    response(&mut stream, "200 OK", "", r#"{"files":[{"id":"doc","name":"Proposal","mimeType":"application/vnd.google-apps.document","capabilities":{"canDownload":true}}]}"#);
                } else if url.contains("/restricted?") {
                    response(&mut stream, "200 OK", "", r#"{"id":"restricted","name":"Restricted","mimeType":"application/pdf","capabilities":{"canDownload":false}}"#);
                } else {
                    response(&mut stream, "200 OK", "", r#"{"id":"doc","name":"Proposal","mimeType":"application/vnd.google-apps.document","capabilities":{"canDownload":true}}"#);
                }
            } else if url.contains("/items/file") {
                response(&mut stream, "200 OK", "", r#"{"id":"file","name":"Report.txt","webUrl":"https://tenant.sharepoint.com/Report.txt","file":{"mimeType":"text/plain"}}"#);
            } else if url.contains("/users") {
                response(&mut stream, "200 OK", "", r#"{"value":[],"@odata.nextLink":"https://attacker.example/steal"}"#);
            } else if url.contains("/me") {
                response(&mut stream, "200 OK", "", r#"{"mail":"me@example.com"}"#);
            } else { response(&mut stream, "403 Forbidden", "", "private-test-token"); }
        }
    });
    let list = call(&root, &path, "google", r#"{"version":1,"request":{"operation":"files.list","location":{"kind":"root"},"next":"https://attacker.example/steal"}}"#);
    assert!(list.contains("Proposal"), "{list}");
    let download = call(&root, &path, "google", r#"{"version":1,"request":{"operation":"files.download","id":{"drive":"","item":"doc"}}}"#);
    assert!(download.contains("Proposal.docx") && download.contains("ZXhwb3J0ZWQ="), "{download}");
    let denied = call(&root, &path, "google", r#"{"version":1,"request":{"operation":"files.download","id":{"drive":"","item":"restricted"}}}"#);
    assert!(denied.contains("\"code\":\"denied\""), "{denied}");
    let download = call(&root, &path, "microsoft", r#"{"version":1,"request":{"operation":"files.download","id":{"drive":"drive","item":"file"}}}"#);
    assert!(download.contains("ZG93bmxvYWRlZA=="), "{download}");
    let foreign = call(&root, &path, "microsoft", r#"{"version":1,"request":{"operation":"directory.read"}}"#);
    assert!(foreign.contains("\"code\":\"invalid_request\""), "{foreign}");
    let before = seen.lock().expect("seen").len();
    let malformed = call(&root, &path, "google", r#"{"version":2,"request":{"operation":"files.download","id":{"drive":"","item":"../token"}}}"#);
    assert!(malformed.contains("\"code\":\"invalid_request\""));
    assert_eq!(seen.lock().expect("seen").len(), before);
    for (service, configuration, read) in [
        ("gh", r#"{"client_id":"publisher","client_secret":"registration-secret"}"#, "https://api.github.com/user"),
        ("resend", "{}", "https://api.resend.com/domains?limit=1"),
        ("cloudflare", r#"{"client_id":"publisher","scopes":"zone:read"}"#, "https://api.cloudflare.com/client/v4/accounts?per_page=50&page=1"),
    ] {
        let before = seen.lock().expect("seen").len();
        let result = call(&root, &path, service, &format!(r#"{{"version":1,"request":{{"operation":"auth.login","configuration":{configuration}}}}}"#));
        assert!(result.contains("\"kind\":\"connected\""), "{service}: {result}");
        let verifying = result.find("\"stage\":\"verifying\"").expect("verification progress");
        let connected = result.find("\"kind\":\"connected\"").expect("verified credential");
        assert!(verifying < connected, "{service}: {result}");
        assert!(seen.lock().expect("authenticated reads")[before..].iter().any(|url| url == read));
        if service == "cloudflare" { assert!(result.contains("\"account_id\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"")); }
    }
    let changed = call(&root, &path, "gh", r#"{"version":1,"request":{"operation":"auth.refresh","state":{"registration":{"client_id":"publisher","client_secret":"registration-secret"},"account_id":8,"refresh_token":"saved-refresh"}}}"#);
    assert!(changed.contains("\"code\":\"unauthorized\""));
    let broad = call(&root, &path, "gh", r#"{"version":1,"request":{"operation":"auth.refresh","state":{"registration":{"client_id":"broad","client_secret":"registration-secret"},"account_id":7,"refresh_token":"saved-refresh"}}}"#);
    assert!(broad.contains("\"code\":\"denied\""));
    let refreshed = call(&root, &path, "cloudflare", r#"{"version":1,"request":{"operation":"auth.refresh","state":{"client_id":"publisher","account_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","scopes":"zone:read offline_access","refresh_token":"saved-refresh"}}}"#);
    assert!(refreshed.contains("rotated-refresh"), "{refreshed}");
    let mut stop = TcpStream::connect(addr).expect("stop fixture");
    stop.write_all(b"GET / HTTP/1.1\r\n\r\n").expect("stop request");
    let mut ignored = Vec::new();
    let _ = stop.read_to_end(&mut ignored);
    task.join().expect("fixture completed");
}
