import asyncio
import json
import os
import subprocess

from azure.identity.aio import AzureDeveloperCliCredential
from msgraph import GraphServiceClient
from msgraph.generated.models.application import Application
from msgraph.generated.models.federated_identity_credential import FederatedIdentityCredential
from msgraph.generated.models.public_client_application import PublicClientApplication
from msgraph.generated.models.spa_application import SpaApplication
from msgraph.generated.models.web_application import WebApplication

from auth_common import get_application, test_authentication_enabled
from load_azd_env import load_azd_env


FEDERATED_CREDENTIAL_NAME = "backend-managed-identity"


def _get_backend_mi_principal_id() -> str:
    """Look up the backend's system-assigned managed identity principal ID.

    Uses the Azure CLI (already a prerequisite of azd) to avoid taking a dependency
    on azure-mgmt-* SDKs from the bootstrap script.
    """
    rg = os.environ.get("AZURE_RESOURCE_GROUP")
    if not rg:
        raise RuntimeError("AZURE_RESOURCE_GROUP is not set; cannot locate backend identity.")
    list_proc = subprocess.run(
        [
            "az",
            "resource",
            "list",
            "-g",
            rg,
            "--tag",
            "azd-service-name=backend",
            "--query",
            "[0].{name:name,type:type}",
            "-o",
            "json",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    payload = list_proc.stdout.strip()
    if not payload or payload == "null":
        raise RuntimeError(f"Could not find a backend resource in resource group {rg}.")
    info = json.loads(payload)
    res_type = info["type"]
    res_name = info["name"]
    if res_type == "Microsoft.Web/sites":
        cmd = ["az", "webapp", "identity", "show", "-g", rg, "-n", res_name, "--query", "principalId", "-o", "tsv"]
    elif res_type == "Microsoft.App/containerApps":
        cmd = [
            "az",
            "containerapp",
            "identity",
            "show",
            "-g",
            rg,
            "-n",
            res_name,
            "--query",
            "principalId",
            "-o",
            "tsv",
        ]
    else:
        raise RuntimeError(f"Unsupported backend resource type for federation: {res_type}")
    show_proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    principal_id = show_proc.stdout.strip()
    if not principal_id:
        raise RuntimeError(f"Backend resource {res_name} has no system-assigned managed identity yet.")
    return principal_id


async def upsert_federated_identity_credential(
    graph_client: GraphServiceClient, server_object_id: str, tenant_id: str, mi_principal_id: str
) -> None:
    """Add or update the federated identity credential that lets the backend MI
    impersonate the server Entra app via Workload Identity Federation."""
    desired = FederatedIdentityCredential(
        name=FEDERATED_CREDENTIAL_NAME,
        issuer=f"https://login.microsoftonline.com/{tenant_id}/v2.0",
        subject=mi_principal_id,
        audiences=["api://AzureADTokenExchange"],
        description="Backend managed identity acting as the server app (Workload Identity Federation).",
    )
    existing = await (
        graph_client.applications.by_application_id(server_object_id).federated_identity_credentials.get()
    )
    existing_creds = (existing.value if existing else None) or []
    for cred in existing_creds:
        if cred.name == FEDERATED_CREDENTIAL_NAME:
            print(f"Updating existing federated identity credential {cred.id}...")
            await graph_client.applications.by_application_id(
                server_object_id
            ).federated_identity_credentials.by_federated_identity_credential_id(cred.id).patch(desired)
            return
    print("Creating new federated identity credential on server app...")
    await graph_client.applications.by_application_id(server_object_id).federated_identity_credentials.post(desired)


async def main():
    load_azd_env()
    if not test_authentication_enabled():
        print("Not updating authentication.")
        exit(0)

    auth_tenant = (os.getenv("AZURE_AUTH_TENANT_ID") or os.getenv("AZURE_TENANT_ID") or "").strip()
    credential = AzureDeveloperCliCredential(tenant_id=auth_tenant)

    scopes = ["https://graph.microsoft.com/.default"]
    graph_client = GraphServiceClient(credentials=credential, scopes=scopes)

    uri = os.getenv("BACKEND_URI")
    client_app_id = os.getenv("AZURE_CLIENT_APP_ID", None)
    if client_app_id:
        client_object_id = await get_application(graph_client, client_app_id)
        if client_object_id:
            print(f"Updating redirect URIs for client app ID {client_app_id}...")
            # Redirect URIs need to be relative to the deployed application
            app = Application(
                public_client=PublicClientApplication(redirect_uris=[]),
                spa=SpaApplication(
                    redirect_uris=[
                        "http://localhost:50505/redirect",
                        "http://localhost:5173/redirect",
                        f"{uri}/redirect",
                    ]
                ),
                web=WebApplication(
                    redirect_uris=[
                        f"{uri}/.auth/login/aad/callback",
                    ]
                ),
            )
            await graph_client.applications.by_application_id(client_object_id).patch(app)
            print(f"Application update for client app id {client_app_id} complete.")

    if os.getenv("AZURE_USE_WORKLOAD_IDENTITY_FEDERATION", "").lower() == "true":
        server_app_id = os.getenv("AZURE_SERVER_APP_ID")
        if not server_app_id:
            print("AZURE_USE_WORKLOAD_IDENTITY_FEDERATION is true but AZURE_SERVER_APP_ID is not set; skipping FIC.")
        else:
            server_object_id = await get_application(graph_client, server_app_id)
            if not server_object_id:
                print(f"Server app {server_app_id} not found in tenant; skipping FIC.")
            else:
                principal_id = _get_backend_mi_principal_id()
                print(f"Wiring federated identity credential: backend MI {principal_id} -> server app {server_app_id}")
                await upsert_federated_identity_credential(graph_client, server_object_id, auth_tenant, principal_id)
                print("Federated identity credential is in place.")


if __name__ == "__main__":
    asyncio.run(main())
