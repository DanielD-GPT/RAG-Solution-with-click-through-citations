metadata description = 'Routes Cognitive Services / OpenAI account logs to Log Analytics. Captures Audit + RequestResponse so token usage and prompt content can be reviewed for abuse.'

param accountName string

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

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: accountName
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${accountName}-diag'
  scope: account
  properties: {
    workspaceId: workspaceId
    logs: logCategoryGroups
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}
