metadata description = 'Routes Storage account logs (blob, file, queue, table) and metrics to Log Analytics. Storage diagnostics target each *Service* sub-resource, so the StorageRead/StorageWrite/StorageDelete log categories are emitted via the blobServices/fileServices/etc. extension scopes.'

param storageAccountName string

@description('Resource ID of the Log Analytics workspace.')
param workspaceId string

@description('Log category groups to capture per service. allLogs includes StorageRead/Write/Delete + transaction logs.')
param logCategoryGroups array = [
  {
    categoryGroup: 'allLogs'
    enabled: true
  }
]

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' existing = {
  parent: storage
  name: 'default'
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' existing = {
  parent: storage
  name: 'default'
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-01-01' existing = {
  parent: storage
  name: 'default'
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-01-01' existing = {
  parent: storage
  name: 'default'
}

resource accountDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-diag'
  scope: storage
  properties: {
    workspaceId: workspaceId
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource blobDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-blob-diag'
  scope: blobService
  properties: {
    workspaceId: workspaceId
    logs: logCategoryGroups
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource fileDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-file-diag'
  scope: fileService
  properties: {
    workspaceId: workspaceId
    logs: logCategoryGroups
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource queueDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-queue-diag'
  scope: queueService
  properties: {
    workspaceId: workspaceId
    logs: logCategoryGroups
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource tableDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${storageAccountName}-table-diag'
  scope: tableService
  properties: {
    workspaceId: workspaceId
    logs: logCategoryGroups
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}
