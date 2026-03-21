<<<<<<< HEAD
# ArgentumVault
=======
# Argentum Vault

## Local secrets

Runtime config is loaded from Xcode build settings (`Config/AppConfig.xcconfig`).
Sensitive values are overridden from local `Config/Secrets.xcconfig`.

1. Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig`.
2. Fill `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `ALPHA_VANTAGE_API_KEY`.
3. Build the app.

`Config/Secrets.xcconfig` is gitignored.
>>>>>>> e7f7d2999b9a266a8418c45383605c4abe66fbbd
