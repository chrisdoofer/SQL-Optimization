// Role assignments for the Function App's Managed Identity
// Deploy AFTER main.bicep so the principalId is available

@description('Principal ID of the Function App Managed Identity')
param functionAppPrincipalId string

@description('Subscription ID(s) where Arc machines reside (for Reader + Run Command)')
param targetSubscriptionIds array = []

@description('Resource ID of the Data Collection Rule')
param dcrResourceId string

// Built-in role definition IDs
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var connectedMachineResourceAdminRoleId = 'cd570a14-e51a-42ad-bac8-bafd67325302'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

// Reader at subscription level (for Resource Graph queries)
resource readerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, functionAppPrincipalId, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Connected Machine Resource Administrator (for Run Commands)
resource arcRunCommandRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, functionAppPrincipalId, connectedMachineResourceAdminRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', connectedMachineResourceAdminRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Monitoring Metrics Publisher on the DCR (for Logs Ingestion API)
resource metricsPublisherRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcrResourceId, functionAppPrincipalId, monitoringMetricsPublisherRoleId)
  scope: tenant()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}
