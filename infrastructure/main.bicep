// Bicep template for deploying the SQL Optimization Azure Function and supporting resources
// Deploy with: az deployment group create -g <rg-name> -f main.bicep -p functionAppName=<name>

@description('Name of the Function App')
param functionAppName string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Log Analytics Workspace ID for Application Insights')
param logAnalyticsWorkspaceId string

@description('Data Collection Endpoint URI')
param dceEndpoint string

@description('Data Collection Rule Immutable ID')
param dcrImmutableId string

@description('Custom log stream name')
param logStreamName string = 'Custom-SQLOptimization_CL'

@description('Resource Graph query to discover Arc machines')
param resourceGraphQuery string = 'resources | where type == \'microsoft.hybridcompute/machines\' | where properties.status == \'Connected\' | project id, name, resourceGroup, subscriptionId, location, tags'

var storageAccountName = toLower('st${take(replace(functionAppName, '-', ''), 20)}')
var appInsightsName = '${functionAppName}-ai'
var hostingPlanName = '${functionAppName}-plan'

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// App Service Plan (Consumption)
resource hostingPlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {}
}

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
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
      powerShellVersion: '7.4'
      appSettings: [
        { name: 'AzureWebJobsStorage'; value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}' }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'; value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}' }
        { name: 'WEBSITE_CONTENTSHARE'; value: toLower(functionAppName) }
        { name: 'FUNCTIONS_EXTENSION_VERSION'; value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME'; value: 'powershell' }
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION'; value: '7.4' }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY'; value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'; value: appInsights.properties.ConnectionString }
        { name: 'DCE_ENDPOINT'; value: dceEndpoint }
        { name: 'DCR_IMMUTABLE_ID'; value: dcrImmutableId }
        { name: 'LOG_STREAM_NAME'; value: logStreamName }
        { name: 'RESOURCE_GRAPH_QUERY'; value: resourceGraphQuery }
      ]
    }
  }
}

// Outputs
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
