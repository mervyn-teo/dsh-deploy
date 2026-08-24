---
name: publishing-dsh-plugins
description: Publish a DSH (DeepSeek Harness) plugin to npm so dshmarket installs it from a prebuilt tarball with a download count. Covers pre-publish package checks, npm 2FA/passkey auth pitfalls (E403/EOTP/ENEEDAUTH), the repository-field linking rule for awesome-dsh-plugin, and post-publish verification. Use when the user asks to publish, release, or ship a dsh-plugin-* package to npm.
---

# Publish DSH Plugins to npm

Publishing to npm is **purely additive**: the awesome-dsh-plugin listing is unaffected either way, GitHub installs keep working, and once linked, dshmarket prefers the npm tarball (seconds instead of a GitHub download), shows a download count, and skips the `allowBuilds` build-approval prompt because the tarball is prebuilt.

These steps encode hard-won lessons from previous publishes — follow them in order.

## 1. Pre-publish package checks

Fix these in `package.json` **before** touching npm:

- **`repository` field must point back at the exact GitHub repo listed in awesome-dsh-plugin.** This is the one step people miss — it is what links the npm package to the registry entry (deliberate name-squatting protection). Use the full form:
  ```jsonc
  { "repository": { "type": "git", "url": "https://github.com/owner/repo.git" } }
  ```
- **Name**: `dsh-plugin-*`, not taken on npm. Check with `npm view <name>` — an **E404 means the name is free**, not an error.
- **Version**: bump with `npm version patch|minor|major` (or by hand); republishing an existing version fails.
- **`files`/tarball contents**: previous good publishes contained exactly `lib/` (built output), `cordis.patch.yml`, `README.md`, `README.zh.md`, `LICENSE`, and `package.json`. Verify with `npm pack --dry-run` and check the file list — do not ship `src/`, tests, or `node_modules`.
- **Official `@deepseek-ai/*` packages must be `peerDependencies`** (with an explicit prerelease branch in the range), **not `dependencies`** — otherwise installs hit `ERESOLVE` on prerelease harness builds.
- Build first so `lib/` is current; ensure the working tree is committed.

## 2. Authentication — expect friction here

This is where previous publishes actually failed. Handle it up front:

1. Run `npm whoami`.
   - **ENEEDAUTH** → not logged in. Do **not** silently retry; ask the user to run `npm login` themselves (past sessions chose this), or use a granular access token with bypass-2fa. The account may have **passkey-only 2FA** (`auth-and-writes`), so login/publish goes through npm's **WebAuthn browser flow**.
2. Run the publish and watch for:
   - **E403 Forbidden** ("Two-factor authentication or granular access token with bypass 2fa enabled") → auth token lacks publish rights; redo login/token as above. Do not keep republishing — it will keep failing with the same 403.
   - **EOTP** with an `https://www.npmjs.com/auth/cli/...` URL → surface the URL to the user; they must complete browser authentication. After authenticating, re-run the same publish command.
   - **EROFS / ENOTEMPTY** on `~/.npm/_cacache` or `node_modules` → local filesystem problem (read-only cache, stale dirs); fix permissions/remove the stale directory before retrying.
3. Note: once one publish in the session authenticates via WebAuthn, **subsequent publishes reuse the session** and go through instantly — publish multiple plugins in sequence.

## 3. Publish

```bash
npm publish --access public
```

## 4. Post-publish verification and expectations

- Verify with `npm view <name> version` and check `repository.url`.
- **Replication lag is normal**: right after publish, `npm view` or the abbreviated-metadata endpoint may briefly 404. Confirm via the `/latest` document (`https://registry.npmjs.org/<name>/latest`) and tell the user a transient 404 within the first hour is just cache catching up — the package is live.
- **Do NOT open a PR, notify anyone, or hand-edit the awesome-dsh-plugin entry.** The npm↔repo mapping is picked up automatically from the registry by daily CI (typically within ~a day). A hand-written `npm:` key in the entry YAML is **rejected by validation** — there is no field to fill in.
- Report the result as: package@version, repository link confirmed, and the "what happens next automatically" summary (CI link → dshmarket prefers tarball, download count, no build prompt).

## Quick reference: errors seen before

| Error | Meaning | Fix |
|---|---|---|
| ENEEDAUTH | Not logged in | User runs `npm login` |
| E403 Forbidden | 2FA/passkey or bypass-2fa token required | Re-auth via WebAuthn browser flow or granular token |
| EOTP + auth URL | One-time browser auth needed | Give user the URL, then re-run publish |
| E404 on `npm view` (pre-publish) | Name is free | Proceed |
| E404 on `npm view` (just after publish) | Replication lag | Check `/latest`; wait, it's live |
| EROFS / ENOTEMPTY | Local FS/cache problem | Fix `~/.npm` perms, remove stale dirs |
| ERESOLVE (on install) | `@deepseek-ai/*` in dependencies | Move to peerDependencies with prerelease range |
