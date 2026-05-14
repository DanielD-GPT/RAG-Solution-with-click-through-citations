"""Workload Identity Federation tests for AuthenticationHelper.

These tests exercise the federated-credential branch added in the WIF hardening
pass: when `use_federated_credential=True` and an `azure_credential` is provided,
the helper must (a) not require a server app secret, (b) configure the MSAL
confidential client with a callable `client_assertion`, and (c) mint a fresh JWT
from the supplied credential each time MSAL calls back.
"""

from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from azure.search.documents.indexes.models import SearchField, SearchIndex

from core.authentication import AuthenticationHelper

_INDEX = SearchIndex(
    name="test",
    fields=[
        SearchField(name="oids", type="Collection(Edm.String)"),
        SearchField(name="groups", type="Collection(Edm.String)"),
    ],
)


def _make_credential(token_value: str = "fake-mi-token"):
    credential = MagicMock()
    credential.get_token.return_value = SimpleNamespace(token=token_value, expires_on=0)
    return credential


def test_federated_credential_requires_credential():
    with pytest.raises(ValueError, match="azure_credential"):
        AuthenticationHelper(
            search_index=_INDEX,
            use_authentication=True,
            server_app_id="SERVER_APP",
            server_app_secret=None,
            client_app_id="CLIENT_APP",
            tenant_id="TENANT_ID",
            use_federated_credential=True,
            azure_credential=None,
        )


def test_federated_credential_does_not_require_secret():
    credential = _make_credential()
    helper = AuthenticationHelper(
        search_index=_INDEX,
        use_authentication=True,
        server_app_id="SERVER_APP",
        server_app_secret=None,
        client_app_id="CLIENT_APP",
        tenant_id="TENANT_ID",
        use_federated_credential=True,
        azure_credential=credential,
    )
    assert helper.confidential_client is not None
    # MSAL should have been configured with the assertion callable; the credential
    # itself should not have been queried yet (lazy).
    credential.get_token.assert_not_called()


def test_federated_credential_mints_assertion_per_call():
    credential = _make_credential("first-token")
    helper = AuthenticationHelper(
        search_index=_INDEX,
        use_authentication=True,
        server_app_id="SERVER_APP",
        server_app_secret=None,
        client_app_id="CLIENT_APP",
        tenant_id="TENANT_ID",
        use_federated_credential=True,
        azure_credential=credential,
    )
    assert helper._mint_federated_client_assertion() == "first-token"
    credential.get_token.assert_called_with(AuthenticationHelper.federated_credential_audience)

    # Simulating MSAL refreshing should pick up the new token.
    credential.get_token.return_value = SimpleNamespace(token="second-token", expires_on=0)
    assert helper._mint_federated_client_assertion() == "second-token"
    assert credential.get_token.call_count == 2


def test_secret_path_unchanged_when_federation_disabled():
    helper = AuthenticationHelper(
        search_index=_INDEX,
        use_authentication=True,
        server_app_id="SERVER_APP",
        server_app_secret="SECRET",
        client_app_id="CLIENT_APP",
        tenant_id="TENANT_ID",
    )
    assert helper.use_federated_credential is False
    assert helper.server_app_secret == "SECRET"
    assert helper.confidential_client is not None
