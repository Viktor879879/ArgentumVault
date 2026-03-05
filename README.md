# Argentum Vault

## Local secrets

Runtime config is loaded from Xcode build settings (`Config/AppConfig.xcconfig`).
Sensitive values are overridden from local `Config/Secrets.xcconfig`.

1. Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig`.
2. Fill `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `ALPHA_VANTAGE_API_KEY`.
3. Build the app.

`Config/Secrets.xcconfig` is gitignored.
