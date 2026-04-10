# WCAG 2.1 AA Accessibility Rules

Actionable checklist for verifying WCAG 2.1 Level AA compliance by reading code. Every rule includes what to look for and how to fix violations. Used by the critic during builds and the design-reviewer during review.

Organized by WCAG's four principles: Perceivable, Operable, Understandable, Robust (POUR).

---

## Perceivable

Information and UI must be presentable in ways users can perceive.

### 1.1.1 Non-text Content

**Rule:** Every non-text element must have a text alternative.

| Element | Required | Verify |
|---|---|---|
| `<img>` | `alt` attribute | Grep for `<img` without `alt=` |
| `<svg>` | `aria-label` or `<title>` child | Grep for `<svg` — check for labeling |
| `<input type="image">` | `alt` attribute | Grep for `type="image"` without `alt=` |
| `<area>` | `alt` attribute | Grep for `<area` without `alt=` |
| Icon-only buttons | `aria-label` on button | Grep for `<button>` containing only `<svg>` or icon component |
| Decorative images | `alt=""` (empty) and `aria-hidden="true"` | Decorative images must explicitly opt out |

**Common violations:**
- `<img src="banner.jpg">` — missing alt entirely
- `<img alt="image">` — alt text describes the element type, not the content
- Icon button with no accessible name: `<button><ArrowIcon /></button>`

**Fix:** Add descriptive `alt` text. For decorative images, use `alt=""`. For icon buttons, add `aria-label`.

### 1.3.1 Info and Relationships

**Rule:** Structure conveyed visually must also be conveyed programmatically.

**What to verify:**
- Headings use `<h1>`-`<h6>` (not styled divs/spans)
- Lists use `<ul>`, `<ol>`, `<dl>` (not repeated divs)
- Tables use `<table>`, `<th>`, `<td>` with `scope` on headers
- Form groups use `<fieldset>` and `<legend>`
- Related inputs grouped logically

**Common violations:**
- `<div className="heading">` styled to look like a heading
- Tab-like UI built from divs without `role="tablist"`, `role="tab"`, `role="tabpanel"`
- Data presented in grid divs instead of `<table>`

**Fix:** Use native HTML elements that convey structure. Add ARIA roles only when native elements are insufficient.

### 1.3.2 Meaningful Sequence

**Rule:** DOM order must match visual reading order. Flag CSS `order`, `flex-direction: row-reverse`, or absolute positioning that creates visual/DOM order mismatch.

**Fix:** Reorder DOM to match visual layout.

### 1.4.1 Use of Color

**Rule:** Color must not be the sole means of conveying information.

**What to verify:**
- Error states use icon or text in addition to red color
- Links in body text are underlined or have non-color indicator
- Status indicators use shape/icon alongside color
- Form validation shows text message, not just red border

**Common violations:**
- `<span className="text-red-500">{error}</span>` with no icon or "Error:" prefix
- Active tab distinguished only by color

**Fix:** Add a secondary indicator: icon, text label, underline, or shape change.

### 1.4.3 Contrast (Minimum)

**Rule:** Text must have 4.5:1 contrast ratio against background (3:1 for large text).

| Text size | Minimum ratio |
|---|---|
| Normal text (< 18pt / < 14pt bold) | 4.5:1 |
| Large text (>= 18pt / >= 14pt bold) | 3:1 |

**What to verify in code:**
- Check text color against background color in the same component
- Flag low-opacity text: `opacity-30`, `text-opacity-40`, `color: rgba(*, *, *, 0.4)`
- Flag light-on-light: white/gray text on light backgrounds
- Flag dark-on-dark: dark text on dark backgrounds

**Common violations:**
- Placeholder text with `text-gray-400` on white background (3.0:1)
- Disabled text with `opacity: 0.3`

**Fix:** Increase contrast to meet minimums. Disabled elements are exempt from 4.5:1 but should still be perceivable.

### 1.4.4 Resize Text

**Rule:** Text must be readable at 200% zoom without loss of content.

**What to verify:** No `overflow: hidden` on text containers without `text-overflow: ellipsis`. No fixed-height containers that clip text. Font sizes use relative units (`rem`, `em`) not absolute (`px`) for body text.

**Fix:** Use relative units. Replace fixed heights with `min-height`.

### 1.4.11 Non-text Contrast

**Rule:** UI components and graphical objects need 3:1 contrast against adjacent colors.

**What to verify:**
- Form input borders visible against background (3:1)
- Button borders/backgrounds distinguishable
- Icon contrast against background
- Focus indicators visible (covered in 2.4.7)

**Common violations:**
- Light gray input border (`#e5e7eb`) on white background (1.5:1)
- Ghost buttons with low-contrast borders

**Fix:** Darken borders and UI element colors to meet 3:1 minimum.

---

## Operable

UI components and navigation must be operable.

### 2.1.1 Keyboard

**Rule:** All functionality must be available via keyboard.

**What to verify:**
- Every `onClick` handler is on a focusable element (`<button>`, `<a>`, `<input>`, or element with `tabIndex`)
- Drag-and-drop has keyboard alternative
- Custom components (dropdowns, modals, tabs) handle keyboard events

**Common violations:**
- `<div onClick={handler}>` — not focusable, not activatable via keyboard
- Custom dropdown with no `onKeyDown` for arrow navigation
- Slider with no keyboard increment/decrement

**Fix:** Use `<button>` for actions, `<a>` for navigation. Add `tabIndex="0"` and `onKeyDown` for custom interactive elements.

### 2.1.2 No Keyboard Trap

**Rule:** Focus must not get trapped in any component.

**What to verify:**
- Modals/dialogs have a close mechanism (Escape key, close button)
- Modal focus trapping returns focus to trigger on close
- Tab key cycles through focusable elements (does not get stuck)

**Common violations:**
- Modal without `onKeyDown` handler for Escape
- Focus trap that prevents tabbing out without explicit close

**Fix:** Add Escape key handler. Return focus to the element that opened the modal on close.

### 2.4.1 Bypass Blocks

**Rule:** Provide a mechanism to skip repeated content.

**What to verify:**
- Skip-to-content link as first focusable element in layout
- `<a href="#main-content" className="sr-only focus:not-sr-only">Skip to content</a>`

**Violation:** Page layout with navigation but no skip link.

**Fix:** Add a skip-to-content link that becomes visible on focus, targeting `<main id="main-content">`.

### 2.4.3 Focus Order

**Rule:** Focus order must follow a logical reading sequence.

**What to verify:**
- No positive `tabIndex` values (`tabIndex="1"`, `tabIndex="5"`) — these override natural order
- Modal focus is trapped within the modal when open
- After dynamic content appears, focus moves to it or it is announced

**Common violations:**
- `tabIndex="1"` to force an element to receive focus first
- Dynamically inserted content that should receive focus but does not

**Fix:** Remove positive tabIndex values. Use `tabIndex="0"` for natural order. Manage focus programmatically with `ref.focus()` for dynamic content.

### 2.4.7 Focus Visible

**Rule:** Keyboard focus indicator must be visible.

**What to verify:**
```
Grep: "outline: none|outline: 0|outline:none|outline:0" in CSS/SCSS
Grep: "focus:outline-none" in TSX/JSX (Tailwind)
```

**Violation:** Removing the default outline without providing a replacement. Acceptable replacement: `:focus-visible` with `ring`, `border`, or `box-shadow`.

**Fix:** Use `:focus-visible` (not `:focus`) with a visible indicator: `outline: 2px solid`, `box-shadow: 0 0 0 2px`, or Tailwind `focus-visible:ring-2`.

### 2.5.5 Target Size

**Rule:** Touch/click targets must be at least 44x44 CSS pixels.

**What to verify:**
- Buttons and links have adequate padding
- Icon-only buttons have min-width/min-height or padding
- Inline links in dense text have adequate line-height

**Common violations:**
- Small icon button: `<button className="p-1"><Icon size={16} /></button>` (approx 24x24px)
- Close button in corner with minimal padding

**Fix:** Ensure minimum 44x44px clickable area through padding, min-width/min-height.

---

## Understandable

Information and UI operation must be understandable.

### 3.1.1 Language of Page

**Rule:** Page must declare its language.

**What to verify:**
```
Grep: "<html" in layout/root files — check for lang= attribute
```

**Violation:** `<html>` without `lang` attribute.

**Fix:** Add `lang="en"` (or appropriate language code) to the `<html>` element.

### 3.3.1 Error Identification

**Rule:** Errors must be identified and described in text.

**What to verify:**
- Form validation shows text error messages, not just visual cues
- Error messages are specific ("Email is required" not just "Error")
- Error messages are associated with inputs via `aria-describedby`

**Fix:** Add text error messages adjacent to the input. Link with `aria-describedby`.

### 3.3.2 Labels or Instructions

**Rule:** Form inputs must have labels and necessary instructions.

**What to verify:**
- Every `<input>`, `<select>`, `<textarea>` has a visible label
- Required fields are indicated (not just with color)
- Format requirements stated before the input ("YYYY-MM-DD")

**Violation:** Input with only `placeholder` and no `<label>`.

**Fix:** Add a visible `<label>` element. Placeholder is not a substitute for a label.

---

## Robust

Content must be robust enough for assistive technologies.

### 4.1.1 Parsing

**Rule:** HTML must be well-formed with no duplicate IDs.

**What to verify:**
```
Grep: "id=\"" in changed files — check for duplicates within the same component tree
```

**Violation:** Two elements with the same `id` value rendered on the same page.

**Fix:** Use unique IDs. For lists, append the item key: `id={`input-${item.id}`}`.

### 4.1.2 Name, Role, Value

**Rule:** Custom components must expose name, role, and value to assistive tech.

| Component | Required ARIA |
|---|---|
| Custom toggle | `role="switch"`, `aria-checked` |
| Custom dropdown | `role="listbox"`, `aria-expanded` |
| Custom tabs | `role="tablist"`, `role="tab"`, `role="tabpanel"` |
| Custom modal | `role="dialog"`, `aria-modal="true"` |

**Fix:** Add appropriate ARIA roles and states. Prefer native HTML elements when possible.

### 4.1.3 Status Messages

**Rule:** Status messages must be announced without receiving focus.

| Message type | Required ARIA |
|---|---|
| Toast/notification | `aria-live="polite"` or `role="status"` |
| Error summary | `aria-live="assertive"` or `role="alert"` |
| Loading indicator | `aria-live="polite"` with status text |

**Fix:** Wrap status containers in `aria-live` regions. The region must exist in DOM before the message appears.
