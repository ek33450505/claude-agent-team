---
name: typescript-conventions
description: TypeScript, React, and UI accessibility conventions for CAST projects. Load when writing, reviewing, or debugging TypeScript/TSX/React code, or when checking accessibility (a11y, aria, focus, contrast, keyboard navigation). Covers file naming, type patterns, hooks, component conventions, testing approach, and the a11y checklist.
user-invocable: false
allowed-tools: []
---

# TypeScript Conventions

- Use React 19 patterns: functional components, hooks, no class components
- Extend existing types rather than type casting: `type UserAdmin = User & { isAdmin: true }` instead of `(user as UserAdmin)`
- Component files: PascalCase (`UserProfile.tsx`)
- Hook files: camelCase prefixed with `use` (`useLocalStorage.ts`)
- Test files live alongside source: `Foo.tsx` -> `Foo.test.tsx`
- Use Vitest + React Testing Library for tests (not Jest in Vite projects)
- Test behavior with `getByRole`/`getByText`, not `getByTestId`
- Import order: React, third-party, local modules, types (enforce with ESLint)
- Prefer `interface` over `type` for object shapes that may be extended
- Use `satisfies` operator for type-safe config objects

## Accessibility (UI projects)

Applies on the FIRST pass, never as a later sweep. Dispatch `frontend-qa` for a
dedicated a11y review before commit on UI-heavy changes.

- Every icon-only button/link gets `aria-label`; decorative icons get `aria-hidden="true"`
- Visible `:focus-visible` state on every interactive element — never rely on browser default rings on dark themes
- Color contrast >= 4.5:1 for text and meaningful icons
- Hit target >= 44x44 px on touch surfaces
- Form inputs have `<label>`, `autoComplete`, and `aria-describedby` for errors
- Animation respects `prefers-reduced-motion` via `useReducedMotion()` or CSS media query
- Semantic HTML first (`<button>`, `<a>`, `<nav>`, `<main>`); ARIA only when semantic HTML is insufficient
- Keyboard navigation works end-to-end — logical tab order, modal focus trap, Escape closes overlays
