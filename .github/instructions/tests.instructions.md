---
applyTo: "test/**/*.test.js"
---
# Test conventions
- Use node:test and node:assert/strict.
- Start the app with app.listen(0) and close the server when the test ends.
- For every endpoint, cover the success path, invalid input (400) and not found (404).
- Test pure front-end helpers from public/ by importing them directly; no browser is needed.
- Do not depend on today's date: pass dates into the code under test.
