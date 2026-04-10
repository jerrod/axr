# Next.js Security Checklist

Rules for the security reviewer when analyzing Next.js code. Each rule is a check to run against the changed files.

## Input Validation & Injection

1. **Server Action input validation:** `Grep: "'use server'|\"use server\""` — every Server Action must validate its inputs with Zod or similar schema validation. Raw `formData.get()` values used without validation are a finding.
2. **dangerouslySetInnerHTML:** `Grep: "dangerouslySetInnerHTML"` — verify the value is never derived from user input or database content without sanitization (DOMPurify or equivalent).
3. **Dynamic route injection:** `Grep: "params\.|searchParams\."` — verify dynamic route parameters and search params are validated before use in database queries, redirects, or file operations.
4. **SQL/ORM injection:** `Grep: "sql\`|prisma\.\$queryRaw|prisma\.\$executeRaw"` — verify raw queries use parameterized templates, not string interpolation.
5. **Redirect injection:** `Grep: "redirect\(|router\.push\(|router\.replace\("` — verify redirect destinations are validated against an allowlist. User-controlled redirect URLs enable open redirect attacks.
6. **eval() usage:** `Grep: "eval\(|new Function\("` — critical finding in any context. No exceptions.

## Authentication & Authorization

7. **Middleware auth:** `Grep: "middleware\.(ts|js)"` — verify authentication middleware covers all protected routes. Check `matcher` configuration for gaps.
8. **API route auth:** `Grep: "route\.(ts|js)|api/.*\.(ts|js)"` — verify every API route handler checks authentication. Routes without auth must be explicitly documented as public.
9. **Server Action auth:** Server Actions run on the server with full permissions. Verify each action checks the user's session/role before performing mutations.
10. **getServerSideProps auth:** `Grep: "getServerSideProps|getStaticProps"` — verify `getServerSideProps` checks auth before returning sensitive data. `getStaticProps` must never include user-specific data.
11. **Session handling:** `Grep: "next-auth|NextAuth|getServerSession|getSession"` — verify session tokens use `httpOnly` cookies, not `localStorage`. Check that session expiration is configured.

## Data Exposure

12. **NEXT_PUBLIC_ leakage:** `Grep: "NEXT_PUBLIC_"` — every `NEXT_PUBLIC_` variable is exposed to the browser. Verify no secrets, API keys, or internal URLs use this prefix.
13. **Server/Client data boundary:** `Grep: "'use client'|\"use client\""` — verify Server Components do not pass sensitive data (tokens, internal IDs, admin flags) as props to Client Components.
14. **getServerSideProps data exposure:** Verify `getServerSideProps` only returns data the user is authorized to see. Check for over-fetching that includes fields not rendered on the page.
15. **Error boundary leakage:** `Grep: "error\.(tsx|jsx)|ErrorBoundary"` — verify error boundaries do not display stack traces, internal paths, or database error messages to users.

## CORS / CSRF

16. **API route CORS:** `Grep: "Access-Control-Allow-Origin|cors"` in API routes — verify CORS headers are not set to `*` when credentials are needed.
17. **Server Action CSRF:** Next.js Server Actions have built-in CSRF protection. Verify the app is not disabling it or using custom form handling that bypasses it.

## Security Headers

18. **next.config headers:** `Grep: "headers\(\)|securityHeaders"` in `next.config` — verify security headers are configured: `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Content-Security-Policy`.
19. **CSP directives:** `Grep: "Content-Security-Policy"` — verify CSP does not include `unsafe-inline` or `unsafe-eval` unless strictly necessary. Use nonces for inline scripts.
20. **X-Frame-Options:** Verify `DENY` or `SAMEORIGIN` is set to prevent clickjacking.

## File Handling & SSRF

21. **Image optimization SSRF:** `Grep: "remotePatterns|domains"` in `next.config` — verify `remotePatterns` does not include wildcard patterns that could be exploited for SSRF. Each remote pattern should specify protocol, hostname, and pathname.
22. **File upload handling:** Verify uploaded files in API routes have size limits, type validation, and are stored outside the public directory.
23. **Dynamic imports:** `Grep: "dynamic\(.*import\("` — verify dynamic import paths are not user-controlled.

## Common Misconfigurations

24. **Source maps in production:** `Grep: "productionBrowserSourceMaps"` — must be `false` or absent in production. Source maps expose original source code.
25. **Powered-by header:** `Grep: "poweredByHeader"` in `next.config` — should be `false` to prevent technology fingerprinting.
26. **Rewrites/redirects:** `Grep: "rewrites\(\)|redirects\(\)"` in `next.config` — verify rewrites do not expose internal services or create open redirects.
27. **Middleware edge runtime:** `Grep: "export const runtime"` — verify middleware runs on the edge runtime where expected, and that Node.js APIs are not accidentally used in edge functions.

## Client-Side Security

28. **localStorage for auth:** `Grep: "localStorage\.(set|get)Item.*token|sessionStorage\.(set|get)Item.*token"` — auth tokens must be stored in `httpOnly` cookies, not browser storage.
29. **postMessage handling:** `Grep: "addEventListener.*message|postMessage"` — verify `message` event listeners validate `event.origin` before processing data.
30. **Third-party scripts:** `Grep: "Script.*src=|<script.*src="` — verify third-party scripts use `integrity` attributes (SRI) and are loaded from trusted domains.

## Database & ORM Safety

31. **Prisma raw queries:** `Grep: "prisma\.\$queryRaw|prisma\.\$executeRaw"` — verify raw Prisma queries use tagged template literals (`Prisma.sql`), not string concatenation with user input.
32. **Drizzle raw queries:** `Grep: "sql\.raw|drizzle.*raw"` — verify raw Drizzle queries use parameterized templates.
33. **Connection string exposure:** `Grep: "DATABASE_URL"` — verify database connection strings are in `.env.local` (not committed) and never exposed via `NEXT_PUBLIC_` prefix.

## Caching & ISR

34. **ISR data staleness:** `Grep: "revalidate|unstable_cache|revalidateTag"` — verify Incremental Static Regeneration does not serve stale data that includes user-specific content or permissions-gated information.
35. **Cache key injection:** `Grep: "unstable_cache\(|cacheTag\("` — verify cache keys and tags are not derived from user input, which could enable cache poisoning.
36. **On-demand revalidation auth:** `Grep: "revalidatePath|revalidateTag"` — verify on-demand revalidation endpoints require authentication to prevent cache flushing attacks.

## Logging & Error Handling

37. **Server-side error logging:** `Grep: "console\.(log|error)\(.*password|console\.(log|error)\(.*token"` — verify server-side logs do not include passwords, tokens, or PII.
38. **Error page information disclosure:** `Grep: "error\.(tsx|jsx)|not-found\.(tsx|jsx)"` — verify custom error pages do not display stack traces, internal paths, or database error messages.
39. **API route error handling:** Verify API routes catch errors and return generic messages. Unhandled errors in API routes expose Next.js internal error format.

## Route & Middleware Safety

40. **Middleware matcher gaps:** `Grep: "export const config.*matcher"` in `middleware.ts` — verify the matcher pattern covers all protected routes. Gaps allow unauthenticated access.
41. **Parallel route auth:** `Grep: "@.*/(.*)|layout\.(tsx|jsx)"` — verify parallel routes and intercepting routes inherit auth from parent layouts, not just individual pages.
42. **Route handler methods:** `Grep: "export async function (GET|POST|PUT|DELETE|PATCH)"` — verify each exported route handler method has appropriate auth checks. Unintended method exports create attack surface.

## Dependency & Build Safety

43. **Bundle analysis:** `Grep: "analyze|ANALYZE"` in `next.config` — verify production bundles do not include dev dependencies, test utilities, or mock data.
44. **Package lock committed:** Verify `package-lock.json` or `yarn.lock` is committed and matches `package.json`. Missing lock files allow supply chain attacks.
45. **Postinstall scripts:** Check `package.json` for `postinstall` scripts that execute arbitrary code. Review new dependencies for suspicious lifecycle scripts.

## SSRF & External Requests

46. **Server-side fetch SSRF:** `Grep: "fetch\(.*req\.|fetch\(.*params\.|fetch\(.*searchParams"` — verify server-side `fetch` calls in Server Components, route handlers, and Server Actions do not use user-controlled URLs. Block internal IP ranges.
47. **Webhook URL validation:** `Grep: "webhook|callback.*url"` — verify webhook destination URLs are validated and internal networks are blocked.
48. **OpenGraph/meta fetching:** `Grep: "generateMetadata|opengraph"` — verify metadata generation that fetches external URLs validates the source and handles timeouts.

## State & Data Hydration

49. **Server Component data in HTML:** `Grep: "__NEXT_DATA__|dehydratedState|pageProps"` — verify server-rendered page props do not include sensitive data (tokens, internal IDs, admin flags) that would be visible in the page HTML source.
50. **Client-side state exposure:** `Grep: "useContext.*auth|useSession"` — verify auth context values passed to Client Components do not include raw tokens or sensitive user fields beyond what the UI needs.
