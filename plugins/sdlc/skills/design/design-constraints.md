# Design Constraints

Proactive rules the critic checks during frontend builds when `.claude/design-context.md` exists. Each rule is mechanically verifiable by reading code — no browser required.

These constraints apply to files matching: `*.tsx`, `*.jsx`, `*.css`, `*.scss`, `*.html`.

## How the Critic Uses This

1. Check if `.claude/design-context.md` exists in the project root
2. If yes, read it to load the project's design tokens
3. For each changed frontend file, check against the rules below
4. Report violations in the standard FINDINGS format: `[file:line] DESIGN_RULE: description (fix)`

If no design-context.md exists, skip design constraint checking entirely.

---

## 1. Design Token Consistency

### 1.1 Color Tokens

**Rule:** All color values must reference design tokens, not hardcoded literals.

**What to grep for:**
```
Grep: "#[0-9a-fA-F]{3,8}" in changed frontend files
Grep: "rgb\(|rgba\(|hsl\(|hsla\(" in changed frontend files
```

**Violation:** A hardcoded color value that does not match any color in the Color Palette section of design-context.md.

**Exceptions:**
- `transparent`, `inherit`, `currentColor` — always allowed
- `#000` and `#fff` in shadows and overlays — allowed in `box-shadow`, `text-shadow`, rgba alpha contexts
- Colors inside SVG `<path>` or `<circle>` fill/stroke that match the palette

**Fix:** Replace with the corresponding CSS variable (`var(--color-primary)`), Tailwind class (`text-primary`), or theme token.

### 1.2 Typography Tokens

**Rule:** Font families must match those defined in design-context.md.

**What to grep for:**
```
Grep: "font-family:" in changed CSS/SCSS files
Grep: "fontFamily" in changed TSX/JSX files (inline styles)
Grep: "font-sans|font-serif|font-mono" in changed TSX/JSX (Tailwind)
```

**Violation:** A font-family value that is not listed in the Typography section of design-context.md. Generic fallbacks (`sans-serif`, `serif`, `monospace`) at the END of a font stack are acceptable.

**Banned defaults** (unless explicitly in design-context.md): Arial, Helvetica, Inter, Roboto, system-ui, -apple-system, BlinkMacSystemFont, Segoe UI.

**Fix:** Use the font defined in design-context.md for the appropriate role (display, body, mono).

### 1.3 Spacing Tokens

**Rule:** Spacing values should align with the spacing scale in design-context.md.

**What to grep for:**
```
Grep: "padding:|margin:|gap:|top:|right:|bottom:|left:" in CSS/SCSS
Grep: "padding|margin|gap" in inline style objects
```

**Violation:** A pixel or rem value that does not appear in the spacing scale. Common violations: `padding: 5px`, `margin: 7px`, `gap: 13px`.

**Exceptions:**
- `0` and `auto` — always allowed
- `1px` — allowed for borders and dividers
- `50%`, `100%` — percentage values are not spacing tokens
- `calc()` expressions — skip (too complex to evaluate statically)

**Fix:** Use the nearest value from the spacing scale, or a CSS variable / Tailwind spacing class.

### 1.4 Border Radius Consistency

**Rule:** Border radius values should be consistent across components.

**What to grep for:**
```
Grep: "border-radius:|rounded-" in changed frontend files
```

**Violation:** More than 3 distinct border-radius values across the changed files (suggesting inconsistency). Does not apply if design-context.md does not specify radius tokens.

**Fix:** Use a shared radius token or Tailwind's `rounded-*` scale consistently.

### 1.5 Shadow Consistency

**Rule:** Box shadows should use a consistent scale.

**What to grep for:**
```
Grep: "box-shadow:|shadow-" in changed frontend files
```

**Violation:** More than 3 distinct shadow definitions across changed files. Does not apply if design-context.md does not specify shadow tokens.

**Fix:** Define shadow tokens in CSS variables or use Tailwind's shadow scale.

---

## 2. Accessibility Baseline

These rules apply regardless of whether design-context.md exists. They are the minimum a11y bar for all frontend code.

### 2.1 Image Alt Text

**Rule:** Every `<img>` must have an `alt` attribute.

**What to grep for:**
```
Grep: "<img " in changed files — verify each has alt=
Grep: "<Image " in changed files (Next.js) — verify each has alt=
```

**Violation:** `<img>` or `<Image>` without `alt`. Decorative images must use `alt=""` (empty string), not omit the attribute.

**Fix:** Add `alt="descriptive text"` or `alt=""` for decorative images.

### 2.2 Form Input Labels

**Rule:** Every form input must have an associated label.

**What to grep for:**
```
Grep: "<input|<select|<textarea" in changed files
```

For each, verify one of:
- A `<label>` with matching `htmlFor`/`for` attribute
- `aria-label` attribute on the input
- `aria-labelledby` pointing to a visible element
- The input is wrapped inside a `<label>` element

**Violation:** An input without any labeling mechanism.

**Fix:** Add a `<label htmlFor="input-id">` or `aria-label="description"`.

### 2.3 Color Contrast

**Rule:** Text colors must have sufficient contrast against their background.

**What to look for:** Flag obvious violations that are detectable from code:
- White or near-white text (`#fff`, `#fafafa`, `#f5f5f5`) on light backgrounds
- Dark text (`#000`, `#111`, `#1a1a1a`) on dark backgrounds
- Low-opacity text (`opacity: 0.3`, `text-opacity-30`) that may reduce contrast below 4.5:1

**Violation:** A visually obvious contrast failure detectable from the code alone.

**Fix:** Adjust colors to meet WCAG AA (4.5:1 for normal text, 3:1 for large text).

### 2.4 Focus Visibility

**Rule:** Interactive elements must have visible focus styles.

**What to grep for:**
```
Grep: "outline: none|outline: 0|outline:none|outline:0" in CSS/SCSS
Grep: ":focus.*outline.*none" in CSS/SCSS
```

**Violation:** Removing outline without providing an alternative focus indicator (`:focus-visible` with ring, border, or shadow).

**Fix:** Replace `outline: none` with a visible focus style using `:focus-visible`.

### 2.5 Semantic HTML

**Rule:** Use semantic elements over generic divs for structure.

**What to look for:**
- Navigation: `<nav>` instead of `<div className="nav">`
- Main content: `<main>` present in layout components
- Headings: `<h1>` through `<h6>` in order (no skipping h2 to h4)
- Lists: `<ul>`/`<ol>` for list-like content, not repeated divs
- Buttons: `<button>` for actions, not `<div onClick>`

**Violation:** A `<div>` with an `onClick` handler that should be a `<button>`. A navigation section using `<div>` instead of `<nav>`.

**Fix:** Replace with the appropriate semantic element.

### 2.6 ARIA Landmarks

**Rule:** Page layouts should include ARIA landmarks.

**What to look for in layout/page components:**
- `<main>` or `role="main"`
- `<nav>` or `role="navigation"`
- `<header>` or `role="banner"`
- `<footer>` or `role="contentinfo"`

**Violation:** A page layout component with no landmark elements. Only flag in top-level layout files, not individual components.

**Fix:** Wrap content sections in appropriate landmark elements.

---

## 3. Performance Patterns

### 3.1 Image Dimensions

**Rule:** Images must specify dimensions to prevent layout shift.

**What to grep for:**
```
Grep: "<img |<Image " in changed files
```

**Violation:** An `<img>` without `width` and `height` attributes (or CSS `aspect-ratio`). Next.js `<Image>` requires `width`/`height` or `fill` prop.

**Fix:** Add explicit `width` and `height` attributes, or use CSS `aspect-ratio`.

### 3.2 Animation Performance

**Rule:** Animations should use compositor-friendly properties.

**What to grep for:**
```
Grep: "transition:.*width|transition:.*height|transition:.*top|transition:.*left|transition:.*margin|transition:.*padding" in CSS/SCSS
Grep: "@keyframes" — then check if keyframes animate layout properties
```

**Violation:** Transitioning layout-triggering properties (width, height, top, left, margin, padding) instead of compositor-friendly properties (transform, opacity).

**Fix:** Use `transform: translateX/Y/scale` instead of animating position/size. Use `opacity` for show/hide.

### 3.3 Font Loading

**Rule:** Custom fonts should not block rendering.

**What to grep for:**
```
Grep: "@font-face" in CSS/SCSS — check for font-display property
Grep: "fonts.googleapis.com" — check URL includes &display=swap
```

**Violation:** A `@font-face` rule without `font-display: swap` (or `optional`). A Google Fonts URL without `display=swap`.

**Fix:** Add `font-display: swap` to `@font-face`. Add `&display=swap` to Google Fonts URLs.

### 3.4 Icon Library Imports

**Rule:** Import individual icons, not the entire library.

**What to grep for:**
```
Grep: "from 'lucide-react'" — should import specific: { Icon1, Icon2 }
Grep: "from 'react-icons'" — should use subpath: 'react-icons/fi'
Grep: "import \* as Icons" — barrel import of icons
```

**Violation:** Importing the entire icon library barrel (`import * as Icons from 'lucide-react'`). Tree-shaking varies by bundler — explicit named imports are always safe.

**Fix:** Import only the icons used: `import { ArrowRight, Check } from 'lucide-react'`.

### 3.5 Large List Rendering

**Rule:** Lists with many items should consider virtualization.

**What to look for:** A `.map()` rendering items from an array or API response without any pagination, virtualization, or item limit.

**Violation:** Rendering an unbounded list (e.g., `items.map(item => <Row />)`) where `items` could exceed 50 entries, with no `slice`, pagination, or virtualization wrapper.

**Note:** This is a judgment call, not a mechanical grep. Flag only when the data source is clearly unbounded (API responses, database queries) and the component renders all items.

**Fix:** Add pagination, `react-window`/`react-virtuoso` for long lists, or `slice(0, limit)` with a "show more" pattern.

---

## 4. Compositional Rules

### 4.1 Card Discipline
**Rule:** Default to cardless layouts. Cards allowed only when they contain user interaction.
**What to grep for:** `.card`, `Card` imports, `rounded-lg shadow` or `rounded-xl shadow` on wrappers.
**Violation:** Card-styled element (border+shadow+radius+background) wrapping content with no button, link, input, or form inside.
**Fix:** Remove card treatment and use plain layout (section, column, divider).

### 4.2 Section Discipline
**Rule:** Each section has one purpose, one headline, usually one supporting sentence.
**What to look for:** `<section>` elements or major landmark divs. Count headings and CTAs within each.
**Violation:** A section with 3+ headings, 3+ buttons/CTAs, or 3+ paragraphs of body text.
**Fix:** Split into multiple focused sections, each with one job.

### 4.3 Hero Budget
**Rule:** First viewport contains only: brand, one headline, one supporting sentence, one CTA group, one dominant image.
**What to look for:** Hero/banner sections (class names containing "hero", "banner", "landing").
**Violation:** Hero with more than 1 heading + 1 subheading + 1 CTA group (up to 2 buttons) + 1 image/visual.
**Fix:** Remove excess elements. Move supporting content to the next section.

### 4.4 Copy Density
**Rule:** Sections should be scannable, not text-heavy.
**What to look for:** Count `<p>` tags or paragraph-length text blocks within each section.
**Violation:** A section with 3+ paragraphs of body text. Flag for review rather than hard-fail.

### 4.5 Typography Restraint
**Rule:** Maximum 2 font families per project (excluding monospace for code).
**What to grep for:** `font-family:` in CSS/SCSS, `fontFamily` in inline styles, font imports.
**Violation:** More than 2 distinct font families across changed files (not counting generic fallbacks).
**Fix:** Reduce to 2 families -- one display/heading font and one body font.
