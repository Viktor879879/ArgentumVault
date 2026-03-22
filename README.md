# Argentum Vault

## Local secrets

Runtime config is loaded from Xcode build settings (`Config/AppConfig.xcconfig`).
Sensitive values are overridden from local `Config/Secrets.xcconfig`.

1. Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig`.
2. Fill `SUPABASE_URL` and `SUPABASE_ANON_KEY`.
3. Build the app.

`Config/Secrets.xcconfig` is gitignored.

Use only the Supabase publishable/anon client key in the app.
Never ship a `service_role` or other server-side secret in the client bundle.
