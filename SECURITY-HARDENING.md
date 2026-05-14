# Security hardening pass 1

This document describes the security defaults that ship with this fork and the additional steps a production deployment should take. It is the canonical reference for the changes in branch `security/hardening-pass-1`.

The defaults are tuned for **regulated / internal-business workloads**, not public demos. Every relaxation needed for a demo deployment is called out below.

---

## What changed by default

| Area | Before | After |
| --- | --- | --- |
| Sign-in (`useAuthentication`) | `false` | **`true`** — deployment fails fast if `clientAppId` / `serverAppId` are missing. |
| Application ingress (`appPublicNetworkAccess`) | n/a (single flag) | `Enabled` — front this with a WAF (see below). |
| Data plane ingress (`dataPlanePublicNetworkAccess`) | `Enabled` | **`Disabled`** — Storage, Search, OpenAI, Document Intelligence, Cosmos, ADLS are reachable only via private endpoints. |
| Data plane network ACL default action | `Allow` | **`Deny`** when data-plane public access is disabled. |
| Storage firewall `bypass` | `AzureServices` | **`None`**. |
| Private endpoints (`usePrivateEndpoint`) | `false` | **`true`**. |
| Blob soft-delete retention | `2` days | **`30`** days. |
| Container soft-delete | not set | **`30` days**. |
| Blob versioning | not set | **`true`** on user-content storage. |
| App Service `ftpsState` | `FtpsOnly` | **`Disabled`**. |
| FTP / SCM basic auth | (already off) | (still off). |
| CORS origin filter | accepts any string in `ALLOWED_ORIGIN` | **must be `https://...` with no trailing `/`**. |
| Portal CORS origins | always added | added **only when an Entra client app is configured**. |
| `/content/<path>` route | only path-traversal check | **strict allow-list** + scheme rejection + length cap + double-encode rejection + control-char rejection. See [`tests/test_content_path_validation.py`](tests/test_content_path_validation.py). |
| Diagnostic settings → Log Analytics | none | **wired on every data-plane resource** (Storage, OpenAI, Document Intelligence, Vision, Content Understanding, Speech, Search, Cosmos, App Service / Container App) when `useApplicationInsights=true`. |
| CI security scans | none | **CodeQL, gitleaks, PSRule for Azure, Dependabot**. |

### Demo-mode opt-out

To run the original demo defaults (open chat endpoint, public data plane), set the following with `azd env set` before `azd up`:

```pwsh
azd env set AZURE_USE_AUTHENTICATION false
azd env set AZURE_USE_PRIVATE_ENDPOINT false
azd env set AZURE_DATAPLANE_PUBLIC_NETWORK_ACCESS Enabled
azd env set AZURE_NETWORK_BYPASS AzureServices
```

⚠️ Doing this in a subscription with no spend cap exposes Azure OpenAI quota to anonymous internet callers. Use only in throwaway subscriptions.

---

## Items provided but not wired in by default

These items ship as standalone Bicep modules so you can adopt them in your environment. They are not wired into `main.bicep` automatically because each requires changes outside the Bicep file (Entra app registration, multi-pass deployment, or runtime configuration).

### 1. Azure Key Vault for Entra secrets — [`infra/core/security/keyvault.bicep`](infra/core/security/keyvault.bicep)

**Why it isn't on by default:** App Service / Container Apps Key Vault references require a two-pass deployment — the app's managed identity must be granted `Key Vault Secrets User` before the app setting reference will resolve. `azd up` provisions everything in one pass.

**To adopt:**

1. Run a first `azd up` with `useAuthentication=false` (or with the secret still in app settings).
2. After deployment, get the backend's principal ID and run a second deployment that includes:

   ```bicep
   module kv 'core/security/keyvault.bicep' = {
     scope: resourceGroup
     name: 'keyvault'
     params: {
       name: '${abbrs.keyVaultVaults}${resourceToken}'
       location: location
       tags: tags
       publicNetworkAccess: dataPlanePublicNetworkAccess
       secretReaderPrincipalIds: [
         deploymentTarget == 'appservice'
           ? backend!.outputs.identityPrincipalId
           : acaBackend!.outputs.identityPrincipalId
       ]
       secretOfficerPrincipalIds: [ principalId ]
     }
   }

   module clientSecret 'core/security/keyvault-secret.bicep' = if (!empty(clientAppSecret)) {
     scope: resourceGroup
     name: 'kv-client-secret'
     params: {
       keyVaultName: kv.outputs.name
       name: 'AZURE-CLIENT-APP-SECRET'
       value: clientAppSecret
     }
   }
   ```

3. Replace the plaintext `AZURE_CLIENT_APP_SECRET` app setting with a reference:

   ```text
   @Microsoft.KeyVault(SecretUri=<clientSecret.outputs.secretUri>)
   ```

4. Add a private endpoint for the Key Vault (re-use the existing private-endpoint pattern in `main.bicep`).

### 2. Azure Front Door + WAF — opt-in via `useFrontDoor=true`

Wired into `main.bicep` as an opt-in. When `useFrontDoor=true`:

- A **Premium Front Door profile** is provisioned together with a **WAF policy** that enables Microsoft's `DefaultRuleSet 2.1` + `BotManagerRuleSet 1.1`, a configurable per-minute rate limit, and an optional geo-allowlist.
- The App Service is locked down with an `ipSecurityRestrictions` rule that matches the `AzureFrontDoor.Backend` service tag **and** the `X-Azure-FDID` header containing the paired Front Door's unique ID. Direct calls to the App Service hostname return 403.
- For the Container Apps target the same Front Door ID is injected as `AZURE_EXPECTED_FRONT_DOOR_ID` so the backend can enforce the header in middleware — Container Apps' native ingress IP restrictions are CIDR-only and cannot match headers.

**To adopt:**

```pwsh
azd env set AZURE_USE_FRONT_DOOR true
azd env set AZURE_FRONT_DOOR_WAF_MODE Prevention       # or Detection while tuning
azd env set AZURE_FRONT_DOOR_RATE_LIMIT_PER_MINUTE 600
azd up
```

Optional: pass `frontDoorAllowedCountries` (e.g. `[ 'US', 'CA' ]`) to geo-fence.

After deployment:

1. Read the AFD endpoint hostname from `az afd endpoint show --resource-group <rg> --profile-name afd-<token> --endpoint-name <token>-endpoint --query hostName -o tsv`.
2. Add `https://<afd-hostname>` to the **redirect URIs** of the Entra client app and rerun `scripts/auth_update.py`.
3. Verify lockdown: `curl https://<app-service>.azurewebsites.net/` must return `403` (App Service) or be unreachable / unauthorized (Container Apps once the middleware is in place).

**Two-module design.** Bicep cannot create a Front Door origin in the same pass as the App Service it points to without a circular dependency on the AFD ID flowing back into App Service IP rules. The wiring is split:

- `infra/core/networking/frontdoor-waf.bicep` — phase 1: profile + WAF policy + endpoint + security policy. Emits `frontDoorId` consumed by the App Service IP rule and the Container App env var.
- `infra/core/networking/frontdoor-origin.bicep` — phase 2: origin group + origin + route, referenced via `existing`. Runs after the backend module so the origin hostname is known.

**Caveat — Container Apps middleware not yet implemented.** Setting `AZURE_EXPECTED_FRONT_DOOR_ID` is necessary but not sufficient for the Container Apps target; you must add a `before_request` hook in `app/backend/app.py` that rejects requests whose `X-Azure-FDID` header doesn't match. Tracked as a follow-up.

### 3. Diagnostic settings → Log Analytics *(wired in by default)*

Wired in by default whenever `useApplicationInsights=true` (which provisions the Log Analytics workspace). See `infra/core/monitor/*-diagnostics.bicep`:

- `storage-diagnostics.bicep` — account + blob/file/queue/table services (covers `StorageRead`/`StorageWrite`/`StorageDelete`).
- `cognitiveservices-diagnostics.bicep` — reused for OpenAI, Document Intelligence, Vision, Content Understanding, Speech.
- `cosmos-diagnostics.bicep` — `DataPlaneRequests` + `ControlPlaneRequests` + audit.
- `appservice-diagnostics.bicep` and `containerapp-diagnostics.bicep` — host audit + HTTP logs + all metrics.
- Search already had `search-diagnostics.bicep`.

Each is wired from `main.bicep` immediately after the resource it observes; all gated on `useApplicationInsights`. Set `AZURE_USE_APPLICATION_INSIGHTS=true` to enable them.

### 4. Workload Identity Federation (WIF) for the backend MSAL flow

The current Python backend's MSAL confidential client uses `AZURE_SERVER_APP_SECRET` for OBO token exchange. To eliminate this secret:

1. Add a federated identity credential to the Entra **server** app that trusts the App Service / Container App **system-assigned managed identity** as a subject.
2. Update `app/backend/core/authentication.py` to use `azure.identity.ManagedIdentityCredential().get_token('api://AzureADTokenExchange/.default')` as the `client_assertion` for the MSAL `ConfidentialClientApplication`.
3. Remove `AZURE_SERVER_APP_SECRET` and `AZURE_CLIENT_APP_SECRET` from app settings entirely.

**Note:** App Service / Container Apps **Easy Auth** (`authsettingsV2`) still requires a client secret for the OIDC handshake — it does not support WIF as of this writing. If you adopt WIF for the backend MSAL flow, set `disableAppServicesAuthentication=true` so the Python app handles sign-in directly via MSAL.

---

## Threat-model summary of the original issues

These were the five concrete dangers identified in the architecture review that motivated this branch:

1. **Public unauthenticated chat endpoint with token-burn risk** — mitigated by `useAuthentication=true` default + assertion that fails the deployment if no Entra app is configured. Front-door + WAF rate-limiting (opt-in) layers an additional control.
2. **`/content/<path>` blob-proxy SSRF / path traversal** — mitigated by `_sanitize_content_path` in [`app/backend/app.py`](app/backend/app.py) with tests in [`tests/test_content_path_validation.py`](tests/test_content_path_validation.py). The container boundary is enforced by `BlobManager.download_blob` which binds to a single configured container.
3. **Data exfiltration via AI Search** — mitigated by `disableLocalAuth=true` on Search, `azureOpenAiDisableKeys=true` on OpenAI, and managed-identity-only data plane. Private endpoint default further prevents direct internet access. With ACLs enabled (`enforceAccessControl=true`) the index is filtered per-user.
4. **Prompt injection** — partially mitigated. The system prompt instructs the model to refuse instructions embedded in documents, and the citation link route now refuses arbitrary URLs. **Residual risk: the model may still leak indexed content in violation of policy.** A content-safety / prompt-shield layer was deferred per the design discussion; consider Azure AI Content Safety prompt shields as a follow-up if you index untrusted documents.
5. **Secrets in plaintext app settings** — partially mitigated. Default secret count is reduced (Storage and Search use MI, OpenAI is keyless). Entra client/server secrets still land in plaintext app settings by default; see "Azure Key Vault for Entra secrets" above for the recommended migration. Tracking issue: open one in your fork referencing this section.

---

## Verification checklist for production

Before going live with this stack:

- [ ] `azd env get-values` shows `AZURE_USE_AUTHENTICATION=true` and an Entra app is registered with the correct redirect URIs.
- [ ] All data-plane resources show `publicNetworkAccess=Disabled` and `networkAcls.defaultAction=Deny` in the portal.
- [ ] Storage accounts have `allowSharedKeyAccess=false`, `supportsHttpsTrafficOnly=true`, `minimumTlsVersion=TLS1_2`, soft-delete + container-delete retention `>= 30` days, and versioning enabled where appropriate.
- [ ] Cosmos DB shows `disableLocalAuth=true`.
- [ ] AI Search shows `disableLocalAuth=true` and the index is reachable only over private endpoint.
- [ ] OpenAI account shows `disableLocalAuth=true` (already implied by `azureOpenAiDisableKeys=true`).
- [ ] App Service / Container App reports `httpsOnly=true`, `minTlsVersion='1.2'`, `ftpsState='Disabled'`, FTP & SCM basic-auth policies set to `allow: false`.
- [ ] CodeQL, gitleaks, and PSRule have all run green at least once on the deployment commit.
- [ ] Dependabot is enabled in repository settings.
- [ ] Front Door + WAF is in front of the application, and the App Service / Container App rejects direct traffic (verify by curling the origin hostname directly — it should fail).
- [ ] Diagnostic settings on every data-plane resource route to a Log Analytics workspace; alerts are configured for high-severity categories.
- [ ] Entra app client secret stored in Key Vault, referenced via `@Microsoft.KeyVault(...)`, **never** in plaintext app settings.

---

## What's still out of scope

- Azure AI Content Safety / prompt shields (deferred by design).
- Customer-managed keys (CMK) on Storage / Cosmos / Search. The defaults rely on Microsoft-managed keys.
- Conditional Access policies on the Entra app — recommended but tenant-specific.
- Cross-region disaster recovery for the AI Search index.
- VNet-injected Azure Functions for cloud ingestion when `useCloudIngestion=true`. The Functions runtime is configured but its network isolation is not asserted here.
