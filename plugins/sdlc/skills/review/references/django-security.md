# Django Security Checklist

Rules for the security reviewer when analyzing Django code. Each rule is a check to run against the changed files.

## Input Validation & Injection

1. **Raw SQL injection:** `Grep: "\.raw\(|\.extra\(|RawSQL\(|cursor\.execute\("` — all raw queries must use parameterized placeholders (`%s` with params list), never string formatting.
2. **ORM extra() deprecation:** `Grep: "\.extra\("` — `extra()` is deprecated and prone to injection. Replace with ORM annotations, subqueries, or `Func` expressions.
3. **Template XSS via mark_safe:** `Grep: "mark_safe\(|format_html\("` — verify user input never flows into `mark_safe()`. Use `format_html()` only with controlled format strings.
4. **Template safe filter:** `Grep: "\|safe\b"` — the `|safe` filter disables autoescaping. Verify the value is not user-controlled.
5. **JSON response construction:** `Grep: "HttpResponse.*application/json|HttpResponse.*json"` — use `JsonResponse` instead of manually serializing JSON into `HttpResponse` (handles content type and escaping).
6. **Form validation bypass:** Check views accepting POST data — verify all input goes through Django Forms or serializers, not raw `request.POST` access without validation.

## Authentication & Sessions

7. **Session cookie flags:** `Grep: "SESSION_COOKIE_SECURE|SESSION_COOKIE_HTTPONLY|SESSION_COOKIE_SAMESITE"` in settings — all three must be set: `SECURE=True`, `HTTPONLY=True`, `SAMESITE='Lax'` or `'Strict'`.
8. **CSRF cookie flags:** `Grep: "CSRF_COOKIE_SECURE|CSRF_COOKIE_HTTPONLY"` — `CSRF_COOKIE_SECURE=True` required for HTTPS deployments.
9. **Login required:** Check new views for `@login_required`, `LoginRequiredMixin`, or equivalent permission checks. Unprotected views must be explicitly documented as public.
10. **Password validation:** `Grep: "AUTH_PASSWORD_VALIDATORS"` — verify validators include minimum length, common password check, and numeric-only check.
11. **Custom auth backends:** `Grep: "class.*Backend.*authenticate"` — verify custom authentication backends properly validate credentials and handle timing attacks.

## CORS / CSRF

12. **CSRF middleware ordering:** `Grep: "MIDDLEWARE"` — verify `CsrfViewMiddleware` appears before any view-processing middleware. Check that `SecurityMiddleware` is first.
13. **CSRF exempt:** `Grep: "csrf_exempt|@csrf_exempt"` — every CSRF exemption must have a documented justification. API endpoints should use token auth instead.
14. **CORS configuration:** `Grep: "CORS_ALLOW_ALL_ORIGINS|CORS_ORIGIN_ALLOW_ALL"` — must be `False` in production. Origins must be explicitly listed.

## File Handling

15. **Upload path traversal:** `Grep: "FileField|ImageField|upload_to"` — verify `upload_to` uses a callable or safe path, not user-controlled input. Check that `MEDIA_ROOT` is outside the project directory.
16. **File size limits:** `Grep: "FILE_UPLOAD_MAX_MEMORY_SIZE|DATA_UPLOAD_MAX_MEMORY_SIZE"` — verify upload size limits are set in settings.
17. **Served media files:** `Grep: "MEDIA_URL|serve\(.*document_root"` — verify media files are served by a web server (nginx/caddy) in production, not Django's `serve()` view.
18. **File type validation:** Verify uploaded files are validated by content type, not just extension. Check for unrestricted file upload.

## Secrets & Configuration

19. **DEBUG in production:** `Grep: "DEBUG\s*=\s*True"` in settings files — must be `False` in production. Verify `DEBUG` is loaded from environment.
20. **SECRET_KEY exposure:** `Grep: "SECRET_KEY\s*="` — verify the secret key is loaded from environment variables, not hardcoded in settings.
21. **ALLOWED_HOSTS wildcard:** `Grep: "ALLOWED_HOSTS.*\*"` — wildcard `ALLOWED_HOSTS` enables host header attacks. Must list specific domains.
22. **Database credentials:** `Grep: "DATABASES.*PASSWORD"` — verify database passwords come from environment variables, not settings files.

## Security Middleware

23. **Security middleware present:** `Grep: "SecurityMiddleware"` — verify `django.middleware.security.SecurityMiddleware` is in MIDDLEWARE and positioned first.
24. **HSTS configuration:** `Grep: "SECURE_HSTS_SECONDS|SECURE_HSTS_INCLUDE_SUBDOMAINS"` — verify HSTS is enabled with reasonable max-age (at least 31536000).
25. **Content type sniffing:** `Grep: "SECURE_CONTENT_TYPE_NOSNIFF"` — must be `True`.
26. **SSL redirect:** `Grep: "SECURE_SSL_REDIRECT"` — must be `True` in production.

## Admin & Management

27. **Admin URL:** `Grep: "admin\.site\.urls|path.*admin/"` — verify admin URL is not the default `/admin/`. Use an obscure path.
28. **Admin permissions:** Check that custom admin views enforce `is_staff` and appropriate permissions.
29. **Management commands:** `Grep: "BaseCommand|management/commands"` — verify management commands that accept input validate and sanitize arguments.

## Logging & Data Exposure

30. **PII in logs:** `Grep: "logger\.|logging\."` — verify log statements do not include passwords, tokens, PII, or full request bodies.
31. **Verbose error pages:** Verify `DEBUG=False` suppresses detailed error pages in production. Check for custom error handlers that may leak information.
32. **Sensitive data in context:** `Grep: "context\[|get_context_data"` — verify view context does not include database credentials, API keys, or user tokens passed to templates.

## Serialization & API Safety

33. **Model serialization leakage:** `Grep: "serializers\.ModelSerializer|fields.*__all__"` — DRF serializers with `fields = '__all__'` expose every model field including sensitive ones. Use explicit field lists.
34. **Writable nested serializers:** `Grep: "class Meta.*depth|NestedSerializer"` — verify nested serializers that accept writes validate relationships and enforce permissions on related objects.
35. **Hyperlinked identity:** `Grep: "HyperlinkedModelSerializer|HyperlinkedRelatedField"` — verify hyperlinked serializers do not expose internal IDs or URLs of resources the user is not authorized to access.
36. **Filterset injection:** `Grep: "django_filters|FilterSet|filterset_fields"` — verify filterable fields do not include sensitive fields (is_staff, is_superuser, password) and that filter backends validate input types.

## Caching

37. **Cache poisoning:** `Grep: "cache\.set|@cache_page|vary_on_headers"` — verify cached responses do not include user-specific data unless cache keys include the user. Check `Vary` headers.
38. **Cache backend security:** `Grep: "CACHES.*BACKEND"` — verify production cache backends use authenticated connections (Redis with password, Memcached with SASL).
39. **Sensitive data in cache:** Verify passwords, tokens, and PII are not stored in cache without encryption or TTL.

## Signals & Async

40. **Signal handler side effects:** `Grep: "post_save|pre_save|post_delete"` — verify signal handlers do not perform unbounded operations (sending emails, making API calls) synchronously. Use task queues for heavy work.
41. **Async view safety:** `Grep: "async def.*view|async def.*get\(|async def.*post\("` — verify async views do not use synchronous ORM calls without `sync_to_async` wrapping (causes thread pool exhaustion).

## Template Security

42. **Custom template tags:** `Grep: "register\.filter|register\.tag|@register"` — verify custom template tags and filters that output HTML use `mark_safe` only on controlled values, never on user input.
43. **Template loader safety:** `Grep: "TEMPLATES.*DIRS|template_name"` — verify template names cannot be controlled by user input (prevents template injection).

## URL & Redirect Safety

44. **Open redirect:** `Grep: "redirect\(.*request\.(GET|POST)|HttpResponseRedirect\(.*request"` — verify redirect destinations are validated. Use `url_has_allowed_host_and_scheme()` to check redirect URLs.
45. **URL pattern specificity:** `Grep: "path\(|re_path\(|url\("` — verify URL patterns are specific enough. Overly broad patterns can match unintended paths.
46. **Trailing slash handling:** `Grep: "APPEND_SLASH"` — verify `APPEND_SLASH` behavior does not create redirect loops or bypass auth middleware.

## API & DRF Safety

47. **DRF authentication classes:** `Grep: "authentication_classes|DEFAULT_AUTHENTICATION_CLASSES"` — verify API views have explicit authentication classes. Default `SessionAuthentication` without CSRF is vulnerable.
48. **DRF permission classes:** `Grep: "permission_classes|DEFAULT_PERMISSION_CLASSES"` — verify `IsAuthenticated` or stricter permissions are set. `AllowAny` must be explicitly justified.
49. **DRF throttling:** `Grep: "throttle_classes|DEFAULT_THROTTLE_CLASSES"` — verify rate limiting is configured for authentication endpoints.
50. **DRF pagination:** `Grep: "pagination_class|DEFAULT_PAGINATION_CLASS"` — verify list endpoints have pagination to prevent unbounded query responses.

## Celery & Task Queue

51. **Task serialization:** `Grep: "CELERY_TASK_SERIALIZER|task_serializer"` — verify task serializer is `json`, not `pickle` (pickle deserialization is RCE).
52. **Task argument validation:** `Grep: "@app\.task|@shared_task"` — verify task arguments are validated. Tasks triggered by external events (webhooks, queues) must not trust input.
53. **Task result backend:** `Grep: "CELERY_RESULT_BACKEND|result_backend"` — verify result backend is secured and does not expose task results to unauthorized users.
