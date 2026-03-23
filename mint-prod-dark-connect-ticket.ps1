[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceId = 'i-05ba31c4ae3f98ae2',

    [Parameter(Mandatory = $true)]
    [string]$UserEmail = 'bendik.slyngstad@scaleaq.com',

    [string]$RouteKey = '',
    [string]$GroupId = 'admin',
    [string]$Region = 'eu-north-1',
    [string]$Issuer = 'scaleworld-prod-connect-ticket',
    [string]$Audience = 'scaleworld-pixelstreaming',
    [string]$SigningKeyParameterName = '/pixelstreaming/prod/connect-ticket/signing-key',
    [string]$RouteHostSuffix = 'stream.scaleworld.net',
    [int]$TtlSeconds = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AwsCliPath {
    $candidate = Get-Command aws -ErrorAction SilentlyContinue
    if ($candidate) {
        return $candidate.Source
    }

    foreach ($path in @(
        'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
        'C:\Program Files\Amazon\AWSCLI\bin\aws.exe'
    )) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    throw "AWS CLI ('aws') was not found."
}

function Resolve-Region {
    param([string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value.Trim()
    }

    foreach ($candidate in @(
        $env:SCALEWORLD_AWS_REGION,
        $env:AWS_REGION,
        $env:AWS_DEFAULT_REGION
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate.Trim()
        }
    }

    try {
        $token = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' -Headers @{
            'X-aws-ec2-metadata-token-ttl-seconds' = '21600'
        }
        $identityDocument = Invoke-RestMethod -Method Get -Uri 'http://169.254.169.254/latest/dynamic/instance-identity/document' -Headers @{
            'X-aws-ec2-metadata-token' = $token
        }
        if ($identityDocument -and -not [string]::IsNullOrWhiteSpace($identityDocument.region)) {
            return $identityDocument.region.Trim()
        }
    } catch {
    }

    throw 'Failed to resolve AWS region. Pass -Region explicitly.'
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)

    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Normalize-RouteKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'Route key must not be empty.'
    }

    $normalizedInput = $Value.Trim().ToLowerInvariant()
    $builder = [System.Text.StringBuilder]::new($normalizedInput.Length)
    $previousWasDash = $false

    foreach ($c in $normalizedInput.ToCharArray()) {
        $isLetter = $c -ge 'a' -and $c -le 'z'
        $isDigit = $c -ge '0' -and $c -le '9'

        if ($isLetter -or $isDigit) {
            [void]$builder.Append($c)
            $previousWasDash = $false
            continue
        }

        if (-not $previousWasDash) {
            [void]$builder.Append('-')
            $previousWasDash = $true
        }
    }

    $normalized = $builder.ToString().Trim('-')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "Route key '$Value' is invalid after normalization."
    }

    if ($normalized.Length -gt 63) {
        throw "Route key '$normalized' exceeds the DNS label length limit (63)."
    }

    return $normalized
}

function Get-RouteKeyFromInstanceTag {
    param(
        [string]$AwsCli,
        [string]$ResolvedRegion,
        [string]$ResolvedInstanceId
    )

    $tagValue = & $AwsCli ec2 describe-tags `
        --region $ResolvedRegion `
        --filters "Name=resource-id,Values=$ResolvedInstanceId" "Name=key,Values=RouteKey" `
        --query 'Tags[0].Value' `
        --output text

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query RouteKey tag for instance '$ResolvedInstanceId'."
    }

    if ([string]::IsNullOrWhiteSpace($tagValue) -or $tagValue -eq 'None') {
        return $null
    }

    return $tagValue.Trim()
}

if ($TtlSeconds -lt 30 -or $TtlSeconds -gt 600) {
    throw 'TtlSeconds must be between 30 and 600.'
}

$awsCli = Get-AwsCliPath
$resolvedRegion = Resolve-Region -Value $Region
$instanceId = $InstanceId.Trim()

if ([string]::IsNullOrWhiteSpace($RouteKey)) {
    $taggedRouteKey = Get-RouteKeyFromInstanceTag -AwsCli $awsCli -ResolvedRegion $resolvedRegion -ResolvedInstanceId $instanceId
    $routeKeySource = if ([string]::IsNullOrWhiteSpace($taggedRouteKey)) { 'instance-id fallback' } else { 'RouteKey tag' }
    $routeKeyCandidate = if ([string]::IsNullOrWhiteSpace($taggedRouteKey)) { $instanceId } else { $taggedRouteKey }
} else {
    $routeKeySource = 'explicit parameter'
    $routeKeyCandidate = $RouteKey.Trim()
}

$normalizedRouteKey = Normalize-RouteKey -Value $routeKeyCandidate

$signingKey = & $awsCli ssm get-parameter `
    --region $resolvedRegion `
    --name $SigningKeyParameterName `
    --with-decryption `
    --query 'Parameter.Value' `
    --output text

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($signingKey) -or $signingKey -eq 'None') {
    throw "Failed to load signing key from '$SigningKeyParameterName'."
}

$now = [DateTimeOffset]::UtcNow
$notBefore = $now.AddSeconds(-5).ToUnixTimeSeconds()
$expires = $now.AddSeconds($TtlSeconds).ToUnixTimeSeconds()

$header = @{
    alg = 'HS256'
    typ = 'JWT'
}

$payload = @{
    sub        = $UserEmail.Trim()
    instanceId = $instanceId
    routeKey   = $normalizedRouteKey
    region     = $resolvedRegion
    groupId    = $GroupId.Trim()
    jti        = [Guid]::NewGuid().ToString('N')
    iss        = $Issuer.Trim()
    aud        = $Audience.Trim()
    nbf        = $notBefore
    exp        = $expires
}

$headerPart = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes(($header | ConvertTo-Json -Compress)))
$payloadPart = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)))
$unsignedToken = "$headerPart.$payloadPart"

$hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($signingKey.Trim()))
try {
    $signatureBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($unsignedToken))
} finally {
    $hmac.Dispose()
}

$signaturePart = ConvertTo-Base64Url $signatureBytes
$token = "$unsignedToken.$signaturePart"
$url = "https://$normalizedRouteKey.$($RouteHostSuffix.Trim().Trim('.'))/player.html?ct=$([Uri]::EscapeDataString($token))"

Write-Host ''
Write-Host "InstanceId: $instanceId"
Write-Host "Region: $resolvedRegion"
Write-Host "RouteKey: $normalizedRouteKey ($routeKeySource)"
Write-Host "Issuer: $($Issuer.Trim())"
Write-Host "Audience: $($Audience.Trim())"
Write-Host "ExpiresAtUtc: $($now.AddSeconds($TtlSeconds).ToString('u'))"
Write-Host ''
Write-Host 'Open this URL:'
Write-Host $url
Write-Host ''
Write-Host 'Raw token:'
Write-Host $token
