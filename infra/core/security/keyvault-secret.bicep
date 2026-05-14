metadata description = 'Writes a single secret value into an existing Key Vault. Skipped when value is empty.'

param keyVaultName string
param name string

@secure()
param value string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(value)) {
  parent: vault
  name: name
  properties: {
    value: value
    attributes: {
      enabled: true
    }
  }
}

output secretUri string = !empty(value) ? secret.properties.secretUri : ''
output name string = name
