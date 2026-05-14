metadata description = 'Routes Azure Cosmos DB logs to Log Analytics. Captures DataPlaneRequests (high-value for audit) and ControlPlaneRequests.'

param cosmosAccountName string

@description('Resource ID of the Log Analytics workspace.')
param workspaceId string

@description('Log category groups to capture.')
param logCategoryGroups array = [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
  {
    categoryGroup: 'audit'
    enabled: true
  }
]

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosAccountName
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${cosmosAccountName}-diag'
  scope: cosmosAccount
  properties: {
    workspaceId: workspaceId
    logs: logCategoryGroups
    metrics: [
      {
        category: 'Requests'
        enabled: true
      }
    ]
  }
}
