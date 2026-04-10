# Express Security Checklist

Rules for the security reviewer when analyzing Express.js code. Each rule is a check to run against the changed files.

## Input Validation & Injection

1. **SQL injection via concatenation:** `Grep: "query\(.*\+|query\(.*\$\{|query\(.*concat"` — all database queries must use parameterized statements or prepared queries, never string concatenation.
2. **NoSQL injection:** `Grep: "find\(.*req\.(body|query|params)|findOne\(.*req\."` — verify MongoDB queries do not pass raw user input. Use schema validation or sanitize with `mongo-sanitize`.
3. **XSS via res.send:** `Grep: "res\.send\(.*req\.|res\.write\(.*req\."` — verify user input is never sent directly in responses without sanitization.
4. **Command injection:** `Grep: "exec\(|execSync\(|spawn\("` — verify `child_process` calls do not include user-controlled input. Use `execFile` with argument arrays instead of `exec` with shell strings.
5. **Template injection:** `Grep: "render\(.*req\."` — verify template engines have autoescaping enabled and user input is not used as template names or in raw blocks.
6. **eval() usage:** `Grep: "eval\(|new Function\(|setTimeout\(.*req\.|setInterval\(.*req\."` — `eval()`, `new Function()`, and string-based `setTimeout`/`setInterval` with user input are critical findings.
7. **Path traversal:** `Grep: "req\.(params|query|body).*path\.|\.join\(.*req\."` — verify user-supplied paths are resolved with `path.resolve` and validated against an allowed base directory.

## Authentication & Sessions

8. **Session configuration:** `Grep: "session\(|express-session"` — verify: `secret` is from environment, `cookie.secure` is `true`, `cookie.httpOnly` is `true`, `cookie.sameSite` is `'lax'` or `'strict'`, `resave` is `false`, `saveUninitialized` is `false`.
9. **Cookie flags:** `Grep: "res\.cookie\(|cookie\("` — verify all cookies set `secure: true`, `httpOnly: true`, `sameSite: 'lax'` in production.
10. **JWT validation:** `Grep: "jsonwebtoken|jwt\.verify|jwt\.sign"` — verify `algorithms` is explicitly set (not defaulting), expiration is checked, and audience/issuer are validated.
11. **Auth middleware:** Check new routes for authentication middleware. Unprotected routes must be explicitly documented.
12. **Password hashing:** `Grep: "bcrypt|argon2|scrypt|pbkdf2"` — verify passwords use strong hashing. `Grep: "md5|sha1|sha256|createHash"` in password contexts is a finding.

## CORS / CSRF

13. **CORS wildcard:** `Grep: "cors\(|origin:\s*true|origin.*\*"` — `origin: true` or `origin: '*'` with `credentials: true` is a critical finding. Origins must be explicitly listed.
14. **CORS configuration:** Verify `cors()` middleware specifies `origin`, `methods`, and `allowedHeaders` explicitly.
15. **CSRF protection:** `Grep: "csurf|csrf"` — verify CSRF protection is enabled for state-changing endpoints. API-only services using token auth may skip CSRF but must document this.

## Security Headers

16. **Helmet middleware:** `Grep: "helmet\(\)|require.*helmet|import.*helmet"` — verify `helmet()` is used and configured. Missing helmet is a medium finding.
17. **Content Security Policy:** `Grep: "contentSecurityPolicy|CSP"` — verify CSP is set with restrictive directives. `unsafe-inline` and `unsafe-eval` are findings.
18. **X-Powered-By:** `Grep: "x-powered-by|disable.*x-powered-by"` — verify the `X-Powered-By` header is disabled (helmet does this by default).

## File Handling

19. **Static file path traversal:** `Grep: "express\.static\("` — verify static file serving uses an absolute path with `path.join(__dirname, 'public')`, not a relative path or user-controlled directory.
20. **Upload size limits:** `Grep: "multer|busboy|formidable"` — verify file upload middleware has size limits configured (`limits: { fileSize: ... }`).
21. **Upload file type:** Verify uploaded files are validated by MIME type and magic bytes, not just extension.

## Rate Limiting & DoS

22. **Body parser limits:** `Grep: "json\(\)|urlencoded\(|bodyParser"` — verify `limit` option is set on body parsers (e.g., `json({ limit: '100kb' })`).
23. **Rate limiting:** `Grep: "express-rate-limit|rateLimit|rate-limit"` — verify rate limiting is applied to auth endpoints (login, register, password reset) at minimum.
24. **Request timeout:** Verify request timeout is set via middleware or server configuration to prevent slowloris attacks.

## Error Handling

25. **Stack trace exposure:** `Grep: "err\.stack|error\.stack|console\.error.*req\."` — verify stack traces are not sent to clients in production. Use a centralized error handler.
26. **Default error handler:** Verify the app has a 4-argument error-handling middleware `(err, req, res, next)` that sanitizes errors before responding.
27. **Unhandled rejections:** `Grep: "unhandledRejection|uncaughtException"` — verify process-level error handlers exist and log errors without exposing details.

## Dependencies

28. **Known vulnerabilities:** Check `package.json` and `package-lock.json` for dependencies with known CVEs. Run `npm audit` or check advisory databases.
29. **Prototype pollution:** `Grep: "merge\(|assign\(|extend\(|lodash\.merge|deepmerge"` — verify deep merge utilities sanitize `__proto__`, `constructor`, and `prototype` keys from user input.

## Database & ORM Safety

30. **Sequelize raw queries:** `Grep: "sequelize\.query\(|\.literal\("` — verify raw Sequelize queries use bind parameters, not string interpolation. `Sequelize.literal()` with user input is injection.
31. **Knex raw queries:** `Grep: "knex\.raw\(|\.whereRaw\(|\.orderByRaw\("` — verify raw Knex methods use parameterized bindings (`?`), not template literals with user data.
32. **Mongoose query injection:** `Grep: "\.find\(req\.|\.findOne\(req\.|\.updateOne\(req\."` — verify MongoDB queries do not pass raw `req.body` or `req.query` objects. User input containing `$gt`, `$ne`, `$regex` operators bypasses auth checks.
33. **Connection string exposure:** `Grep: "DATABASE_URL|MONGO_URI|REDIS_URL"` — verify database connection strings come from environment variables and are not logged.

## WebSocket Security

34. **WebSocket auth:** `Grep: "ws\(|WebSocket|socket\.io"` — verify WebSocket connections authenticate on upgrade, not just on initial HTTP request.
35. **WebSocket input validation:** Verify data received on WebSocket connections is validated and typed before processing. Parse and schema-validate all incoming messages.
36. **Socket.io CORS:** `Grep: "cors.*origin|io\(.*cors"` — verify Socket.io CORS configuration is not set to `*` when credentials are used.

## Logging & Monitoring

37. **PII in logs:** `Grep: "console\.(log|info|warn|error)\(.*req\.body|console\.(log|info|warn|error)\(.*password"` — verify log statements do not include request bodies, passwords, tokens, or PII.
38. **Morgan/Winston sensitive data:** `Grep: "morgan\(|winston\.|createLogger"` — verify logging middleware does not log full request/response bodies or `Authorization` headers.
39. **Error serialization:** `Grep: "JSON\.stringify\(err|res\.json\(err"` — verify errors are not serialized and sent to clients. Error objects may contain stack traces and internal paths.

## Server Configuration

40. **Process environment:** `Grep: "process\.env\."` — verify `NODE_ENV` is checked and set to `production` in production. Debug features gated on `NODE_ENV !== 'production'` must not leak.
41. **Trust proxy:** `Grep: "trust proxy|app\.set.*proxy"` — if behind a reverse proxy, verify `trust proxy` is set correctly. Misconfiguration leads to IP spoofing via `X-Forwarded-For`.
42. **Compression middleware:** `Grep: "compression\(\)"` — verify compression is enabled to prevent BREACH attacks only when sensitive tokens are not in response bodies, or use per-request masking.

## File System & Paths

43. **Directory listing:** `Grep: "serveIndex|directory\("` — verify directory listing is disabled in production. `serve-index` middleware should not be used with user-accessible paths.
44. **Symlink following:** `Grep: "express\.static.*follow"` — verify static file serving does not follow symlinks outside the intended directory.

## Authentication Patterns

45. **Passport strategy configuration:** `Grep: "passport\.use|Strategy\("` — verify Passport strategies validate callback URLs, check state parameters (OAuth), and use PKCE where available.
46. **Token refresh:** `Grep: "refreshToken|refresh_token"` — verify refresh tokens are stored securely (httpOnly cookie), rotated on use, and invalidated on logout.
47. **Account enumeration:** `Grep: "User not found|Invalid password|email.*not.*registered"` — verify login and password reset endpoints return identical responses for valid and invalid accounts to prevent user enumeration.

## SSRF & External Requests

48. **SSRF via user URLs:** `Grep: "axios\(|fetch\(|request\(|got\("` — verify HTTP client requests do not use user-controlled URLs without validation. Block internal IP ranges (127.0.0.1, 10.x, 172.16-31.x, 169.254.x).
49. **Webhook URL validation:** `Grep: "webhook|callback.*url|notify.*url"` — verify webhook destination URLs are validated and internal networks are blocked.
50. **DNS rebinding:** When validating URLs, resolve the hostname and check the resulting IP, not just the hostname string.
