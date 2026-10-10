# Django otherwise constructs HTTP OIDC callbacks behind the HTTPS terminator.
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
