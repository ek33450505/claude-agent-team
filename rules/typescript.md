---
globs:
  - "**/*.ts"
  - "**/*.tsx"
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
