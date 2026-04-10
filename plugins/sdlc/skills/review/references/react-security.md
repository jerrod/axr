# React Security Checklist

Rules for the security reviewer when analyzing React code. Each rule is a check to run against the changed files.

## Cross-Site Scripting (XSS)

1. **dangerouslySetInnerHTML:** `Grep: "dangerouslySetInnerHTML"` — verify the value is never derived from user input, URL parameters, or database content without sanitization. If sanitization is used, verify DOMPurify or equivalent with a strict allowlist.
2. **href javascript: injection:** `Grep: "href.*javascript:|href=\{.*\}"` — verify `href` attributes do not accept user-controlled values that could contain `javascript:` URIs. Validate URLs start with `https://`, `http://`, or `/`.
3. **User-controlled src attributes:** `Grep: "src=\{|src=\{.*\}"` — verify `src`, `srcSet`, and `action` attributes on `img`, `iframe`, `script`, `form`, and `embed` elements do not accept unvalidated user input.
4. **Dynamic element creation:** `Grep: "createElement\(.*\,|React\.createElement"` — verify element type is not user-controlled (prevents rendering arbitrary HTML elements).
5. **innerHTML via refs:** `Grep: "\.innerHTML\s*=|\.outerHTML\s*="` — direct DOM manipulation with `innerHTML` bypasses React's XSS protections. Use React state/props instead.

## URL & Navigation Security

6. **Open redirects:** `Grep: "window\.location|location\.href|location\.assign|location\.replace"` — verify redirect destinations are validated against an allowlist. User-controlled URLs enable phishing.
7. **URL parameter injection:** `Grep: "useSearchParams|URLSearchParams|location\.search"` — verify URL parameters are validated and sanitized before use in rendering or API calls.
8. **Link target:** `Grep: "target.*_blank|target=\"_blank\""` — verify links with `target="_blank"` include `rel="noopener noreferrer"` to prevent reverse tabnapping.

## Client-Side Storage

9. **Auth tokens in localStorage:** `Grep: "localStorage\.(set|get)Item.*token|localStorage\.(set|get)Item.*auth|localStorage\.(set|get)Item.*session"` — auth tokens and session data must be stored in `httpOnly` cookies, not `localStorage` or `sessionStorage` (accessible to XSS).
10. **Sensitive data in storage:** `Grep: "localStorage\.setItem|sessionStorage\.setItem"` — verify PII, credentials, and sensitive business data are not stored in browser storage.

## Inter-Window Communication

11. **postMessage origin validation:** `Grep: "addEventListener.*message|onmessage"` — verify `message` event listeners check `event.origin` against an expected value before processing `event.data`.
12. **postMessage data validation:** Verify data received via `postMessage` is validated/typed before use. Do not trust structure or content from other windows.
13. **postMessage target origin:** `Grep: "postMessage\("` — verify `targetOrigin` is set to a specific origin, not `"*"`, when sending sensitive data.

## Dependency & Prototype Safety

14. **Prototype pollution:** `Grep: "Object\.assign\(.*req|\.merge\(.*req|deepmerge|lodash\.merge"` — verify deep merge/assign operations on user input sanitize `__proto__`, `constructor`, and `prototype` keys.
15. **eval and dynamic code:** `Grep: "eval\(|new Function\(|setTimeout\(.*\"|setInterval\(.*\""` — `eval()`, `new Function()`, and string-based timers with user data are critical findings.
16. **JSON.parse without try/catch:** `Grep: "JSON\.parse\("` — verify `JSON.parse` calls on user input are wrapped in try/catch to prevent crashes on malformed input.

## State & Data Flow

17. **Sensitive data in React state:** Verify component state does not hold decrypted secrets, full credit card numbers, or other sensitive data that could be exposed via React DevTools.
18. **API key exposure:** `Grep: "REACT_APP_|VITE_|import\.meta\.env"` — environment variables prefixed with `REACT_APP_` or `VITE_` are bundled into client code. Verify no secrets use these prefixes.
19. **Unvalidated API responses:** Verify API response data is validated/typed before rendering. Malformed responses should be handled gracefully, not rendered blindly.

## Form Security

20. **Form action targets:** `Grep: "action=\{|action=\""` — verify form `action` attributes point to expected endpoints and are not user-controlled.
21. **Autocomplete on sensitive fields:** `Grep: "type=\"password\"|type=\"credit"` — verify `autoComplete="off"` or `autoComplete="new-password"` is set on sensitive input fields to prevent credential caching.
22. **File input validation:** `Grep: "type=\"file\"|<input.*file"` — verify file inputs have `accept` attributes and client-side size validation. Server-side validation is still required.

## Common Misconfigurations

23. **Source maps in production:** Verify `GENERATE_SOURCEMAP=false` or equivalent is set in production builds to prevent source code exposure.
24. **Error boundary information disclosure:** `Grep: "componentDidCatch|ErrorBoundary"` — verify error boundaries display user-friendly messages, not stack traces or internal error details.
25. **Console logging of sensitive data:** `Grep: "console\.(log|debug|info)\(.*password|console\.(log|debug|info)\(.*token|console\.(log|debug|info)\(.*secret"` — remove logging of sensitive data before production.
26. **Strict mode disabled:** `Grep: "StrictMode"` — verify `React.StrictMode` is used in development to catch potential security issues during rendering.

## API Communication

27. **Fetch without credentials control:** `Grep: "fetch\(|axios\.|useSWR|useQuery"` — verify API calls include appropriate `credentials` mode. `credentials: 'include'` should only be used with same-origin or explicitly trusted origins.
28. **Authorization header exposure:** `Grep: "Authorization.*Bearer|headers.*token"` — verify auth tokens in request headers are not logged, cached in browser history, or exposed via referrer.
29. **Error response handling:** `Grep: "\.catch\(|\.then\(.*error"` — verify API error responses are handled gracefully. Do not display raw server error messages to users.
30. **Request/response interceptors:** `Grep: "interceptors\.(request|response)|beforeRequest|afterResponse"` — verify interceptors do not log sensitive data and properly handle token refresh without exposing tokens.

## Rendering & Content Safety

31. **Markdown rendering:** `Grep: "react-markdown|marked|remark|rehype"` — verify markdown renderers sanitize HTML. `react-markdown` with `rehype-raw` re-enables HTML and must be paired with `rehype-sanitize`.
32. **Rich text editors:** `Grep: "ContentEditable|contenteditable|draft-js|slate|tiptap|quill"` — verify rich text content is sanitized before storage and before rendering in other contexts.
33. **SVG injection:** `Grep: "\.svg|ReactComponent.*svg|dangerouslySetInnerHTML.*svg"` — SVGs can contain JavaScript. Verify user-uploaded SVGs are sanitized or rendered as images, not inline.
34. **iframe sandboxing:** `Grep: "<iframe|<Iframe"` — verify iframes rendering external content use `sandbox` attribute with minimal permissions and do not include `allow-scripts` with `allow-same-origin`.

## Dependency & Build Safety

35. **Prototype pollution in deps:** `Grep: "lodash|underscore|merge-deep|deep-extend"` — verify deep-merge dependencies are up to date and inputs from users are sanitized before merging.
36. **Bundle analysis:** Verify production bundles do not include test utilities, dev tools, or mock data. `Grep: "mock|fixture|__test__|\.test\.|\.spec\."` in production imports is a finding.
37. **CDN subresource integrity:** `Grep: "integrity=|crossOrigin"` — verify scripts and stylesheets loaded from CDNs use SRI (`integrity` attribute) to detect tampering.
38. **Supply chain:** Verify `package-lock.json` or `yarn.lock` is committed. Check for unusual `postinstall` scripts in dependencies that could execute arbitrary code.

## Authentication & Session Patterns

39. **Auth context exposure:** `Grep: "AuthContext|AuthProvider|useAuth"` — verify auth context does not expose raw tokens or sensitive user data to all child components. Provide only what each component needs.
40. **Route guard implementation:** `Grep: "PrivateRoute|ProtectedRoute|RequireAuth"` — verify route guards redirect to login on auth failure and do not flash protected content before redirect.
41. **Token refresh handling:** `Grep: "refreshToken|interceptor.*401"` — verify token refresh logic handles race conditions when multiple requests fail simultaneously. Use a single refresh promise.
42. **Logout cleanup:** `Grep: "logout|signOut|clearAuth"` — verify logout clears all auth state: cookies, storage, in-memory tokens, and revokes server-side session.

## Accessibility as Security

43. **ARIA for security UI:** `Grep: "aria-live|role=\"alert\"|role=\"status\""` — verify security-relevant UI (error messages, auth status, session warnings) uses appropriate ARIA attributes so screen reader users are informed of state changes.
44. **Autofill behavior:** `Grep: "autoComplete|autocomplete"` — verify password fields use `autoComplete="current-password"` or `"new-password"` for correct password manager integration. Sensitive fields should use `autoComplete="off"`.

## SSRF & External Requests (Client-Side)

45. **Fetch URL construction:** `Grep: "fetch\(.*\+|fetch\(.*\$\{"` — verify client-side fetch calls do not construct URLs from user input without validation. User-controlled URLs can be used for SSRF if proxied through a server endpoint.
46. **Image/media source validation:** `Grep: "src=\{.*user|src=\{.*data\."` — verify image and media sources from user data are validated against an allowlist of domains.
47. **WebSocket URL construction:** `Grep: "new WebSocket\(|useWebSocket"` — verify WebSocket connection URLs are not user-controlled.

## State Management Security

48. **Redux/Zustand sensitive data:** `Grep: "createSlice|createStore|create\(.*set"` — verify global state stores do not hold decrypted secrets, session tokens, or complete PII records that could be exposed via DevTools.
49. **State persistence:** `Grep: "persist|rehydrate|REHYDRATE"` — verify persisted state (Redux Persist, Zustand persist) does not include auth tokens, secrets, or sensitive user data in localStorage.
50. **State serialization:** `Grep: "serialize|deserialize|JSON\.stringify.*state"` — verify state serialization for SSR hydration does not include sensitive server-side data in the HTML payload.
