// CallType beta topology: Linux App Service B1 (API+SignalR), Static Web Apps Free (Flutter web),
// private Blob Storage (encrypted backups). Reproduces docs/azure-beta-plan.md, does not migrate hosting.
//
// IMPORTANT: this template intentionally does NOT set siteConfig.appSettings. Azure's app settings
// PUT replaces the whole collection — an empty/partial `appSettings` block here would wipe secrets
// (Jwt__Secret, Turn__SharedSecret, connection strings, ...) on the next deployment. App settings are
// out of scope for I01 and are owned by R01's deploy pipeline, which must read-merge-write the existing
// collection instead of overwriting it. See docs/ops/beta-infrastructure.md.
//
// O7 (2026-09-29) adds, without changing that rule:
// - NON-SECRET defaults for Attachments__*, Calls__* and Push__Apns__BundleId through
//   modules/appsettings-merge.bicep, which reads the live collection and only ADDS missing keys
//   (existing values always win). Secrets are never in this template.
// - Blob: every container the API uses, the private `db-backups` container for off-site database
//   backups (infra/postgres/backup.sh), a lifecycle policy (e2e-attachments 35 d, db-backups
//   dbBackupRetentionDays), blob + container soft delete and a CanNotDelete lock on the account
//   (O3 / N05 Blob part — docs/ops/postgres-restore.md §7).
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

@description('Days a deleted blob / container stays recoverable (soft delete). 0 = off. Also delays the final erasure of deleted attachments and backups by the same number of days - see docs/ops/postgres-restore.md §7 before raising it.')
@minValue(0)
@maxValue(365)
param blobSoftDeleteDays int = 7

@description('Lifecycle safety net for e2e-attachments: delete blobs not modified for this many days. Must stay ABOVE Attachments__RetentionDays (30), because the application deletes committed blobs itself; this rule only catches what the app missed.')
@minValue(31)
param e2eAttachmentsLifecycleDays int = 35

@description('Off-site database backups in db-backups older than this are deleted (backup.sh writes one set per day).')
@minValue(8)
param dbBackupRetentionDays int = 35

@description('Put a CanNotDelete lock on the storage account (control plane only; blob reads/writes/deletes are unaffected). Needs Owner / User Access Administrator to deploy.')
param lockStorageAccount bool = true

@description('Add missing NON-SECRET app settings (Attachments__*, Calls__*, Push__Apns__BundleId). Existing values are never changed.')
param applyNonSecretAppSettings bool = true

@description('''Non-secret app settings added when missing. Mirrors the code defaults
(src/server/CallType.Api/Configuration/AttachmentsOptions.cs, appsettings.json "Calls") so the owner
sees and can tune the capacity/cost knobs in the portal. NEVER put a secret here - the APNs trio
Push__Apns__TeamId/KeyId/PrivateKeyP8 is set by the owner all at once, because
ProductionConfigurationValidator refuses to start with only some of them.''')
param appSettingDefaults object = {
  Attachments__RetentionDays: '30'
  Attachments__UploadWindowHours: '24'
  Attachments__MaxCiphertextBytes: '104923136'
  Attachments__MaxBytesPerDevicePerDay: '1073741824'
  Attachments__MaxTotalBytesPerDay: '53687091200'
  Calls__PendingTtlSeconds: '45'
  Calls__MaxCallPushesPerCallerPerMinute: '6'
  Push__Apns__BundleId: 'cz.zcloud.jay'
}

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

// --- Blob: containers, soft delete, lifecycle, lock (O3 Blob part + O7) --------------------------

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    // Soft delete is the restore path for an accidental or buggy DELETE (a cleanup service that
    // picks the wrong blobs, an operator mistake). It is NOT a backup against losing the account;
    // the CanNotDelete lock below and the off-site DB dumps cover that side.
    deleteRetentionPolicy: {
      enabled: blobSoftDeleteDays > 0
      days: max(blobSoftDeleteDays, 1) // ignored while disabled
    }
    containerDeleteRetentionPolicy: {
      enabled: blobSoftDeleteDays > 0
      days: max(blobSoftDeleteDays, 1) // ignored while disabled
    }
  }
}

// Every container the API uses, so a fresh install passes /health/ready (it checks `backups`)
// without waiting for the first upload's CreateIfNotExists. Private: all access goes through the
// API (or, for db-backups, a create-only SAS held by the database server).
var containerNames = [
  'backups' // user backups, BackupEndpoints / BackupCleanupService
  'channel-media' // public channel images, served through the API only
  'e2e-attachments' // E2E-encrypted media (stream M2), app-side TTL Attachments__RetentionDays
  'db-backups' // off-site copies of infra/postgres/backup.sh (encrypted with age)
]

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = [
  for name in containerNames: {
    parent: blobService
    name: name
    properties: {
      publicAccess: 'None'
    }
  }
]

// One policy per account ('default' is the only allowed name): this resource OWNS all lifecycle
// rules of the account. Add new rules here, never in the portal, or the next deploy removes them.
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          // Safety net next to E2eAttachmentCleanupService, not a replacement: the app deletes
          // committed blobs after Attachments__RetentionDays (30) and abandoned uploads after 24 h.
          // Five days of margin so this rule never races the app's own, row-consistent deletion.
          name: 'e2e-attachments-safety-net'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['e2e-attachments/']
            }
            actions: {
              baseBlob: {
                delete: { daysAfterModificationGreaterThan: e2eAttachmentsLifecycleDays }
              }
            }
          }
        }
        {
          // backup.sh cannot delete (create-only SAS), so retention of the off-site copies lives here.
          name: 'db-backups-retention'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['db-backups/']
            }
            actions: {
              baseBlob: {
                delete: { daysAfterCreationGreaterThan: dbBackupRetentionDays }
              }
            }
          }
        }
      ]
    }
  }
  dependsOn: [containers]
}

// Deleting the account would take every user backup, channel image and off-site DB dump with it,
// and soft delete does not survive account deletion. A lock turns that into a two-step, deliberate act.
resource storageLock 'Microsoft.Authorization/locks@2020-05-01' = if (lockStorageAccount) {
  name: '${storageAccountName}-cannot-delete'
  scope: storageAccount
  properties: {
    level: 'CanNotDelete'
    notes: 'CallType beta: user backups, channel media, E2E attachments and off-site DB backups. Remove only with the owner\'s written OK (docs/ops/postgres-restore.md).'
  }
}

// --- Non-secret app settings (O7), merged: existing values always win ---------------------------

module nonSecretSettings 'modules/appsettings-merge.bicep' = if (applyNonSecretAppSettings) {
  name: 'calltype-nonsecret-appsettings'
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
output appServicePlanResourceId string = appServicePlan.id
output storageContainers array = containerNames
