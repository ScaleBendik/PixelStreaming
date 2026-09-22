[CmdletBinding()]
param(
    [string]$RuntimeRoot,
    [string]$InstallBase = 'C:\PixelStreaming',
    [string]$Environment = $env:SCALEWORLD_DEPLOYMENT_TRACK,
    [string]$Mode = 'normal',
    [string]$Bucket = 'scaleworlddepot',
    [string]$SnapshotPath = $env:SCALEWORLD_INSTANCE_CONFIG_SNAPSHOT
)
$ErrorActionPreference='Stop'
$OutputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $OutputEncoding
Import-Module (Join-Path $PSScriptRoot 'instance_config.psm1') -Force
if ($Environment -notin @('dev','stage','prod')) { throw 'Explicit deployment environment is required for instance config.' }
if (!$SnapshotPath) { throw 'Snapshot path is required.' }
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $SnapshotPath))
$serviceClass=(& (Join-Path $PSScriptRoot 'resolve_service_class_from_instance_tag.ps1') | Select-Object -Last 1)
if ($serviceClass -notin @('standard','premium')) { throw 'Cannot resolve serving instance class.' }
$metadataPath=Join-Path $RuntimeRoot 'runtime-bundle-metadata.json'
$bundleId=if (Test-Path -LiteralPath $metadataPath) { (Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json).bundleId } else { 'git_ref' }
$buildPath=Join-Path $InstallBase 'state\current-release.json'
$buildState=if (Test-Path -LiteralPath $buildPath) { Get-Content -LiteralPath $buildPath -Raw | ConvertFrom-Json } else { $null }
$buildId=[string](Get-ConfigProperty $buildState 'BuildId' '')
# The candidate uses ScaleWorldCurrentBuild (ZIP filename); local BuildId is usually an S3 ETag.
$buildName=Split-Path -Leaf ([string](Get-ConfigProperty $buildState 'ZipKey' 'unknown.zip'))
$cached=$null
if (Test-Path -LiteralPath $SnapshotPath) {
    $cached=Read-InstanceConfigSnapshot $SnapshotPath
    if ($cached.environment -ne $Environment -or $cached.serviceClass -ne $serviceClass -or
        $cached.bundleId -ne $bundleId -or $cached.buildId -ne $buildId) { $cached=$null }
}
# Component/full-stack recovery and a repeated launch while serving keep the same snapshot.
$components=@(Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -ieq 'node.exe' -and $_.CommandLine -like "*$RuntimeRoot*SignallingWebServer*") -or
    ($_.Name -like 'ScaleWorld*.exe')
})
if ($Mode -eq 'recovery' -or $components.Count -gt 0) {
    if (!$cached) { throw 'Recovery requires a matching startup configuration snapshot.' }
    Write-Output 'Retaining instance config snapshot for recovery/running stack.'
    exit 0
}
function Invoke-ConfigAws {
    param([string[]]$Arguments)
    # Windows PowerShell turns native stderr into error records; inspect the exit code ourselves.
    $ErrorActionPreference='Continue'
    $output=& $aws @Arguments 2>&1
    return [pscustomobject]@{ExitCode=$LASTEXITCODE; Text=($output -join "`n")}
}
function Read-StartupS3Json {
    param([string]$Key, [switch]$Optional)
    $result=Invoke-ConfigAws @('s3','cp',"s3://$Bucket/$Key",'-','--region',$region,'--cli-connect-timeout','5','--cli-read-timeout','10')
    if ($result.ExitCode -ne 0) {
        if ($Optional -and $result.Text -match '(404|NoSuchKey|Not Found)') { return $null }
        throw "Unable to read configuration object $Key."
    }
    $json=$result.Text
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 65536) { throw 'Configuration object exceeds 64 KiB.' }
    return $json
}
try {
    $aws=(Get-Command aws -ErrorAction Stop).Source
    $token=Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds'='21600' } -TimeoutSec 5
    $identity=Invoke-RestMethod -Uri 'http://169.254.169.254/latest/dynamic/instance-identity/document' -Headers @{ 'X-aws-ec2-metadata-token'=$token } -TimeoutSec 5
    $region=$identity.region
    $reference=$null
    $candidateId=$null
    if ($Environment -eq 'dev') {
        $pointer=Read-StartupS3Json -Key 'InstanceConfig/v1/dev/current.json' -Optional
        if ($pointer) { $reference=$pointer | ConvertFrom-Json }
    } else {
        $result=Invoke-ConfigAws @('ssm','get-parameter','--name',"/scaleworld/release/$Environment/current-candidate",'--region',$region,'--query','Parameter.Value','--output','text','--cli-connect-timeout','5','--cli-read-timeout','10')
        $candidate=$null
        if ($result.ExitCode -ne 0) {
            if ($result.Text -notmatch 'ParameterNotFound') { throw 'Unable to resolve release candidate for instance config.' }
            if ($cached -and $cached.reference) { throw 'Previously configured release pointer is missing.' }
        } else { $candidate=$result.Text | ConvertFrom-Json }
        $reference=Get-ConfigProperty $candidate 'instanceConfig'
        $candidateRuntime=Get-ConfigProperty $candidate 'runtimeArtifact'
        if ($reference -or $candidateRuntime) {
            $candidateBuildName=Split-Path -Leaf ([string](Get-ConfigProperty $candidate 'unrealBuildId' 'unknown.zip'))
            if ((Get-ConfigProperty $candidateRuntime 'bundleId') -ne $bundleId -or
                $candidateBuildName -ne $buildName) {
                # The installer validates new binaries before they can be captured as a new candidate.
                # That maintenance run may use the current profile; it does not validate a release candidate.
                if ($Mode -eq 'validation') { Write-Output 'Artifact validation uses the current profile pending candidate capture.' }
                elseif ($cached) { Write-Output 'Retaining config for installed artifacts; newer candidate requires an artifact update.'; exit 0 }
                else { throw 'Installed artifacts do not match the configuration candidate. Update the instance first.' }
            }
        }
        $candidateId=Get-ConfigProperty $candidate 'candidateId'
    }
    $profile=$null
    if ($reference) {
        if ($reference.revisionId -cnotmatch '^[a-f0-9]{32}$' -or $reference.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            $reference.manifestKey -cnotmatch '^InstanceConfig/v1/(dev|stage)/revisions/[a-f0-9]{32}\.json$') { throw 'Invalid configuration reference.' }
        $configEnvironment=if ($Environment -eq 'dev') { 'dev' } else { 'stage' }
        if ($reference.manifestKey -cne "InstanceConfig/v1/$configEnvironment/revisions/$($reference.revisionId).json") { throw 'Configuration reference has an incorrect scope or revision path.' }
        $json=Read-StartupS3Json -Key $reference.manifestKey
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        if ($hash -ne $reference.sha256) { throw 'Configuration checksum mismatch.' }
        $document=$json | ConvertFrom-Json
        if ($document.schemaVersion -ne 1 -or $document.revisionId -ne $reference.revisionId -or $document.environment -ne $configEnvironment) { throw 'Unsupported or mismatched configuration document.' }
        $profile=$document.$serviceClass
        Assert-InstanceConfigLayer $profile
    }
    if ($Environment -eq 'dev' -and !$reference -and $cached -and $cached.reference) { throw 'Previously configured Dev pointer is missing.' }
    Write-InstanceConfigAtomic -Path $SnapshotPath -Value ([ordered]@{
        schemaVersion=1; environment=$Environment; serviceClass=$serviceClass; bundleId=$bundleId; buildId=$buildId;
        candidateId=$candidateId; reference=$reference; profile=$profile; instanceId=$identity.instanceId; region=$region;
        loadedAtUtc=[DateTime]::UtcNow.ToString('o'); source='published'
    })
    Write-Output "Instance config resolved for $Environment/$serviceClass."
} catch {
    # Only a previously validated snapshot for these exact installed artifacts can be reused.
    if ($cached -and $_.Exception.Message -match 'Unable to (read configuration|resolve release candidate)') {
        $cached.source='cached'
        Write-InstanceConfigAtomic -Path $SnapshotPath -Value $cached
        Write-Warning 'Configuration storage unavailable; retaining the matching cached snapshot.'
        exit 0
    }
    [IO.File]::WriteAllText($SnapshotPath+'.error.txt', $_.Exception.Message)
    throw
}
