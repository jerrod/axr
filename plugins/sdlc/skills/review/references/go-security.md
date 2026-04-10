# Go Security Checklist

Rules for the security reviewer when analyzing Go code. Each rule is a check to run against the changed files.

## Input Validation & Injection

1. **SQL injection via fmt:** `Grep: "fmt\.Sprintf.*SELECT|fmt\.Sprintf.*INSERT|fmt\.Sprintf.*UPDATE|fmt\.Sprintf.*DELETE"` — all SQL queries must use parameterized placeholders (`$1`, `?`), never `fmt.Sprintf` or string concatenation.
2. **SQL Query with string formatting:** `Grep: "db\.Query\(fmt\.|db\.Exec\(fmt\.|db\.QueryRow\(fmt\."` — `db.Query`, `db.Exec`, and `db.QueryRow` must use argument placeholders, not formatted strings.
3. **Command injection:** `Grep: "exec\.Command\(|exec\.CommandContext\("` — verify the command and arguments are not constructed from user input. If user input is needed, use argument arrays (not shell strings) and validate against an allowlist.
4. **Template injection:** `Grep: "template\.HTML\(|template\.JS\(|template\.CSS\("` — `template.HTML()` bypasses Go's template escaping. Verify the value is never derived from user input.
5. **Path traversal:** `Grep: "filepath\.Join\(.*r\.|os\.Open\(.*r\.|ioutil\.ReadFile\(.*r\."` — verify user-supplied paths are cleaned with `filepath.Clean()` and validated against an allowed base directory. Check for `../` sequences.
6. **XML/JSON deserialization:** `Grep: "xml\.Decoder|json\.Decoder|xml\.Unmarshal|json\.Unmarshal"` — verify deserialized data is validated after parsing. For XML, check for XXE by verifying external entity resolution is disabled.

## Authentication & Sessions

7. **Missing auth middleware:** Check new HTTP handlers for authentication middleware. Verify `http.HandleFunc` and router registrations include auth checks for protected endpoints.
8. **JWT validation:** `Grep: "jwt\.Parse|jwt\.ParseWithClaims"` — verify: signing method is validated (not just `alg` from header), expiration is checked, audience and issuer are validated, key is from secure storage.
9. **Cookie security flags:** `Grep: "http\.Cookie|SetCookie"` — verify cookies set `Secure: true`, `HttpOnly: true`, `SameSite: http.SameSiteLaxMode` (or `Strict`).
10. **Password hashing:** `Grep: "bcrypt|argon2|scrypt|pbkdf2"` — verify passwords use `bcrypt.GenerateFromPassword` or `argon2`. `Grep: "md5\.New|sha1\.New|sha256\.New"` in password contexts is a finding.
11. **Timing-safe comparison:** `Grep: "subtle\.ConstantTimeCompare|hmac\.Equal"` — verify token and password comparisons use constant-time functions, not `==` or `bytes.Equal`.

## CORS / CSRF

12. **CORS wildcard:** `Grep: "Access-Control-Allow-Origin.*\*|AllowAllOrigins|AllowOrigins.*\*"` — wildcard origin with credentials is a critical finding. Origins must be explicitly listed.
13. **CORS middleware:** Verify CORS middleware configuration restricts `AllowMethods`, `AllowHeaders`, and `AllowOrigins` to necessary values.
14. **CSRF protection:** Verify state-changing handlers (POST, PUT, DELETE) have CSRF protection via tokens or SameSite cookies.

## TLS & Network

15. **HTTP without TLS:** `Grep: "http\.ListenAndServe\(|net\.Listen\(\"tcp\""` — verify production servers use `http.ListenAndServeTLS` or sit behind a TLS-terminating proxy. Plaintext listeners must be explicitly justified.
16. **TLS configuration:** `Grep: "tls\.Config"` — verify `MinVersion` is `tls.VersionTLS12` or higher. Check that cipher suites do not include weak options.
17. **HTTP client timeouts:** `Grep: "http\.Client\{|http\.DefaultClient|http\.Get\("` — verify HTTP clients set `Timeout`. The `http.DefaultClient` has no timeout and is a DoS risk.

## File Handling

18. **Request body limits:** `Grep: "http\.MaxBytesReader|r\.Body"` — verify `http.MaxBytesReader()` wraps `r.Body` before reading. Unbounded body reads cause memory exhaustion.
19. **File upload handling:** `Grep: "r\.FormFile|r\.MultipartReader"` — verify uploaded files have size limits and content type validation.
20. **Temp file handling:** `Grep: "os\.CreateTemp|ioutil\.TempFile"` — verify temp files are cleaned up with `defer os.Remove()`.

## Cryptography

21. **Weak random:** `Grep: "math/rand"` — `math/rand` is not cryptographically secure. Use `crypto/rand` for tokens, keys, nonces, and any security-relevant random values.
22. **Hardcoded keys:** `Grep: "[]byte\(\".*\"\)|key\s*:?=\s*\".*\""` — verify encryption keys and signing secrets are loaded from environment or config, not hardcoded.
23. **Weak hash algorithms:** `Grep: "md5\.New\(\)|sha1\.New\(\)"` — MD5 and SHA1 are not suitable for security purposes (signatures, integrity, passwords). Use SHA-256+ or bcrypt.

## Concurrency

24. **Race conditions on shared state:** `Grep: "go func|sync\.Mutex|sync\.RWMutex"` — verify shared mutable state is protected by mutexes or channels. Check for goroutines that modify map or slice values without synchronization.
25. **Context cancellation:** `Grep: "context\.Background\(\)|context\.TODO\(\)"` — verify HTTP handlers use `r.Context()` and pass it to downstream calls. `context.Background()` in request handlers prevents proper cancellation and timeout.

## Error Handling & Logging

26. **Error information disclosure:** `Grep: "http\.Error\(.*err\.Error\(\)|fmt\.Fprintf\(w.*err"` — verify internal error messages are not sent to clients. Return generic error messages and log details server-side.
27. **Panic recovery:** `Grep: "panic\(|log\.Fatal"` — verify HTTP servers have recovery middleware to catch panics. `log.Fatal` calls `os.Exit` and should not be used in request handlers.
28. **PII in logs:** `Grep: "log\.(Print|Printf|Println)\(.*password|log\.(Print|Printf|Println)\(.*token"` — verify log statements do not include passwords, tokens, or PII.

## Dependency & Build

29. **Go module verification:** `Grep: "GONOSUMCHECK|GONOSUMDB|GOFLAGS.*-insecure"` — verify module checksum verification is not disabled. Check `go.sum` is committed.
30. **CGO security:** `Grep: "import \"C\"|cgo"` — CGo code bypasses Go's memory safety. Verify CGo usage is necessary and inputs to C functions are validated.

## Serialization & Response Safety

31. **JSON field exposure:** `Grep: "json:\".*\"|json\.Marshal"` — verify struct JSON tags do not expose sensitive fields (passwords, internal IDs, admin flags). Use separate response structs or `json:"-"` to hide fields.
32. **Reflect-based deserialization:** `Grep: "reflect\.|mapstructure"` — verify reflection-based deserialization validates types and does not allow arbitrary field setting from user input.
33. **YAML deserialization:** `Grep: "yaml\.Unmarshal|gopkg\.in/yaml"` — YAML v2 allows arbitrary type instantiation. Use YAML v3 or `yaml.Decoder` with `KnownFields(true)`.
34. **Protobuf validation:** `Grep: "proto\.Unmarshal|protobuf"` — verify protobuf messages are validated after unmarshaling. Unknown fields and default values can mask missing required data.

## HTTP Handler Safety

35. **Response header injection:** `Grep: "w\.Header\(\)\.Set\(|w\.Header\(\)\.Add\("` — verify header values do not include user-controlled data that could contain `\r\n` sequences (HTTP response splitting).
36. **Handler timeout:** `Grep: "http\.TimeoutHandler|ReadTimeout|WriteTimeout"` — verify server has `ReadTimeout`, `WriteTimeout`, and `IdleTimeout` set to prevent resource exhaustion.
37. **SSRF prevention:** `Grep: "http\.Get\(|http\.Post\(|http\.NewRequest\("` — verify HTTP client requests do not use user-controlled URLs without validation. Check for internal IP ranges (127.0.0.1, 10.x, 169.254.x, ::1).
38. **Method restriction:** `Grep: "r\.Method|mux\.Methods"` — verify handlers check HTTP method. `http.HandleFunc` accepts all methods by default.

## Middleware & Authentication

39. **Auth middleware bypass:** `Grep: "mux\.Handle|http\.Handle|router\.(GET|POST|PUT|DELETE)"` — verify auth middleware is applied to routes, not skipped by handler registration order.
40. **API key validation:** `Grep: "X-API-Key|Authorization|Bearer"` — verify API key/token validation uses constant-time comparison (`subtle.ConstantTimeCompare`) and checks for empty values.
41. **RBAC enforcement:** `Grep: "role|permission|IsAdmin|isAuthorized"` — verify role-based access control checks are performed in middleware, not duplicated (and possibly forgotten) in each handler.

## Database Safety

42. **SQL connection pooling:** `Grep: "sql\.Open|SetMaxOpenConns|SetMaxIdleConns"` — verify connection pool limits are set. Unbounded pools can exhaust database connections under load.
43. **Prepared statement caching:** `Grep: "db\.Prepare\(|stmt\.Close"` — verify prepared statements are properly closed after use. Leaking prepared statements exhausts database resources.
44. **Transaction handling:** `Grep: "db\.Begin\(|tx\.Commit|tx\.Rollback"` — verify transactions are always committed or rolled back, including in error paths. Use `defer tx.Rollback()` with a commit at the end.

## Serialization & Response Safety (continued)

45. **gRPC input validation:** `Grep: "pb\.|protobuf|\.proto"` — verify gRPC service implementations validate all incoming message fields. Default zero values can mask missing required data.
46. **GraphQL introspection:** `Grep: "graphql|gqlgen|graphql-go"` — verify GraphQL introspection is disabled in production. Introspection exposes the full schema to attackers.
47. **GraphQL query depth:** Verify GraphQL resolvers have query depth and complexity limits to prevent denial of service via deeply nested queries.

## SSRF & External Requests

48. **SSRF via user URLs:** `Grep: "http\.Get\(.*req\.|http\.Post\(.*req\.|httpClient\.Do"` — verify HTTP client requests do not use user-controlled URLs without validation. Block internal IP ranges (127.0.0.1, 10.x, 172.16-31.x, 169.254.x, ::1, fd00::/8).
49. **Webhook URL validation:** `Grep: "webhook|callback.*url|notify.*url"` — verify webhook destination URLs are validated against an allowlist or block internal networks.
50. **DNS rebinding:** When validating URLs, resolve the hostname and check the resulting IP address — DNS rebinding maps public hostnames to internal IPs.
