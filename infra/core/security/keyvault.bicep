metadata description = 'Creates an Azure Key Vault for storing runtime secrets. Uses RBAC only (no access policies). Soft-delete and purge protection are required. Public network access defaults to Disabled.'

param name string
param location string = resourceGroup().location
param tags object = {}

@description('Principal IDs that need to READ secrets (typically the App Service / Container App managed identity).')
param secretReaderPrincipalIds array = []

@description('Principal IDs that need to MANAGE secrets (typically the deploying user during `azd up`).')
param secretOfficerPrincipalIds array = []

@description('Public network access. Disable in production and use private endpoints.')
@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Disabled'

@description('How long deleted secrets remain recoverable. Min 7, max 90.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: true
    publicNetworkAccess: publicNetworkAccess
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: publicNetworkAccess == 'Disabled' ? 'Deny' : 'Allow'
    }
  }
}

// Key Vault Secrets User
var secretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
// Key Vault Secrets Officer
var secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource readerAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in secretReaderPrincipalIds: if (!empty(principalId)) {
  name: guid(vault.id, principalId, secretsUserRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}]

resource officerAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for principalId in secretOfficerPrincipalIds: if (!empty(principalId)) {
  name: guid(vault.id, principalId, secretsOfficerRoleId)
  scope: vault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficerRoleId)
    principalId: principalId
  }
}]

output id string = vault.id
output name string = vault.name
output uri string = vault.properties.vaultUri
