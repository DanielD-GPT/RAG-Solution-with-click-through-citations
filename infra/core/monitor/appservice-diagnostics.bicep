metadata description = 'Routes App Service logs to Log Analytics. Captures HTTP logs, auth audit events, and app-level errors.'

param appServiceName string

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

resource appService 'Microsoft.Web/sites@2022-03-01' existing = {
  name: appServiceName
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${appServiceName}-diag'
  scope: appService
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
