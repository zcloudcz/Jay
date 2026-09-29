// CallType STAGING topology (N10 / O6, docs/superpowers/plans/2026-09-29-gap-ops.md):
// Linux App Service F1 (Free) for the API + Static Web Apps Free for the Flutter web build + its own
// private Storage account. Purpose: deploy.yml deploys every SHA here first, runs the smoke test,
// and production (beta-appservice.bicep) gets the SAME artifact only after that passed and a human
// approved it. Contract for the workflow: docs/ops/staging.md.
//
// Deploy into a SEPARATE resource group (recommended: rg-calltype-staging, same region as beta):
// - cost of staging is visible on its own in Cost Management,
// - `az group delete` of staging can never touch beta,
// - the OIDC principal for staging gets rights on staging only.
//
// Why F1 and not a deployment slot on B1: slots need Standard or higher (owner decision 2026-09-18:
// staging at 0 USD compute). Known F1 limits the smoke test must respect (Microsoft Learn,
// "Azure App Service limits", checked 2026-09-29):
// - max 5 concurrent WebSocket connections on Linux Free (6th gets HTTP 429) - smoke uses <= 2,
// - 60 CPU minutes per day, 1 GB memory, 165 MB outbound bandwidth per day; over quota the app is
//   stopped with HTTP 403 until the quota resets (midnight UTC) - smoke must stay small,
// - no Always On (cold start: smoke waits for warm-up), no custom domain, no SLA.
//
// Like beta-appservice.bicep, this template never sets siteConfig.appSettings: the app settings of
// staging (its own Jwt__Secret, its own connection strings to calltype_staging /
// calltype_audit_staging, its own Blob connection string) are secrets and are set by the owner.
// Only NON-SECRET defaults go through modules/appsettings-merge.bicep, which never overwrites.
targetScope = 'resourceGroup'

@description('Azure region; use the same region as beta so latency to the external PostgreSQL server is comparable.')
param location string = resourceGroup().location

@description('App Service plan name (F1 Linux).')
param appServicePlanName string = 'asp-calltype-staging'

@description('Staging web app (API+SignalR) name. Globally unique.')
param webAppName string = 'calltype-staging-zahy'

@description('Staging Static Web App (Flutter web) name.')
param staticWebAppName string = 'calltype-staging-web'

@description('Staging storage account. Globally unique, lowercase, 3-24 chars. Separate from beta so staging can never read or delete production blobs.')
param storageAccountName string = 'calltypestagingzahy'

@description('.NET runtime version, matches CallType.Api target framework.')
param dotnetVersion string = '10.0'

@description('Lifecycle: delete staging blobs older than this many days in every container. Staging holds only smoke-test data.')
@minValue(1)
param stagingBlobRetentionDays int = 7

@description('Add missing NON-SECRET app settings (existing values are never changed).')
param applyNonSecretAppSettings bool = true

@description('''Non-secret staging defaults. ASPNETCORE_ENVIRONMENT=Production on purpose: staging must
run the same ProductionConfigurationValidator as beta, otherwise a missing secret would only be found
in production. Business mode stays OFF on staging until the owner sets ConnectionStrings__Audit.''')
param appSettingDefaults object = {
  ASPNETCORE_ENVIRONMENT: 'Production'
  Database__ApplyMigrationsOnStartup: 'true'
  Attachments__RetentionDays: '1'
  Attachments__MaxTotalBytesPerDay: '104857600'
  Push__Apns__BundleId: 'cz.zcloud.jay'
}

param tags object = {
  project: 'calltype'
  environment: 'staging'
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'F1'
    tier: 'Free'
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
  tags: tags
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|${dotnetVersion}'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      alwaysOn: false // not available on Free; the smoke test waits for warm-up instead
      webSocketsEnabled: true // always on for Linux anyway, kept explicit to match beta
      use32BitWorkerProcess: false
      healthCheckPath: '/health'
      // No appSettings here on purpose - see header.
    }
  }
}

resource staticWebApp 'Microsoft.Web/staticSites@2023-12-01' = {
  name: staticWebAppName
  location: location
  tags: tags
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {}
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
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

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    // Staging data is disposable smoke-test data: no soft delete, nothing to recover.
    deleteRetentionPolicy: { enabled: false }
    containerDeleteRetentionPolicy: { enabled: false }
  }
}

// Same container names as beta, so the same build runs unchanged (the names are constants in code).
var containerNames = ['backups', 'channel-media', 'e2e-attachments']

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = [
  for name in containerNames: {
    parent: blobService
    name: name
    properties: { publicAccess: 'None' }
  }
]

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'staging-short-retention'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'] }
            actions: {
              baseBlob: { delete: { daysAfterModificationGreaterThan: stagingBlobRetentionDays } }
            }
          }
        }
      ]
    }
  }
  dependsOn: [containers]
}

module nonSecretSettings 'modules/appsettings-merge.bicep' = if (applyNonSecretAppSettings) {
  name: 'calltype-staging-nonsecret-appsettings'
  params: {
    webAppName: webApp.name
    currentAppSettings: list('${webApp.id}/config/appsettings', '2023-12-01').properties
    defaultAppSettings: appSettingDefaults
  }
}

output webAppDefaultHostName string = webApp.properties.defaultHostName
output webAppResourceId string = webApp.id
output staticWebAppDefaultHostname string = staticWebApp.properties.defaultHostname
output staticWebAppResourceId string = staticWebApp.id
output storageAccountResourceId string = storageAccount.id
// Needed for the PostgreSQL firewall / pg_hba.conf: F1 runs on shared workers with their own set.
output webAppPossibleOutboundIpAddresses string = webApp.properties.possibleOutboundIpAddresses
