# Google Drive / Docs setup (manual, owner-only)

These steps need a Google account with access to Google Cloud Console and cannot be automated from this repository.

1. **Create a Google Cloud project** for Companion (separate projects or clients for development and production).
2. **Enable APIs**: Google Drive API, Google Docs API (and Google Picker API if you host a picker page).
3. **OAuth consent screen**: app name, support email, app logo (licensed), privacy policy URL, terms URL, authorized domains. Add test users while in *Testing*.
4. **Scopes**: `openid`, `email`, `https://www.googleapis.com/auth/drive.file` (default, non-sensitive per-file access). Only add `drive.metadata.readonly` / `drive.readonly` if you will offer those modes publicly — they are restricted scopes requiring verification and possibly a security assessment.
5. **Create an OAuth client** of type **Desktop app**. Note the client ID (and the non-confidential client secret Google issues for desktop clients).
6. **Build with the client**:
   ```bash
   GOOGLE_CLIENT_ID=xxxx.apps.googleusercontent.com GOOGLE_CLIENT_SECRET=xxxx scripts/build-app.sh
   ```
   For development runs you can instead export `COMPANION_GoogleOAuthClientID` / `COMPANION_GoogleOAuthClientSecret`.
7. **Document selection**: with `drive.file`, Companion can read only files the user selects with the Google Picker or that Companion created. The desktop Picker flow requires a small HTTPS page you host (`GOOGLE_PICKER_URL`) per Google's desktop Picker guide. Until then, users can add documents created by Companion, or use the *Broad reading* mode with test users.
8. **School accounts**: verify with a permitted test account whether the Workspace admin allows third-party access; do not assume it.
9. **Production verification**: submit the consent screen for verification for the scopes you request; recheck Google's user-data policy for the LLM disclosure flow before public release.

The redirect is a loopback address (`http://127.0.0.1:<random port>`), which Google allows for desktop clients without registering it.
