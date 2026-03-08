param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [string]$ResourceGroupName = "rg-mcs-portal",
    [string]$Location = "eastus2",
    [string]$SubscriptionId,
    [string]$IndexDocument = "index.html",
    [string]$ErrorDocument = "index.html",
    [switch]$SkipCreate,
    [switch]$OpenSite
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceIndex = Join-Path $repoRoot 'index.html'
$sourceData = Join-Path $repoRoot 'data'
$stagingRoot = Join-Path $repoRoot '.azure-static-staging'

function Assert-CommandAvailable {
    param([string]$CommandName)

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$CommandName' is not installed or not on PATH."
    }
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Out-String).Trim())
    }

    return $output
}

function Invoke-AzureCliJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $json = Invoke-AzureCli -Arguments ($Arguments + @('--output', 'json'))
    $text = ($json | Out-String).Trim()
    if (-not $text) {
        return $null
    }

    return $text | ConvertFrom-Json
}

function New-StagingContent {
    if (Test-Path $stagingRoot) {
        Remove-Item $stagingRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $stagingRoot | Out-Null
    Copy-Item $sourceIndex (Join-Path $stagingRoot 'index.html')
    Copy-Item $sourceData (Join-Path $stagingRoot 'data') -Recurse
}

Assert-CommandAvailable -CommandName 'az'

if (-not (Test-Path $sourceIndex)) {
    throw "Site entry file not found: $sourceIndex"
}

if (-not (Test-Path $sourceData)) {
    throw "Data folder not found: $sourceData"
}

$null = Invoke-AzureCliJson -Arguments @('account', 'show')

if ($SubscriptionId) {
    Invoke-AzureCli -Arguments @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}

$subscription = Invoke-AzureCliJson -Arguments @('account', 'show')
if (-not $subscription) {
    throw 'Unable to resolve the active Azure subscription. Run az login first.'
}

if ($StorageAccountName -notmatch '^[a-z0-9]{3,24}$') {
    throw 'Storage account name must be 3-24 characters and contain only lowercase letters and numbers.'
}

New-StagingContent

if (-not $SkipCreate) {
    $groupExists = Invoke-AzureCli -Arguments @('group', 'exists', '--name', $ResourceGroupName)
    if ((($groupExists | Out-String).Trim()) -ne 'true') {
        Write-Host "Creating resource group $ResourceGroupName in $Location..."
        Invoke-AzureCli -Arguments @('group', 'create', '--name', $ResourceGroupName, '--location', $Location) | Out-Null
    }

    $account = Invoke-AzureCliJson -Arguments @('storage', 'account', 'show', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName)
    if (-not $account) {
        Write-Host "Creating storage account $StorageAccountName..."
        Invoke-AzureCli -Arguments @(
            'storage', 'account', 'create',
            '--name', $StorageAccountName,
            '--resource-group', $ResourceGroupName,
            '--location', $Location,
            '--sku', 'Standard_LRS',
            '--kind', 'StorageV2',
            '--allow-blob-public-access', 'true',
            '--min-tls-version', 'TLS1_2'
        ) | Out-Null
    }
}

Write-Host 'Enabling static website hosting...'
Invoke-AzureCli -Arguments @(
    'storage', 'blob', 'service-properties', 'update',
    '--account-name', $StorageAccountName,
    '--static-website',
    '--index-document', $IndexDocument,
    '--404-document', $ErrorDocument,
    '--auth-mode', 'login'
) | Out-Null

Write-Host 'Uploading site files to $web...'
Invoke-AzureCli -Arguments @(
    'storage', 'blob', 'upload-batch',
    '--account-name', $StorageAccountName,
    '--auth-mode', 'login',
    '--destination', '$web',
    '--source', $stagingRoot,
    '--overwrite', 'true'
) | Out-Null

$staticWebsite = Invoke-AzureCliJson -Arguments @(
    'storage', 'blob', 'service-properties', 'show',
    '--account-name', $StorageAccountName,
    '--auth-mode', 'login'
)

$siteUrl = $null
if ($staticWebsite -and $staticWebsite.staticWebsite -and $staticWebsite.staticWebsite.enabled) {
    $siteUrl = $staticWebsite.staticWebsite.primaryEndpoints.web
}

Write-Host ''
Write-Host 'Azure Blob Static Website deployment complete.'
Write-Host "Subscription : $($subscription.name) [$($subscription.id)]"
Write-Host "Resource Group: $ResourceGroupName"
Write-Host "Storage Account: $StorageAccountName"
if ($siteUrl) {
    Write-Host "Website URL : $siteUrl"
}

if ($OpenSite -and $siteUrl) {
    Start-Process $siteUrl | Out-Null
}