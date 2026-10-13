use std::collections::BTreeMap;
use std::error::Error;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

type TestResult<T = ()> = Result<T, Box<dyn Error + Send + Sync>>;

const ACCOUNT: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const ZONE: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const API_TOKEN: &str = "fake-fixture-only-token";
const TUNNEL_TOKEN: &str = "fixture-tunnel-token-only";
const FOREIGN_TUNNEL: &str = "22222222-2222-4222-8222-222222222222";
const FOREIGN_DNS: &str = "cccccccccccccccccccccccccccccccc";
const COLLISION_DNS: &str = "dddddddddddddddddddddddddddddddd";

fn check(condition: bool, message: impl Into<String>) -> TestResult {
    if condition {
        Ok(())
    } else {
        Err(std::io::Error::other(message.into()).into())
    }
}

fn quoted(value: &str) -> String {
    let mut result = String::from("\"");
    for character in value.chars() {
        match character {
            '"' => result.push_str("\\\""),
            '\\' => result.push_str("\\\\"),
            '\n' => result.push_str("\\n"),
            '\r' => result.push_str("\\r"),
            '\t' => result.push_str("\\t"),
            value if value < ' ' => result.push_str(&format!("\\u{:04x}", value as u32)),
            value => result.push(value),
        }
    }
    result.push('"');
    result
}

fn filter(input: &str, expression: &str) -> TestResult<String> {
    let mut child = Command::new("jq")
        .args(["-rcS", expression])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    match child.stdin.take() {
        Some(mut input_pipe) => input_pipe.write_all(input.as_bytes())?,
        None => return Err(std::io::Error::other("jq has no input pipe").into()),
    }
    let output = child.wait_with_output()?;
    check(output.status.success(), format!("jq rejected fixture JSON: {}", String::from_utf8_lossy(&output.stderr)))?;
    Ok(String::from_utf8(output.stdout)?.trim().to_owned())
}

fn digest(input: &str) -> TestResult<String> {
    let mut child = Command::new("sha256sum")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    match child.stdin.take() {
        Some(mut input_pipe) => input_pipe.write_all(input.as_bytes())?,
        None => return Err(std::io::Error::other("sha256sum has no input pipe").into()),
    }
    let output = child.wait_with_output()?;
    check(output.status.success(), "sha256sum failed")?;
    let output = String::from_utf8(output.stdout)?;
    match output.split_whitespace().next() {
        Some(value) => Ok(value.to_owned()),
        None => Err(std::io::Error::other("sha256sum returned no digest").into()),
    }
}

struct Directory(PathBuf);

impl Directory {
    fn new() -> TestResult<Self> {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let path = std::env::temp_dir().join(format!("ryra-cloudflare-fixture-{}-{nonce}", std::process::id()));
        fs::create_dir(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
        Ok(Self(path))
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            eprintln!("cannot remove fixture directory {}: {error}", self.0.display());
        }
    }
}

#[derive(Clone)]
struct Tunnel {
    id: String,
    name: String,
    config: String,
    deleted: bool,
}

impl Tunnel {
    fn json(&self) -> String {
        format!("{{\"id\":{},\"name\":{},\"account_tag\":\"{ACCOUNT}\",\"config_src\":\"cloudflare\",\"connections\":[],\"deleted_at\":null}}", quoted(&self.id), quoted(&self.name))
    }
}

#[derive(Clone, Debug, PartialEq)]
struct Record {
    id: String,
    name: String,
    kind: String,
    content: String,
    comment: String,
    proxied: bool,
}

impl Record {
    fn json(&self) -> String {
        format!("{{\"id\":{},\"name\":{},\"type\":{},\"content\":{},\"comment\":{},\"proxied\":{},\"ttl\":1}}", quoted(&self.id), quoted(&self.name), quoted(&self.kind), quoted(&self.content), quoted(&self.comment), self.proxied)
    }
}

struct World {
    tunnels: Vec<Tunnel>,
    records: Vec<Record>,
    state: PathBuf,
    create_calls: usize,
    mutations: Vec<String>,
    errors: Vec<String>,
    drop_create_response: bool,
    drop_dns_delete_response: bool,
    active_delete_failures: usize,
}

impl World {
    fn new(state: PathBuf) -> Self {
        Self {
            tunnels: vec![Tunnel {
                id: FOREIGN_TUNNEL.to_owned(),
                name: "unrelated-owner-tunnel".to_owned(),
                config: "{\"ingress\":[{\"hostname\":\"untouched.example.com\",\"service\":\"http://127.0.0.1:9123\"},{\"service\":\"http_status:404\"}],\"warp-routing\":{\"enabled\":false}}".to_owned(),
                deleted: false,
            }],
            records: vec![Record {
                id: FOREIGN_DNS.to_owned(),
                name: "untouched.example.com".to_owned(),
                kind: "CNAME".to_owned(),
                content: format!("{FOREIGN_TUNNEL}.cfargotunnel.com"),
                comment: "unrelated owner".to_owned(),
                proxied: true,
            }],
            state,
            create_calls: 0,
            mutations: Vec::new(),
            errors: Vec::new(),
            drop_create_response: true,
            drop_dns_delete_response: false,
            active_delete_failures: 0,
        }
    }

    fn owned(&self) -> TestResult<&Tunnel> {
        let mut tunnels = self.tunnels.iter().filter(|tunnel| tunnel.id != FOREIGN_TUNNEL && !tunnel.deleted);
        let tunnel = match tunnels.next() {
            Some(tunnel) => tunnel,
            None => return Err(std::io::Error::other("owned tunnel is missing").into()),
        };
        check(tunnels.next().is_none(), "more than one owned tunnel exists")?;
        Ok(tunnel)
    }
}

struct Request {
    method: String,
    path: String,
    query: BTreeMap<String, String>,
    headers: BTreeMap<String, String>,
    body: String,
}

fn decode(value: &str) -> TestResult<String> {
    let mut bytes = Vec::new();
    let mut source = value.bytes();
    while let Some(byte) = source.next() {
        match byte {
            b'+' => bytes.push(b' '),
            b'%' => {
                let digits: String = source.by_ref().take(2).map(char::from).collect();
                check(digits.len() == 2, "truncated URL escape")?;
                bytes.push(u8::from_str_radix(&digits, 16)?);
            }
            byte => bytes.push(byte),
        }
    }
    Ok(String::from_utf8(bytes)?)
}

fn read_request(stream: &mut TcpStream) -> TestResult<Request> {
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut bytes = Vec::new();
    let header_end = loop {
        let mut buffer = [0; 4096];
        let count = stream.read(&mut buffer)?;
        check(count != 0, "request ended before headers")?;
        bytes.extend_from_slice(&buffer[..count]);
        if let Some(offset) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            break offset + 4;
        }
        check(bytes.len() < 64 * 1024, "request headers too large")?;
    };
    let header_text = String::from_utf8(bytes[..header_end].to_vec())?;
    let mut lines = header_text.lines();
    let first = match lines.next() {
        Some(first) => first,
        None => return Err(std::io::Error::other("request line missing").into()),
    };
    let words: Vec<_> = first.split_whitespace().collect();
    check(words.len() == 3, "invalid request line")?;
    let mut headers = BTreeMap::new();
    for line in lines.filter(|line| !line.is_empty()) {
        let (key, value) = match line.split_once(':') {
            Some(pair) => pair,
            None => return Err(std::io::Error::other("invalid request header").into()),
        };
        headers.insert(key.to_ascii_lowercase(), value.trim().to_owned());
    }
    let content_length = match headers.get("content-length") {
        Some(value) => value.parse::<usize>()?,
        None => 0,
    };
    check(content_length < 1024 * 1024, "request body too large")?;
    while bytes.len() - header_end < content_length {
        let mut buffer = [0; 4096];
        let count = stream.read(&mut buffer)?;
        check(count != 0, "request body truncated")?;
        bytes.extend_from_slice(&buffer[..count]);
    }
    let (path, query_string) = match words[1].split_once('?') {
        Some(pair) => pair,
        None => (words[1], ""),
    };
    let mut query = BTreeMap::new();
    for part in query_string.split('&').filter(|part| !part.is_empty()) {
        let (key, value) = match part.split_once('=') {
            Some(pair) => pair,
            None => (part, ""),
        };
        query.insert(decode(key)?, decode(value)?);
    }
    Ok(Request {
        method: words[0].to_owned(),
        path: path.to_owned(),
        query,
        headers,
        body: String::from_utf8(bytes[header_end..header_end + content_length].to_vec())?,
    })
}

enum Response {
    Json(u16, String),
    Disconnect,
}

fn success(result: String) -> Response {
    Response::Json(200, format!("{{\"success\":true,\"errors\":[],\"messages\":[],\"result\":{result}}}"))
}

fn listing(items: Vec<String>) -> Response {
    Response::Json(200, format!("{{\"success\":true,\"errors\":[],\"messages\":[],\"result\":[{}],\"result_info\":{{\"page\":1,\"per_page\":50,\"count\":{},\"total_count\":{},\"total_pages\":1}}}}", items.join(","), items.len(), items.len()))
}

fn missing() -> Response {
    Response::Json(404, "{\"success\":false,\"errors\":[{\"code\":1001,\"message\":\"fixture resource missing\"}],\"result\":null}".to_owned())
}

fn parameter<'a>(request: &'a Request, name: &str) -> TestResult<&'a str> {
    match request.query.get(name) {
        Some(value) => Ok(value),
        None => Err(std::io::Error::other(format!("missing query parameter {name}")).into()),
    }
}

fn handle(world: &mut World, request: Request) -> TestResult<Response> {
    check(request.headers.get("authorization") == Some(&format!("Bearer {API_TOKEN}")), "incorrect API authorization")?;
    check(!request.body.contains(API_TOKEN), "API token escaped into request body")?;
    let path = request.path.as_str();
    let method = request.method.as_str();
    let tunnel_base = format!("/accounts/{ACCOUNT}/cfd_tunnel");
    let dns_base = format!("/zones/{ZONE}/dns_records");
    if method == "GET" && path == "/zones" {
        check(parameter(&request, "account.id")? == ACCOUNT, "zone lookup is not account scoped")?;
        let name = parameter(&request, "name")?;
        return Ok(listing(if name == "example.com" {
            vec![format!("{{\"id\":\"{ZONE}\",\"name\":\"example.com\",\"status\":\"active\",\"type\":\"full\",\"account\":{{\"id\":\"{ACCOUNT}\"}}}}")]
        } else {
            Vec::new()
        }));
    }
    if method == "GET" && path == format!("/zones/{ZONE}/ssl/universal/settings") {
        return Ok(success("{\"enabled\":true}".to_owned()));
    }
    if method == "GET" && path == format!("/zones/{ZONE}/settings/ssl") {
        return Ok(success("{\"id\":\"ssl\",\"value\":\"strict\"}".to_owned()));
    }
    if method == "GET" && path == tunnel_base {
        check(parameter(&request, "is_deleted")? == "false", "tunnel lookup includes deleted tunnels")?;
        check(parameter(&request, "per_page")? == "50", "tunnel lookup is not bounded")?;
        check(parameter(&request, "page")? == "1", "unexpected tunnel page")?;
        let name = parameter(&request, "name")?;
        return Ok(listing(world.tunnels.iter().filter(|tunnel| !tunnel.deleted && tunnel.name == name).map(Tunnel::json).collect()));
    }
    if method == "POST" && path == tunnel_base {
        let name = filter(&request.body, ".name")?;
        check(filter(&request.body, ".config_src")? == "cloudflare", "tunnel is not remotely managed")?;
        let owner = fs::read_to_string(world.state.join("owner"))?;
        let owner = owner.trim();
        check(owner.len() == 32 && owner.bytes().all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()), "owner identity is not private stable lowercase hex")?;
        let hash = digest("ryra/cloudflare\napp.example.com")?;
        check(name == format!("ryra-{owner}-{}", &hash[..32]), "tunnel name is not deterministic for owner/provider/domain")?;
        let claim = fs::read_to_string(world.state.join("claims").join(format!("{hash}.json")))?;
        check(filter(&claim, ".provider")? == "ryra/cloudflare", "claim provider missing before create")?;
        check(filter(&claim, ".account")? == ACCOUNT, "claim account missing before create")?;
        check(filter(&claim, ".zone")? == ZONE, "claim zone missing before create")?;
        check(filter(&claim, ".domain")? == "app.example.com", "claim domain missing before create")?;
        check(filter(&claim, ".hostName")? == "app.localhost", "claim backend Host missing before create")?;
        check(filter(&claim, ".tunnelName")? == name, "claim tunnel anchor missing before create")?;
        check(!world.tunnels.iter().any(|tunnel| !tunnel.deleted && tunnel.name == name), "duplicate tunnel create attempted")?;
        world.create_calls += 1;
        let tunnel = Tunnel {
            id: format!("11111111-1111-4111-8111-{:012x}", world.create_calls),
            name,
            config: "null".to_owned(),
            deleted: false,
        };
        let response = tunnel.json();
        world.mutations.push(format!("create tunnel {}", tunnel.id));
        world.tunnels.push(tunnel);
        if world.drop_create_response {
            world.drop_create_response = false;
            return Ok(Response::Disconnect);
        }
        return Ok(success(response));
    }
    if let Some(rest) = path.strip_prefix(&format!("{tunnel_base}/")) {
        let (id, suffix) = match rest.split_once('/') {
            Some(pair) => pair,
            None => (rest, ""),
        };
        let position = match world.tunnels.iter().position(|tunnel| tunnel.id == id && !tunnel.deleted) {
            Some(position) => position,
            None => return Ok(missing()),
        };
        match (method, suffix) {
            ("GET", "") => return Ok(success(world.tunnels[position].json())),
            ("GET", "configurations") => return Ok(success(format!("{{\"config\":{},\"source\":\"cloudflare\",\"version\":1}}", world.tunnels[position].config))),
            ("GET", "token") => return Ok(success(quoted(TUNNEL_TOKEN))),
            ("PUT", "configurations") => {
                check(id != FOREIGN_TUNNEL, "foreign tunnel configuration overwritten")?;
                let config = filter(&request.body, ".config")?;
                check(filter(&config, ".[\"warp-routing\"].enabled")? == "false", "warp routing must stay disabled")?;
                check(filter(&config, ".ingress[-1].service")? == "http_status:404", "missing final deny route")?;
                let count: usize = filter(&config, ".ingress | length")?.parse()?;
                check(count == 1 || count == 2, "unexpected ingress entries")?;
                if count == 2 {
                    check(filter(&config, ".ingress[0].hostname")? == "app.example.com", "wrong tunnel hostname")?;
                    check(filter(&config, ".ingress[0].originRequest.httpHostHeader")? == "app.localhost", "wrong backend Host header")?;
                    check(filter(&config, ".ingress[0].service")?.starts_with("http://127.0.0.1:"), "backend must remain HTTP loopback")?;
                }
                world.tunnels[position].config = config.clone();
                world.mutations.push(format!("configure tunnel {id}"));
                return Ok(success(format!("{{\"config\":{config},\"source\":\"cloudflare\",\"version\":2}}")));
            }
            ("DELETE", "") => {
                check(id != FOREIGN_TUNNEL, "foreign tunnel deleted")?;
                check(filter(&world.tunnels[position].config, ".ingress")? == "[{\"service\":\"http_status:404\"}]", "tunnel deleted before disabling ingress")?;
                check(!world.records.iter().any(|record| record.content == format!("{id}.cfargotunnel.com")), "tunnel deleted before its DNS records")?;
                if world.active_delete_failures > 0 {
                    world.active_delete_failures -= 1;
                    return Ok(Response::Json(409, "{\"success\":false,\"errors\":[{\"code\":1022,\"message\":\"active connections remain\"}],\"result\":null}".to_owned()));
                }
                world.tunnels[position].deleted = true;
                world.mutations.push(format!("delete tunnel {id}"));
                return Ok(success("null".to_owned()));
            }
            _ => {}
        }
    }
    if method == "GET" && path == dns_base {
        check(parameter(&request, "per_page")? == "50", "DNS lookup is not bounded")?;
        check(parameter(&request, "page")? == "1", "unexpected DNS page")?;
        let name = parameter(&request, "name")?;
        return Ok(listing(world.records.iter().filter(|record| record.name == name).map(Record::json).collect()));
    }
    if method == "POST" && path == dns_base {
        let name = filter(&request.body, ".name")?;
        let tunnel = world.owned()?;
        check(name == "app.example.com", "unexpected DNS hostname created")?;
        check(!world.records.iter().any(|record| record.name == name), "existing DNS record was overwritten")?;
        check(filter(&request.body, ".type")? == "CNAME", "DNS record must be CNAME")?;
        check(filter(&request.body, ".content")? == format!("{}.cfargotunnel.com", tunnel.id), "DNS target differs from owned tunnel")?;
        check(filter(&request.body, ".comment")? == format!("Ryra:{}", tunnel.name), "DNS ownership marker missing")?;
        check(filter(&request.body, ".proxied")? == "true", "DNS record must be proxied")?;
        check(filter(&request.body, ".ttl")? == "1", "DNS TTL must be automatic")?;
        let record = Record {
            id: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee".to_owned(),
            name,
            kind: "CNAME".to_owned(),
            content: format!("{}.cfargotunnel.com", tunnel.id),
            comment: format!("Ryra:{}", tunnel.name),
            proxied: true,
        };
        let response = record.json();
        world.mutations.push(format!("create DNS {}", record.id));
        world.records.push(record);
        return Ok(success(response));
    }
    if method == "DELETE" {
        if let Some(id) = path.strip_prefix(&format!("{dns_base}/")) {
            check(id != FOREIGN_DNS && id != COLLISION_DNS, "foreign DNS deleted")?;
            let position = match world.records.iter().position(|record| record.id == id) {
                Some(position) => position,
                None => return Ok(missing()),
            };
            check(filter(&world.owned()?.config, ".ingress")? == "[{\"service\":\"http_status:404\"}]", "DNS deleted before disabling ingress")?;
            world.records.remove(position);
            world.mutations.push(format!("delete DNS {id}"));
            if world.drop_dns_delete_response {
                world.drop_dns_delete_response = false;
                return Ok(Response::Disconnect);
            }
            return Ok(success(format!("{{\"id\":{}}}", quoted(id))));
        }
    }
    Err(std::io::Error::other(format!("unexpected Cloudflare request {method} {path}")).into())
}

struct Fixture {
    url: String,
    world: Arc<Mutex<World>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Fixture {
    fn start(state: PathBuf) -> TestResult<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let url = format!("http://{}", listener.local_addr()?);
        listener.set_nonblocking(true)?;
        let world = Arc::new(Mutex::new(World::new(state)));
        let stop = Arc::new(AtomicBool::new(false));
        let thread_world = Arc::clone(&world);
        let thread_stop = Arc::clone(&stop);
        let thread = thread::spawn(move || {
            while !thread_stop.load(Ordering::SeqCst) {
                let mut stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    Err(error) => {
                        if let Ok(mut world) = thread_world.lock() {
                            world.errors.push(format!("accept: {error}"));
                        }
                        break;
                    }
                };
                let response = read_request(&mut stream).and_then(|request| {
                    let mut world = thread_world.lock().map_err(|_| std::io::Error::other("fixture lock poisoned"))?;
                    handle(&mut world, request)
                });
                let response = match response {
                    Ok(response) => response,
                    Err(error) => {
                        if let Ok(mut world) = thread_world.lock() {
                            world.errors.push(error.to_string());
                        }
                        Response::Json(500, "{\"success\":false,\"errors\":[{\"message\":\"fixture assertion failed\"}]}".to_owned())
                    }
                };
                if let Response::Json(status, body) = response {
                    let packet = format!("HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    if let Err(error) = stream.write_all(packet.as_bytes()) {
                        if let Ok(mut world) = thread_world.lock() {
                            world.errors.push(format!("response: {error}"));
                        }
                    }
                }
            }
        });
        Ok(Self { url, world, stop, thread: Some(thread) })
    }

    fn inspect<T>(&self, operation: impl FnOnce(&mut World) -> TestResult<T>) -> TestResult<T> {
        let mut world = self.world.lock().map_err(|_| std::io::Error::other("fixture lock poisoned"))?;
        check(world.errors.is_empty(), format!("fixture rejected requests: {:?}", world.errors))?;
        operation(&mut world)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            if thread.join().is_err() {
                eprintln!("Cloudflare fixture server panicked");
            }
        }
    }
}

fn run(script: &Path, directory: &Path, fixture: &Fixture) -> TestResult<Output> {
    let output = Command::new("timeout")
        .args(["30s", "bash"])
        .arg(script)
        .arg(directory.join("manifest.json"))
        .arg(directory.join("state"))
        .arg(directory.join("runtime"))
        .env_clear()
        .env("PATH", std::env::var("PATH")?)
        .env("CLOUDFLARE_ACCOUNT_ID", ACCOUNT)
        .env("CLOUDFLARE_API_TOKEN", API_TOKEN)
        .env("RYRA_CLOUDFLARE_API_URL", &fixture.url)
        .output()?;
    check(!String::from_utf8_lossy(&output.stdout).contains(API_TOKEN), "API token leaked to stdout")?;
    check(!String::from_utf8_lossy(&output.stderr).contains(API_TOKEN), "API token leaked to stderr")?;
    fixture.inspect(|_| Ok(()))?;
    Ok(output)
}

fn succeeded(output: &Output, stage: &str) -> TestResult {
    check(output.status.success(), format!("{stage} failed: {}", String::from_utf8_lossy(&output.stderr)))
}

fn manifest(directory: &Path, port: u16, collision: bool) -> TestResult {
    fs::write(directory.join("manifest.json"), format!("{{\"provider\":\"ryra/cloudflare\",\"sites\":[{{\"domain\":\"app.example.com\",\"port\":{port},\"hostName\":\"app.localhost\"}}{}]}}", if collision { ",{\"domain\":\"collision.example.com\",\"port\":8113,\"hostName\":\"collision.localhost\"}" } else { "" }))?;
    Ok(())
}

fn no_account_token(path: &Path) -> TestResult {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            no_account_token(&entry.path())?;
        } else {
            check(!String::from_utf8_lossy(&fs::read(entry.path())?).contains(API_TOKEN), format!("API token persisted in {}", entry.path().display()))?;
        }
    }
    Ok(())
}

#[test]
fn interrupted_provider_lifecycle_is_owned_and_convergent() -> TestResult {
    let directory = Directory::new()?;
    let script = match std::env::var_os("RYRA_CLOUDFLARE_RUNTIME") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(file!()).with_file_name("runtime.sh"),
    };
    check(script.is_file(), format!("provider runtime missing: {}", script.display()))?;
    fs::create_dir(directory.0.join("state"))?;
    fs::create_dir(directory.0.join("runtime"))?;
    let fixture = Fixture::start(directory.0.join("state"))?;
    manifest(&directory.0, 8083, false)?;

    let interrupted = run(&script, &directory.0, &fixture)?;
    check(!interrupted.status.success(), "disconnected create must report unsuccessful provisioning")?;
    fixture.inspect(|world| {
        check(world.create_calls == 1, "interrupted POST did not create exactly once")?;
        check(world.owned()?.config == "null", "interrupted create unexpectedly configured tunnel")
    })?;
    succeeded(&run(&script, &directory.0, &fixture)?, "retry after interrupted create")?;
    let expected_hash = digest("ryra/cloudflare\napp.example.com")?;
    let claim = directory.0.join("state/claims").join(format!("{expected_hash}.json"));
    let token = directory.0.join("runtime").join(format!("{expected_hash}.token"));
    check(fs::read_to_string(&token)?.trim() == TUNNEL_TOKEN, "cloudflared did not receive the tunnel token")?;
    check(fs::metadata(&token)?.permissions().mode() & 0o077 == 0, "tunnel token is readable outside its owner")?;
    check(claim.is_file(), "successful setup lost its durable ownership claim")?;
    fixture.inspect(|world| {
        check(world.create_calls == 1, "retry created a duplicate tunnel")?;
        check(filter(&world.owned()?.config, ".ingress[0].service")? == "http://127.0.0.1:8083", "wrong backend route")?;
        check(world.records.iter().filter(|record| record.name == "app.example.com").count() == 1, "setup did not create exactly one DNS record")
    })?;
    succeeded(&run(&script, &directory.0, &fixture)?, "unchanged setup")?;
    no_account_token(&directory.0)?;
    fixture.inspect(|world| check(world.create_calls == 1, "unchanged setup duplicated its tunnel"))?;

    let unrelated_tunnel = fixture.inspect(|world| Ok(world.tunnels[0].config.clone()))?;
    let unrelated_record = fixture.inspect(|world| Ok(world.records[0].clone()))?;
    manifest(&directory.0, 8094, false)?;
    succeeded(&run(&script, &directory.0, &fixture)?, "backend port update")?;
    fixture.inspect(|world| {
        check(world.create_calls == 1, "backend change replaced the owned tunnel")?;
        check(filter(&world.owned()?.config, ".ingress[0].service")? == "http://127.0.0.1:8094", "backend change left the old route")
    })?;

    let collision_record = Record {
        id: COLLISION_DNS.to_owned(),
        name: "collision.example.com".to_owned(),
        kind: "A".to_owned(),
        content: "203.0.113.7".to_owned(),
        comment: "managed by somebody else".to_owned(),
        proxied: false,
    };
    fixture.inspect(|world| {
        world.records.push(collision_record.clone());
        Ok(())
    })?;
    let before_collision = fixture.inspect(|world| Ok(world.mutations.clone()))?;
    manifest(&directory.0, 8094, true)?;
    let collision = run(&script, &directory.0, &fixture)?;
    check(!collision.status.success(), "foreign DNS collision was accepted")?;
    fixture.inspect(|world| {
        check(world.mutations == before_collision, "collision caused a mutation before validation finished")?;
        check(world.records.iter().any(|record| record == &collision_record), "foreign DNS collision was overwritten")?;
        check(world.create_calls == 1, "collision created an orphan tunnel")
    })?;

    manifest(&directory.0, 8094, false)?;
    let saved_claim = fs::read(&claim)?;
    fs::remove_file(&claim)?;
    let unclaimed = run(&script, &directory.0, &fixture)?;
    check(!unclaimed.status.success(), "matching tunnel was adopted without its ownership claim")?;
    fixture.inspect(|world| check(world.mutations == before_collision, "unclaimed tunnel refusal mutated resources"))?;
    fs::write(&claim, saved_claim)?;
    fs::set_permissions(&claim, fs::Permissions::from_mode(0o600))?;

    let safe_config = fixture.inspect(|world| Ok(world.owned()?.config.clone()))?;
    let foreign_config = filter(&safe_config, ".ingress |= ([.[0], {hostname:\"foreign.example.net\",service:\"http://127.0.0.1:9999\"}, .[1]])")?;
    fixture.inspect(|world| {
        let tunnel = match world.tunnels.iter_mut().find(|tunnel| tunnel.id != FOREIGN_TUNNEL && !tunnel.deleted) {
            Some(tunnel) => tunnel,
            None => return Err(std::io::Error::other("owned tunnel missing before foreign route simulation").into()),
        };
        tunnel.config = foreign_config.clone();
        Ok(())
    })?;
    let foreign_route = run(&script, &directory.0, &fixture)?;
    check(!foreign_route.status.success(), "foreign tunnel ingress was accepted")?;
    fixture.inspect(|world| {
        check(world.mutations == before_collision, "foreign ingress refusal mutated resources")?;
        check(world.owned()?.config == foreign_config, "foreign tunnel ingress was overwritten")?;
        let tunnel = match world.tunnels.iter_mut().find(|tunnel| tunnel.id != FOREIGN_TUNNEL && !tunnel.deleted) {
            Some(tunnel) => tunnel,
            None => return Err(std::io::Error::other("owned tunnel missing after foreign route refusal").into()),
        };
        tunnel.config = safe_config;
        world.drop_dns_delete_response = true;
        world.active_delete_failures = 1;
        Ok(())
    })?;

    fs::write(directory.0.join("manifest.json"), "{\"provider\":\"ryra/cloudflare\",\"sites\":[]}")?;
    let interrupted_cleanup = run(&script, &directory.0, &fixture)?;
    check(!interrupted_cleanup.status.success(), "disconnected DNS deletion did not report incomplete cleanup")?;
    check(claim.is_file(), "interrupted cleanup discarded the ownership claim")?;
    check(!token.exists(), "removed site retained its local tunnel credential")?;
    fixture.inspect(|world| {
        check(filter(&world.owned()?.config, ".ingress")? == "[{\"service\":\"http_status:404\"}]", "interrupted cleanup left a live hostname route")?;
        check(!world.records.iter().any(|record| record.name == "app.example.com"), "interrupted DNS deletion did not take effect")
    })?;

    let active_cleanup = run(&script, &directory.0, &fixture)?;
    check(!active_cleanup.status.success(), "active tunnel deletion refusal was ignored")?;
    check(claim.is_file(), "active tunnel cleanup lost its retry anchor")?;
    succeeded(&run(&script, &directory.0, &fixture)?, "cleanup retry after connector exits")?;
    check(!claim.exists(), "completed cleanup retained an ownership claim")?;
    check(!token.exists(), "completed cleanup retained a tunnel credential")?;
    fixture.inspect(|world| {
        check(world.tunnels.iter().all(|tunnel| tunnel.id == FOREIGN_TUNNEL || tunnel.deleted), "cleanup leaked its tunnel")?;
        check(world.records.len() == 2, "cleanup removed or created unrelated records")?;
        check(world.records.contains(&unrelated_record), "cleanup changed unrelated DNS")?;
        check(world.records.contains(&collision_record), "cleanup changed previously colliding DNS")?;
        check(world.tunnels.iter().any(|tunnel| tunnel.id == FOREIGN_TUNNEL && !tunnel.deleted && tunnel.config == unrelated_tunnel), "cleanup changed the unrelated tunnel")?;
        check(world.create_calls == 1, "lifecycle created duplicate tunnels")
    })?;
    no_account_token(&directory.0)?;
    let idle = Command::new("timeout")
        .args(["30s", "bash"])
        .arg(&script)
        .arg(directory.0.join("manifest.json"))
        .arg(directory.0.join("state"))
        .arg(directory.0.join("runtime"))
        .env_clear()
        .env("PATH", std::env::var("PATH")?)
        .output()?;
    succeeded(&idle, "drained provider without an unused connection")?;
    Ok(())
}
