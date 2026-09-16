// CallType beta topology: Linux App Service B1 (API+SignalR), Static Web Apps Free (Flutter web),
// private Blob Storage (encrypted backups). Reproduces docs/azure-beta-plan.md, does not migrate hosting.
//
// IMPORTANT: this template intentionally does NOT set siteConfig.appSettings. Azure's app settings
// PUT replaces the whole collection — an empty/partial `appSettings` block here would wipe secrets
// (Jwt__Secret, Turn__SharedSecret, connection strings, ...) on the next deployment. App settings are
// out of scope for I01 and are owned by R01's deploy pipeline, which must read-merge-write the existing
// collection instead of overwriting it. See docs/ops/beta-infrastructure.md.
targetScope = 'resourceGroup'

@description('Azure region for all resources. Must match the existing rg-calltype-beta resources when adopting them.')
param location string = resourceGroup().location

@description('App Service plan name.')
param appServicePlanName string = 'asp-calltype-beta'

@description('Web app (API+SignalR) name. Must be globally unique.')
param webAppName string = 'calltype-beta-zahy'

@description('Static Web App (Flutter web) name.')
param staticWebAppName string = 'calltype-beta-web'

@description('Storage account name for private encrypted backups. Must be globally unique, lowercase, 3-24 chars.')
param storageAccountName string = 'calltypebetazahy'

@description('.NET runtime version for the Linux web app, matches CallType.Api target framework.')
param dotnetVersion string = '10.0'

@description('Tags applied to the web app. Preserved explicitly so a re-deploy does not wipe existing tags (ARM PUT replaces the whole tags collection).')
param webAppTags object = {
  project: 'calltype'
  environment: 'beta'
  'managed-by': 'Codex'
}

@description('Tags applied to the static web app.')
param staticWebAppTags object = {
  project: 'CallType'
  'managed-by': 'Codex'
}

// Global constraint: exactly one B1 instance, no autoscale. Do not parameterize capacity above 1.
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'B1'
    tier: 'Basic'
    capacity: 1
  }
  kind: 'linux'
  properties: {
    reserved: true // required for Linux plans
  }
}

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  tags: webAppTags
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|${dotnetVersion}'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      alwaysOn: true
      webSocketsEnabled: true
      // No appSettings here on purpose - see file header comment.
    }
  }
}

resource staticWebApp 'Microsoft.Web/staticSites@2023-12-01' = {
  name: staticWebAppName
  location: location
  tags: staticWebAppTags
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {}
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

output webAppDefaultHostName string = webApp.properties.defaultHostName
output webAppResourceId string = webApp.id
output staticWebAppDefaultHostname string = staticWebApp.properties.defaultHostname
output staticWebAppResourceId string = staticWebApp.id
output storageAccountResourceId string = storageAccount.id
output appServicePlanResourceId string = appServicePlan.id
