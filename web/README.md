# Location Suite web

The Vite project serves two surfaces:

- `/` is the public product page. Its route and diagnostics previews are illustrative, not live device status.
- `/app` is the existing browser device-control interface. It still calls the local FastAPI backend and retains its point, route, favorites, and history tools.

Run `npm install` (or `pnpm install` with the checked-in lockfile), then `npm run dev`. Use `npm run build`, `npm run lint`, and `npm test` to verify the web project.

The iOS download section links to this repository's IPA workflow artifact. Access may require repository permissions. The release documentation does not yet configure a public direct-download feed, so the page does not advertise one.
