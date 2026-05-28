// Bicep template for deploying the SQL Edition Optimisation solution
// Single deployment creates EVERYTHING: workspace, Function App, custom table, DCE, DCR
// Deploy with: az deployment group create -g <rg-name> -f main.bicep -p functionAppName=<name>

@description('Name of the Function App')
param functionAppName string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Name for the Log Analytics Workspace (created by this template)')
param logAnalyticsWorkspaceName string = '${functionAppName}-law'

@description('Log Analytics data retention in days')
param retentionInDays int = 90

@description('Custom log stream name')
param logStreamName string = 'Custom-SQLEditionOptimisation_CL'

@description('Resource Graph query to discover Arc machines')
param resourceGraphQuery string = 'resources | where type == \'microsoft.hybridcompute/machines\' | where properties.status == \'Connected\' | where properties.osType == \'Windows\' | where isnotnull(properties.detectedProperties.mssqldiscovered) or isnotnull(tags[\'sql-server\']) | project id, name, resourceGroup, subscriptionId, location, tags'

var storageAccountName = toLower('st${take(replace(functionAppName, '-', ''), 20)}')
var appInsightsName = '${functionAppName}-ai'
var hostingPlanName = '${functionAppName}-plan'
var dceName = '${functionAppName}-dce'
var dcrName = '${functionAppName}-dcr'
var customTableName = 'SQLEditionOptimisation_CL'

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// App Service Plan (Elastic Premium for Durable Functions at scale)
resource hostingPlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
    family: 'EP'
  }
  properties: {
    maximumElasticWorkerCount: 20
  }
}

// Log Analytics Workspace (created by this template)
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

// Application Insights (backed by the workspace)
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// Custom Table in Log Analytics
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: logAnalyticsWorkspace
  name: customTableName
  properties: {
    schema: {
      name: customTableName
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'MachineName', type: 'string' }
        { name: 'InstanceName', type: 'string' }
        { name: 'Edition', type: 'string' }
        { name: 'ProductVersion', type: 'string' }
        { name: 'ProductLevel', type: 'string' }
        { name: 'VisibleCPUs', type: 'int' }
        { name: 'DatabaseName', type: 'string' }
        { name: 'CompatibilityLevel', type: 'int' }
        { name: 'EnterpriseFeatures', type: 'string' }
        { name: 'FeatureCount', type: 'int' }
        { name: 'HasBlockingFeatures', type: 'boolean' }
        { name: 'DowngradeEligibility', type: 'string' }
        { name: 'ResourceGroup', type: 'string' }
        { name: 'SubscriptionId', type: 'string' }
        { name: 'Location', type: 'string' }
      ]
    }
    retentionInDays: 90
  }
}

// Data Collection Endpoint
resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: dceName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// Data Collection Rule
resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: dcrName
  location: location
  dependsOn: [
    customTable
  ]
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    streamDeclarations: {
      '${logStreamName}': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'MachineName', type: 'string' }
          { name: 'InstanceName', type: 'string' }
          { name: 'Edition', type: 'string' }
          { name: 'ProductVersion', type: 'string' }
          { name: 'ProductLevel', type: 'string' }
          { name: 'VisibleCPUs', type: 'int' }
          { name: 'DatabaseName', type: 'string' }
          { name: 'CompatibilityLevel', type: 'int' }
          { name: 'EnterpriseFeatures', type: 'string' }
          { name: 'FeatureCount', type: 'int' }
          { name: 'HasBlockingFeatures', type: 'boolean' }
          { name: 'DowngradeEligibility', type: 'string' }
          { name: 'ResourceGroup', type: 'string' }
          { name: 'SubscriptionId', type: 'string' }
          { name: 'Location', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspace.id
          name: 'logAnalyticsDestination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          logStreamName
        ]
        destinations: [
          'logAnalyticsDestination'
        ]
        transformKql: 'source'
        outputStream: 'Custom-${customTableName}'
      }
    ]
  }
}

// Function App
resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.6'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storageAccount.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: 'https://${storageAccount.name}.blob.${environment().suffixes.storage}' }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: 'https://${storageAccount.name}.queue.${environment().suffixes.storage}' }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: 'https://${storageAccount.name}.table.${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION', value: '7.6' }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY', value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'DCE_ENDPOINT', value: dataCollectionEndpoint.properties.logsIngestion.endpoint }
        { name: 'DCR_IMMUTABLE_ID', value: dataCollectionRule.properties.immutableId }
        { name: 'LOG_STREAM_NAME', value: logStreamName }
        { name: 'RESOURCE_GRAPH_QUERY', value: resourceGraphQuery }
      ]
    }
  }
}

// RBAC: Storage Blob Data Owner for identity-based AzureWebJobsStorage
resource storageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  scope: storageAccount
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  }
}

// RBAC: Storage Account Contributor (for queue/table operations used by Durable Functions)
resource storageContribRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, '17d1049b-9a84-46fb-8f53-869881c3d3ab')
  scope: storageAccount
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '17d1049b-9a84-46fb-8f53-869881c3d3ab')
  }
}

// RBAC: Storage Queue Data Contributor (Durable Functions uses queues)
resource storageQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  scope: storageAccount
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  }
}

// RBAC: Storage Table Data Contributor (Durable Functions uses tables)
resource storageTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  scope: storageAccount
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
  }
}

// Outputs
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
output dceEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
output dcrImmutableId string = dataCollectionRule.properties.immutableId
output dcrResourceId string = dataCollectionRule.id
output customTableName string = customTable.name
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name
