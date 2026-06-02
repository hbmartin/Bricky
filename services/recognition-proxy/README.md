# Bricky AI Subject Recognition Proxy

Azure Functions (v4, TypeScript) HTTP proxy that powers Bricky's **AI Subject
Recognition** Pro feature. The iOS app never holds the Azure OpenAI key — it
calls this proxy with a StoreKit 2 entitlement token (JWS). The proxy:

1. **Verifies the App Store entitlement** (active `Bricky Pro` subscription).
2. **Enforces a per-user monthly fair-use quota** server-side.
3. Calls **Azure OpenAI GPT-4o vision** to identify celebrities, cartoon
   characters, famous places/landmarks, musicians, etc.
4. Returns a normalized `RecognitionResult` JSON (subjects + `remainingQuota`).

> Pay-per-use only. No always-on compute. Stays under the project cloud cap.

## Contract

`POST /api/recognizeImage`

```jsonc
// request
{
  "imageBase64": "<jpeg base64, no data: prefix>",
  "entitlementToken": "<StoreKit 2 JWS representation>"
}
```

```jsonc
// 200 OK
{
  "subjects": [
    {
      "name": "Eiffel Tower",
      "category": "landmark",      // person|character|landmark|place|musician|artwork|animal|object|unknown
      "confidence": 0.94,           // 0...1
      "summary": "Wrought-iron lattice tower on the Champ de Mars in Paris.",
      "location": "Paris, France"   // optional
    }
  ],
  "remainingQuota": 87
}
```

Error responses use `{ "error": "<message>", "code": "<machine_code>" }`:

| HTTP | code              | Meaning                                   |
|------|-------------------|-------------------------------------------|
| 400  | `bad_request`     | Missing/invalid image or token            |
| 401  | `not_entitled`    | Entitlement token invalid/expired         |
| 403  | `not_entitled`    | No active Pro subscription                 |
| 429  | `quota_exceeded`  | Monthly allowance used up                  |
| 502  | `upstream_error`  | Azure OpenAI call failed                   |

The iOS `AzureOpenAIRecognitionClient` maps these statuses directly.

## Configuration (App Settings / Key Vault references)

| Setting                          | Description                                            |
|----------------------------------|--------------------------------------------------------|
| `AZURE_OPENAI_ENDPOINT`          | e.g. `https://<resource>.openai.azure.com`            |
| `AZURE_OPENAI_API_KEY`           | **Key Vault reference** — never inline                |
| `AZURE_OPENAI_DEPLOYMENT`        | GPT-4o vision deployment name                          |
| `AZURE_OPENAI_API_VERSION`       | e.g. `2024-08-01-preview`                             |
| `APPSTORE_BUNDLE_ID`             | `com.bricky.app`                                       |
| `APPSTORE_ENVIRONMENT`           | `Production` or `Sandbox` (must match the token)       |
| `APPSTORE_VERIFY_CHAIN`          | `true` to cryptographically verify Apple's JWS chain   |
| `MONTHLY_QUOTA`                  | Fair-use cap per user per month (default `100`)        |
| `QUOTA_TABLE_CONNECTION`         | Azure Table Storage connection string for quota counts |

## Local run

```bash
npm install
npm run build
# add a local.settings.json (gitignored) with the settings above
npm start
```

## Deploy

```bash
npm run build
func azure functionapp publish bricky-recognition
```
