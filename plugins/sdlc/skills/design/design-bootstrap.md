# Design Bootstrap Guide

How to scan a project for existing design tokens and generate `.claude/design-context.md`. This guide is used by the `sdlc:design init` phase.

## Overview

The bootstrap process has two paths:

1. **Existing design system detected** — extract tokens from config files and CSS into design-context.md
2. **No design system found** — guide the user through aesthetic selection, then create design-context.md as the source of truth

## Step 1: Scan for Design Tokens

Run these scans in order. Each populates a section of design-context.md.

### Component Library Detection

| What to find | Where to look | How to detect |
|---|---|---|
| shadcn/ui | `components.json` at project root | `Glob: **/components.json` then check for `"$schema": "https://ui.shadcn.com/schema.json"` |
| Radix UI | package.json | `Grep: "@radix-ui/" in package.json` |
| MUI | package.json | `Grep: "@mui/material" in package.json` |
| Chakra UI | package.json | `Grep: "@chakra-ui/react" in package.json` |
| Headless UI | package.json | `Grep: "@headlessui/react" in package.json` |
| Icon library | package.json | `Grep: "lucide-react\|@heroicons\|react-icons\|@phosphor-icons" in package.json` |

Populate the **Component Library** section with framework (react/vue/svelte/angular from package.json), library name, and icon package.

### Tailwind Config Detection

Look for Tailwind configuration:

```
Glob: **/tailwind.config.{js,ts,mjs,cjs}
Glob: **/postcss.config.{js,ts,mjs,cjs}  (check for tailwindcss plugin)
```

If found, extract:
- **Colors:** `theme.extend.colors` or `theme.colors` — map to Color Palette section
- **Fonts:** `theme.extend.fontFamily` or `theme.fontFamily` — map to Typography section
- **Spacing:** `theme.extend.spacing` or `theme.spacing` — map to Spacing section
- **Border radius:** `theme.extend.borderRadius` — note in design-context.md
- **Screens/breakpoints:** `theme.screens` — note responsive breakpoints

### CSS Variables Detection

Scan for CSS custom properties:

```
Grep: "--[a-zA-Z]" in **/*.css, **/*.scss
```

Focus on root-level variables (inside `:root` or `html` selectors). Extract:
- Color variables (`--color-*`, `--bg-*`, `--text-*`, `--primary`, `--accent`, etc.)
- Font variables (`--font-*`, `--heading-font`, `--body-font`)
- Spacing variables (`--spacing-*`, `--gap-*`, `--space-*`)
- Radius variables (`--radius-*`, `--rounded-*`)
- Shadow variables (`--shadow-*`)

### Font Detection

Multiple sources:

| Source | How to detect |
|---|---|
| Google Fonts link | `Grep: "fonts.googleapis.com" in **/*.html, **/*.css, **/*.tsx, **/*.jsx` |
| @font-face | `Grep: "@font-face" in **/*.css, **/*.scss` |
| Next.js fonts | `Grep: "next/font" in **/*.ts, **/*.tsx, **/*.js, **/*.jsx` |
| Font packages | `Grep: "@fontsource" in package.json` |
| CSS font-family | `Grep: "font-family:" in **/*.css, **/*.scss` — extract unique values |

### Color Extraction

Beyond config files, scan actual usage:

```
Grep: "#[0-9a-fA-F]{3,8}" in **/*.{css,scss,tsx,jsx,ts,js}
Grep: "rgb\(|rgba\(|hsl\(|hsla\(" in **/*.{css,scss,tsx,jsx,ts,js}
```

Deduplicate and identify the most-used colors. Map to semantic roles (primary, accent, surface, text, success, warning, error) by frequency and context.

### Spacing Scale Detection

Look for consistent spacing patterns:

```
Grep: "gap-|p-|px-|py-|m-|mx-|my-|space-" in **/*.{tsx,jsx}  (Tailwind classes)
Grep: "padding:|margin:|gap:" in **/*.{css,scss}
```

Identify the base unit (commonly 4px or 8px) and the scale multipliers in use.

### Motion Detection

```
Grep: "transition:|animation:|@keyframes" in **/*.{css,scss}
Grep: "transition|animate-|duration-" in **/*.{tsx,jsx}  (Tailwind classes)
Grep: "framer-motion|@react-spring|gsap" in package.json
```

Extract duration values and easing functions. Note the animation library if present.

## Step 2: Populate design-context.md

Use the scan results to fill each section. For sections with no data detected, leave them with placeholder comments.

### Output Template

Write to `.claude/design-context.md`:

```markdown
# Design Context

## Aesthetic Direction
direction: [detected or user-selected]
commitment: [key visual commitments]

## Typography
display: [display/heading font]
headline: [secondary heading font, if different from display]
body: [body text font]
caption: [small text font, if different from body]
mono: [monospace font, if detected]
scale: [type scale ratio, e.g., 1.25 (major third)]

## Color Palette
background: [hex]
surface: [hex]
primary-text: [hex]
muted-text: [hex]
accent: [hex]
success: [hex]
warning: [hex]
error: [hex]

## Spacing
base: [base unit, e.g., 8px]
scale: [array of values]

## Component Library
framework: [react/vue/svelte/angular]
library: [component library name]
icons: [icon library]

## Motion
philosophy: [detected pattern or user choice]
duration-fast: [ms]
duration-normal: [ms]
easing: [css easing function]
reduced-motion: respected

## Accessibility
target: WCAG 2.1 AA
min-contrast: 4.5:1 (normal text), 3:1 (large text)
focus-visible: always
```

### Mapping Rules

| Scan result | Design-context section | Field |
|---|---|---|
| shadcn components.json `style` | Aesthetic Direction | Infer from style (new-york = editorial, default = clean) |
| Tailwind `fontFamily.sans` | Typography | body |
| Tailwind `fontFamily.serif` | Typography | display (if present) |
| Tailwind `fontFamily.mono` | Typography | mono |
| Tailwind `colors.primary` | Color Palette | accent |
| CSS `--primary` | Color Palette | accent |
| CSS `--background`, `--bg` | Color Palette | background |
| CSS `--muted`, `--text-muted` | Color Palette | muted-text |
| CSS `--foreground`, `--text` | Color Palette | primary-text |
| Tailwind `spacing` | Spacing | base + scale |
| CSS transition durations | Motion | duration-fast, duration-normal |

## Step 3: No Design System Found

When scans return no configuration files, CSS variables, or consistent patterns, guide the user through aesthetic selection.

### Aesthetic Direction Selection

Present the 11 aesthetic modes (from frontend-design-principles.md):

1. **Brutally minimal** — extreme reduction, monochrome, sharp edges
2. **Maximalist chaos** — dense, layered, overwhelming intentionally
3. **Retro-futuristic** — CRT glow, scan lines, terminal aesthetics
4. **Organic/natural** — earth tones, soft curves, hand-drawn feel
5. **Luxury/refined** — high contrast, serif typography, generous whitespace
6. **Playful/toy-like** — bright primaries, rounded corners, bouncy motion
7. **Editorial/magazine** — strong typography hierarchy, grid-based, bold headlines
8. **Brutalist/raw** — exposed structure, monospace, no decoration
9. **Art deco/geometric** — symmetry, gold accents, ornamental borders
10. **Soft/pastel** — muted palette, gentle gradients, airy spacing
11. **Industrial/utilitarian** — functional, dense information, no ornament

Ask the user to pick a direction or describe their own. Then:

1. Select fonts that match the direction (never Inter, Roboto, Arial, system fonts)
2. Generate a color palette with semantic roles
3. Define a spacing scale (base 4px or 8px)
4. Set motion philosophy (subtle vs expressive)
5. Write the complete design-context.md

### Font Selection Guidance

Match font character to aesthetic direction:

| Direction | Display font character | Body font character |
|---|---|---|
| Editorial/magazine | High-contrast serif (Playfair Display, Cormorant) | Clean sans (Source Sans, Libre Franklin) |
| Brutally minimal | Geometric sans (Outfit, Syne) | Same as display |
| Retro-futuristic | Monospace (Space Mono, IBM Plex Mono) | Clean sans or same mono |
| Organic/natural | Rounded serif (Lora, Crimson Text) | Soft sans (Nunito, Karla) |
| Luxury/refined | Elegant serif (Cormorant Garamond, DM Serif) | Light sans (Jost, Raleway) |

## Step 4: Validation

After generating design-context.md, verify:

1. Every section has values (no empty fields)
2. Color hex values are valid 3 or 6 digit hex codes
3. Contrast ratios between text and surface colors meet WCAG AA (4.5:1)
4. Font names are specific (not generic families like sans-serif alone)
5. Spacing scale is internally consistent (follows a base multiplier)
6. The file is under 50 lines (design-context.md should be concise)

## When to Re-bootstrap

Run `sdlc:design init` again when:
- Switching component libraries
- Major redesign or rebrand
- Adding Tailwind to a project that didn't have it
- The design-context.md feels stale (colors/fonts no longer match actual usage)

The init phase checks for an existing design-context.md and asks before overwriting.
