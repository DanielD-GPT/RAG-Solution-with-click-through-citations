metadata description = 'Routes Container App logs and system events to Log Analytics. ContainerAppConsoleLogs go to the managed environment by default; this captures the system events and platform logs at the app scope.'

param containerAppName string

@description('Resource ID of the Log Analytics workspace.')
param workspaceId string

@description('Log category groups to capture.')
param logCategoryGroups array = [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
]

resource containerApp 'Microsoft.App/containerApps@2024-03-01' existing = {
  name: containerAppName
}

resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${containerAppName}-diag'
  scope: containerApp
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
