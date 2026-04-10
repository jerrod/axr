# FastAPI Security Checklist

Rules for the security reviewer when analyzing FastAPI code. Each rule is a check to run against the changed files.

## Input Validation & Injection

1. **Pydantic model bypass:** Check for endpoints accepting `dict` or `Any` instead of typed Pydantic models. `Grep: "def .*(request:\s*(dict|Any|Body))"` — all request bodies must use Pydantic models with field constraints.
2. **Raw SQL injection:** `Grep: "text\(|execute\(|raw\("` — all database queries must use parameterized statements or ORM methods, never string formatting with user input.
3. **ORM filter injection:** `Grep: "filter\(.*format\(|filter\(.*%s|filter\(.*\+\s*"` — ORM filters must use keyword arguments, not string interpolation.
4. **Template injection:** `Grep: "HTMLResponse|Jinja2Templates"` — verify user input is not interpolated into HTML templates without escaping. Check that `autoescape=True` is set on Jinja2 environments.
5. **Path parameter injection:** `Grep: "Path\("` — verify path parameters have validation constraints (regex, min/max length) when used in file operations or database lookups.
6. **Request body size:** `Grep: "UploadFile|File\("` — verify `max_length` or equivalent size limits on file upload fields. Check for `file.read()` without size guards.
7. **JSON schema bypass:** Check for endpoints using `Request.json()` directly instead of Pydantic model parsing — this skips validation entirely.

## Authentication & Sessions

8. **Missing auth dependency:** Check new endpoints for `Depends(get_current_user)` or equivalent auth dependency. Endpoints without auth must be explicitly documented as public.
9. **JWT validation:** `Grep: "jwt.decode|jose.jwt"` — verify `algorithms` parameter is explicitly set (not defaulting), `verify_exp=True`, and audience/issuer are validated.
10. **Password hashing:** `Grep: "passlib|bcrypt|argon2|pbkdf2"` — verify passwords are hashed with a strong algorithm. `Grep: "md5|sha1|sha256"` for password contexts is a finding.
11. **Session token storage:** `Grep: "Set-Cookie|response.set_cookie"` — verify `httponly=True`, `secure=True`, `samesite="lax"` or `"strict"` on session cookies.
12. **OAuth state parameter:** `Grep: "oauth|OAuth"` — verify state parameter is generated, stored, and validated to prevent CSRF in OAuth flows.

## CORS / CSRF

13. **Wildcard CORS:** `Grep: "allow_origins.*\*|CORSMiddleware"` — `allow_origins=["*"]` with `allow_credentials=True` is a critical finding. Origins must be explicitly listed when credentials are allowed.
14. **CORS method restriction:** Verify `allow_methods` is restricted to needed methods, not `["*"]`.
15. **Missing CORS middleware:** If the API serves browser clients, verify CORSMiddleware is installed.

## File Handling

16. **Path traversal:** `Grep: "open\(|Path\(|pathlib"` — verify user-supplied filenames are sanitized. Check for `../` traversal in file paths constructed from user input.
17. **File read without limits:** `Grep: "\.read\(\)|\.read\(-1\)"` — file reads must specify a max size to prevent memory exhaustion.
18. **Temp file cleanup:** `Grep: "NamedTemporaryFile|tempfile"` — verify temp files are cleaned up in finally blocks or use context managers.
19. **File type validation:** Verify uploaded files are validated by content type (magic bytes), not just extension.

## Secrets & Configuration

20. **Debug mode:** `Grep: "debug=True|--reload"` — verify debug mode and auto-reload are disabled in production configuration.
21. **Secret in code:** `Grep: "SECRET_KEY|JWT_SECRET|API_KEY|PASSWORD"` — verify secrets are loaded from environment variables, not hardcoded.
22. **Verbose errors:** `Grep: "traceback|exc_info|detail=str\(e\)"` — verify stack traces and internal error details are not returned to clients in production.

## Rate Limiting & DoS

23. **Missing rate limiting:** Check auth endpoints (login, register, password reset) for rate limiting middleware or decorators. `Grep: "slowapi|RateLimiter|rate_limit"`.
24. **Unbounded queries:** `Grep: "\.all\(\)|\.filter\("` — verify list endpoints have pagination limits (`limit`, `offset`, or `skip`/`take`).
25. **Large payload:** `Grep: "Body\("` — verify request body size limits are set via middleware or field constraints.

## Dependency Injection

26. **Dependency override in production:** `Grep: "dependency_overrides"` — dependency overrides must only exist in test code, never in production paths.
27. **Background task secrets:** `Grep: "BackgroundTasks|add_task"` — verify background tasks do not receive raw secrets as arguments (use config references instead).

## Serialization & Response Safety

28. **Response model filtering:** `Grep: "response_model"` — verify endpoints returning database models use a response model to filter sensitive fields (password hashes, internal IDs, admin flags). Returning ORM objects directly leaks schema.
29. **Enum coercion:** `Grep: "Enum|IntEnum|StrEnum"` — verify Pydantic enum fields reject invalid values. Check for `use_enum_values=True` which converts to raw values and loses validation.
30. **Recursive model depth:** `Grep: "model_validator|field_validator"` — verify self-referencing models have a max depth to prevent stack overflow via deeply nested payloads.
31. **Custom JSON encoder:** `Grep: "json_encoder|JSONEncoder|jsonable_encoder"` — verify custom encoders do not serialize sensitive fields (datetime precision leaks, decimal precision).

## Middleware & Lifecycle

32. **Middleware ordering:** `Grep: "add_middleware"` — verify security middleware (CORS, TrustedHost, HTTPSRedirect) is added in the correct order. CORS must be added last (processes first).
33. **TrustedHost middleware:** `Grep: "TrustedHostMiddleware"` — verify `allowed_hosts` is configured for production to prevent host header attacks.
34. **HTTPS redirect:** `Grep: "HTTPSRedirectMiddleware"` — verify HTTPS redirect is enabled in production deployments.
35. **Startup/shutdown events:** `Grep: "on_event|lifespan"` — verify startup events do not log secrets and shutdown events properly close database connections.

## Logging & Monitoring

36. **PII in logs:** `Grep: "logger\.|logging\."` — verify log statements do not include passwords, tokens, credit card numbers, or request bodies containing PII.
37. **Request logging:** Verify request logging middleware redacts sensitive headers (`Authorization`, `Cookie`, `X-API-Key`) before writing to logs.
38. **Error response detail:** `Grep: "HTTPException.*detail"` — verify `HTTPException` detail messages do not include internal paths, SQL errors, or stack traces.

## WebSocket Security

39. **WebSocket auth:** `Grep: "WebSocket|websocket"` — verify WebSocket endpoints validate authentication on connection, not just on the initial HTTP upgrade.
40. **WebSocket input validation:** Verify data received on WebSocket connections is validated before processing. Raw JSON from clients must be parsed and schema-validated.
41. **WebSocket rate limiting:** Verify WebSocket connections have message rate limits to prevent flooding.

## Database & ORM Safety

42. **Connection string exposure:** `Grep: "DATABASE_URL|create_engine|AsyncSession"` — verify database connection strings are loaded from environment, never logged, and use SSL for remote connections.
43. **Transaction isolation:** `Grep: "session\.commit|session\.flush"` — verify write operations use appropriate transaction isolation and handle conflicts (optimistic locking or serializable isolation).
44. **Bulk operations:** `Grep: "bulk_insert|bulk_update|execute_many"` — verify bulk operations validate all items, not just the first, and respect size limits.

## Security Headers

45. **Missing security headers:** Verify responses include `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: strict-origin-when-cross-origin`. Use middleware to set these globally.
46. **Content-Security-Policy:** If the API serves HTML (admin panels, docs), verify CSP headers are set with restrictive directives. `unsafe-inline` and `unsafe-eval` are findings.
47. **Cache-Control on sensitive endpoints:** `Grep: "Cache-Control|cache_control"` — verify responses containing sensitive data include `Cache-Control: no-store` to prevent browser caching.

## SSRF & External Requests

48. **SSRF via user URLs:** `Grep: "httpx\.|aiohttp\.|requests\.(get|post)"` — verify HTTP client requests do not use user-controlled URLs without validation. Block internal IP ranges (127.0.0.1, 10.x, 172.16-31.x, 169.254.x, ::1).
49. **Webhook URL validation:** `Grep: "webhook|callback_url|notify_url"` — verify webhook destination URLs are validated against an allowlist or at minimum block internal networks.
50. **DNS rebinding:** When validating URLs, resolve the hostname and check the IP address, not just the hostname string — DNS rebinding can map public hostnames to internal IPs.
