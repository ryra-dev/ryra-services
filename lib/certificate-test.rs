use std::error::Error;
use std::fs::{self, File};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

type TestResult<T = ()> = Result<T, Box<dyn Error>>;

const HOST: &str = "service.example.test";

struct Directory(PathBuf);

impl Directory {
    fn new() -> TestResult<Self> {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let path = std::env::temp_dir().join(format!(
            "ryra-certificate-fixture-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir(&path)?;
        let directory = Self(path);
        fs::set_permissions(&directory.0, fs::Permissions::from_mode(0o700))?;
        Ok(directory)
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_dir_all(&self.0) {
            eprintln!(
                "cannot remove fixture directory {}: {error}",
                self.0.display()
            );
        }
    }
}

fn openssl(directory: &Path, arguments: &[&str]) -> TestResult {
    let output = Command::new("openssl")
        .current_dir(directory)
        .args(arguments)
        .stdin(Stdio::null())
        .output()?;
    assert!(
        output.status.success(),
        "OpenSSL fixture failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(())
}

fn leaf(directory: &Path, name: &str, algorithm: &str, dates: &[&str]) -> TestResult {
    let key = format!("{name}.key");
    let request = format!("{name}.csr");
    let certificate = format!("{name}.pem");
    let mut arguments = vec![
        "req",
        "-new",
        "-newkey",
        algorithm,
        "-nodes",
        "-keyout",
        &key,
        "-out",
        &request,
        "-subj",
        "/CN=fallback.example.test",
    ];
    if algorithm == "ec" {
        arguments.extend(["-pkeyopt", "ec_paramgen_curve:prime256v1"]);
    }
    openssl(directory, &arguments)?;
    fs::set_permissions(directory.join(&key), fs::Permissions::from_mode(0o640))?;
    let mut arguments = vec![
        "ca",
        "-batch",
        "-notext",
        "-config",
        "ca.conf",
        "-in",
        &request,
        "-out",
        &certificate,
    ];
    arguments.extend_from_slice(dates);
    openssl(directory, &arguments)?;
    let mut chain = fs::read(directory.join(&certificate))?;
    chain.extend(fs::read(directory.join("ca.pem"))?);
    fs::write(directory.join(format!("{name}-fullchain.pem")), chain)?;
    Ok(())
}

fn validate(script: &Path, host: &str, certificate: &Path, key: &Path) -> TestResult<Output> {
    let mut child = Command::new("bash")
        .arg(script)
        .args([host.as_ref(), certificate.as_os_str(), key.as_os_str()])
        .env("LC_ALL", "C")
        .env("RYRA_KEYSTORE", "off")
        .env("RYRA_PRESENCE", "off")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let started = Instant::now();
    while child.try_wait()?.is_none() {
        if started.elapsed() > Duration::from_secs(5) {
            child.kill()?;
            child.wait()?;
            return Err("certificate check timed out, possibly waiting for a password".into());
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(child.wait_with_output()?)
}

fn check(
    script: &Path,
    host: &str,
    certificate: &Path,
    key: &Path,
    reason: Option<&str>,
) -> TestResult {
    let before_certificate = fs::read(certificate).ok();
    let before_key = fs::read(key).ok();
    let before_mode = fs::metadata(key)
        .ok()
        .map(|metadata| metadata.permissions().mode());
    let output = validate(script, host, certificate, key)?;
    let message = String::from_utf8(output.stderr)?;
    assert!(
        output.stdout.is_empty(),
        "validator printed unexpected output"
    );
    match reason {
        None => assert!(output.status.success() && message.is_empty(), "{message}"),
        Some(reason) => {
            assert!(!output.status.success(), "accepted {reason}");
            assert!(
                message.contains(reason),
                "missing reason {reason}: {message}"
            );
            assert!(message.contains(host), "missing hostname: {message}");
            assert!(
                message.contains(&certificate.display().to_string()),
                "missing certificate path: {message}"
            );
            assert!(
                message.contains(&key.display().to_string()),
                "missing key path: {message}"
            );
            assert!(
                !message.contains("fixture-password") && !message.contains("-----BEGIN"),
                "secret output"
            );
        }
    }
    assert_eq!(
        fs::read(certificate).ok(),
        before_certificate,
        "certificate changed"
    );
    assert_eq!(fs::read(key).ok(), before_key, "key changed");
    assert_eq!(
        fs::metadata(key)
            .ok()
            .map(|metadata| metadata.permissions().mode()),
        before_mode,
        "key mode changed"
    );
    Ok(())
}

#[test]
fn supplied_certificates_validate_real_files_and_replacements() -> TestResult {
    let script = std::env::current_dir()?.join("lib/certificate-check.sh");
    assert!(
        script.is_file(),
        "run this test from the ryra-services repository"
    );
    let directory = Directory::new()?;
    let root = &directory.0;
    openssl(
        root,
        &[
            "req",
            "-x509",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:prime256v1",
            "-nodes",
            "-keyout",
            "ca.key",
            "-out",
            "ca.pem",
            "-days",
            "2",
            "-subj",
            "/CN=Private fixture CA",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
        ],
    )?;
    fs::write(root.join("index"), "")?;
    fs::write(root.join("serial"), "01\n")?;
    fs::write(
        root.join("ca.conf"),
        format!(
            "[ca]\ndefault_ca=fixture\n[fixture]\ndatabase=index\nserial=serial\nnew_certs_dir=.\ncertificate=ca.pem\nprivate_key=ca.key\ndefault_md=sha256\ndefault_days=1\nunique_subject=no\npolicy=policy\nx509_extensions=server\n[policy]\ncommonName=supplied\n[server]\nsubjectAltName=DNS:{HOST}\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
        ),
    )?;
    leaf(root, "rsa", "rsa:2048", &[])?;
    leaf(root, "ec", "ec", &[])?;
    let certificate = root.join("fullchain.pem");
    let key = root.join("key.pem");
    fs::copy(root.join("rsa-fullchain.pem"), &certificate)?;
    fs::copy(root.join("rsa.key"), &key)?;
    check(&script, HOST, &certificate, &key, None)?;
    check(
        &script,
        "wrong.example.test",
        &certificate,
        &key,
        Some("hostname"),
    )?;
    check(
        &script,
        "fallback.example.test",
        &certificate,
        &key,
        Some("hostname"),
    )?;
    check(
        &script,
        HOST,
        &certificate,
        &root.join("ec.key"),
        Some("does not match"),
    )?;
    fs::copy(root.join("ec-fullchain.pem"), &certificate)?;
    fs::copy(root.join("ec.key"), &key)?;
    check(&script, HOST, &certificate, &key, None)?;
    openssl(
        root,
        &[
            "pkey",
            "-in",
            "ec.key",
            "-ec_conv_form",
            "compressed",
            "-ec_param_enc",
            "explicit",
            "-out",
            "alternate-ec.key",
        ],
    )?;
    fs::set_permissions(
        root.join("alternate-ec.key"),
        fs::Permissions::from_mode(0o640),
    )?;
    check(
        &script,
        HOST,
        &certificate,
        &root.join("alternate-ec.key"),
        None,
    )?;
    let key_link = root.join("key-link.pem");
    symlink(&key, &key_link)?;
    check(&script, HOST, &certificate, &key_link, None)?;

    for mode in [0o644, 0o602, 0o606, 0o660] {
        fs::set_permissions(&key, fs::Permissions::from_mode(mode))?;
        check(&script, HOST, &certificate, &key_link, Some("permissions"))?;
    }
    fs::set_permissions(&key, fs::Permissions::from_mode(0o600))?;
    check(&script, HOST, &certificate, &key, None)?;
    fs::set_permissions(&key, fs::Permissions::from_mode(0o000))?;
    if File::open(&key).is_err() {
        check(&script, HOST, &certificate, &key, Some("readable"))?;
    } else {
        eprintln!("unreadable-file check requires a user without permission bypass privileges");
    }
    fs::set_permissions(&key, fs::Permissions::from_mode(0o640))?;
    fs::set_permissions(&certificate, fs::Permissions::from_mode(0o000))?;
    if File::open(&certificate).is_err() {
        check(&script, HOST, &certificate, &key, Some("readable"))?;
    }
    fs::set_permissions(&certificate, fs::Permissions::from_mode(0o644))?;
    check(
        &script,
        HOST,
        &root.join("missing.pem"),
        &key,
        Some("missing"),
    )?;
    check(
        &script,
        HOST,
        &certificate,
        &root.join("missing.key"),
        Some("missing"),
    )?;
    check(&script, HOST, root, &key, Some("regular file"))?;
    check(&script, HOST, &certificate, root, Some("regular file"))?;

    for malformed in [
        "",
        "not a certificate\n",
        "-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----\n",
    ] {
        fs::write(&certificate, malformed)?;
        check(&script, HOST, &certificate, &key, Some("PEM"))?;
    }
    let valid_chain = fs::read_to_string(root.join("ec-fullchain.pem"))?;
    for suffix in [
        "-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----\n",
        "-----BEGIN CERTIFICATE-----\ntruncated\n",
        "unexpected trailing content\n",
    ] {
        fs::write(&certificate, format!("{valid_chain}{suffix}"))?;
        check(&script, HOST, &certificate, &key, Some("PEM"))?;
    }
    fs::write(&certificate, valid_chain.replace('\n', "\r\n"))?;
    check(&script, HOST, &certificate, &key, None)?;
    fs::write(&certificate, &valid_chain)?;
    fs::write(&key, "invalid fixture key, never print this\n")?;
    check(&script, HOST, &certificate, &key, Some("private key"))?;
    fs::copy(root.join("ec.key"), &key)?;

    for (name, dates, reason) in [
        (
            "expired",
            [
                "-startdate",
                "20000101000000Z",
                "-enddate",
                "20000102000000Z",
            ],
            "expired",
        ),
        (
            "future",
            [
                "-startdate",
                "21000101000000Z",
                "-enddate",
                "21000102000000Z",
            ],
            "not yet valid",
        ),
    ] {
        leaf(root, name, "ec", &dates)?;
        check(
            &script,
            HOST,
            &root.join(format!("{name}-fullchain.pem")),
            &root.join(format!("{name}.key")),
            Some(reason),
        )?;
    }
    for (name, password, traditional) in [
        ("encrypted.key", "pass:fixture-password", false),
        ("empty-password.key", "pass:", false),
        ("traditional.key", "pass:fixture-password", true),
    ] {
        let mut arguments = vec![
            "pkey", "-in", "ec.key", "-aes256", "-passout", password, "-out", name,
        ];
        if traditional {
            arguments.push("-traditional");
        }
        openssl(root, &arguments)?;
        fs::set_permissions(root.join(name), fs::Permissions::from_mode(0o640))?;
        check(
            &script,
            HOST,
            &certificate,
            &root.join(name),
            Some("unencrypted"),
        )?;
        if password == "pass:" {
            let original = fs::read_to_string(root.join(name))?;
            for header in [
                "-----BEGIN ENCRYPTED PRIVATE KEY----- \t\n",
                "\u{feff}-----BEGIN ENCRYPTED PRIVATE KEY-----\n",
            ] {
                let padded = original.replace("-----BEGIN ENCRYPTED PRIVATE KEY-----\n", header);
                fs::write(root.join(name), padded)?;
                check(
                    &script,
                    HOST,
                    &certificate,
                    &root.join(name),
                    Some("unencrypted"),
                )?;
            }
        }
    }
    Ok(())
}
