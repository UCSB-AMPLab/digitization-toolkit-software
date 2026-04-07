---
applyTo: "frontend/**"
---

# Specific instructions for frontend development.

## ⛔ CSS Location — Non-Negotiable Rules

**ALL CSS must live in `frontend/static/app.css`. No exceptions.**

### FORBIDDEN patterns — never do these:

```svelte
<!-- ❌ NEVER: <style> blocks inside .svelte files -->
<style>
  .my-button { color: red; }
</style>
```

```svelte
<!-- ❌ NEVER: inline style attributes -->
<div style="color: red; margin: 8px;">...</div>
<button style="background: blue;">...</button>
```

```ts
// ❌ NEVER: style strings in TypeScript/JavaScript
element.style.color = 'red';
const styles = { color: 'red' };
```

```svelte
<!-- ❌ NEVER: style directives -->
<div style:color="red">...</div>
```

### CORRECT pattern — always do this:

Add a named class to `frontend/static/app.css`, then apply it in the template:

```css
/* frontend/static/app.css */
.my-button {
  color: var(--accent-primary);
  margin: var(--spacing-sm);
}
```

```svelte
<!-- frontend/src/lib/components/MyComponent.svelte -->
<button class="my-button">Click me</button>
```

### Dynamic state is the only exception

Only JS-driven dynamic values that cannot be expressed as toggled CSS classes may use a style binding, and only with a CSS variable:

```svelte
<!-- ✅ ALLOWED only when value is truly dynamic -->
<div style="--progress: {percent}%">...</div>
```

```css
/* The visual rule still lives in app.css */
.progress-bar::after { width: var(--progress); }
```

---

## CSS Variables

All colors, spacing, and typography values are defined as CSS variables in `app.css`. **Always use variables — never hard-code values.**

| Variable | Purpose |
|---|---|
| `--bg-color` | Page background (#ffffff) |
| `--bg-gray` | Secondary background (#f2f2f2) |
| `--text-color` | Body text (#757575) |
| `--text-dark` | Heading/emphasis text (#000000) |
| `--text-muted` | Muted/disabled text (#858585) |
| `--accent-primary` | Brand blue (rgba(41,98,255,0.8)) |
| `--accent-hover` | Hover accent (#f18e00) |
| `--accent-link` | Link color (#F2784B) |
| `--footer-bg` | Footer background (#003660) |
| `--footer-text` | Footer text (#ffffff) |
| `--spacing-sm` | 0.5rem |
| `--spacing-md` | 1rem |
| `--spacing-lg` | 1.5rem |
| `--spacing-xl` | 2rem |
| `--spacing-xxl` | 3rem |

When you need a new reusable value, **add it as a CSS variable in `:root`** inside `app.css` before using it.

---

## CSS Organization in app.css

Follow these section headers when adding new rules:

```css
/* ==================== */
/* Component Name       */
/* ==================== */
```

Group styles by component or feature. Keep existing sections intact. Do not scatter related rules.

---

## Project Specific Guidelines

- The default screen is a **7-inch display**. All styles must be optimized for 800×480 and 1024×600 resolutions first, then scale up for larger screens.
- Use relative units (`rem`, `%`, `vh`/`vw`) over fixed `px` wherever possible.
- Test layout at both 800×480 and 1024×600 before considering work done.

---

## Svelte Component Rules

- `.svelte` files contain **only** `<script>`, template markup, and **no** `<style>` blocks.
- Apply styling exclusively through CSS classes defined in `app.css`.
- Use `class:` directive for conditional classes (not `style:`):

```svelte
<!-- ✅ CORRECT: toggle a class -->
<div class:active={isActive} class="panel">...</div>

<!-- ❌ WRONG: toggle a style -->
<div style:background={isActive ? 'blue' : 'gray'}>...</div>
```

---

## Building

- The project is built on Docker. IDE errors on some library imports are due to VSCode not resolving dependencies installed inside the container — these are not real errors.
- The backend runs **natively** (not in Docker). See the root `copilot-instructions.md` for details.
