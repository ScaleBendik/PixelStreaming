Set-StrictMode -Version Latest

function Get-ConfigProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Get-InstanceConfigFields {
    $fields = @{ resX=@(320,7680); resY=@(240,4320); fps=@(1,120); maxBitrateKbps=@(100,200000); forceResolution=@(0,1) }
    foreach ($name in @('ViewDistance','AntiAliasing','Shadow','GlobalIllumination','Reflection','PostProcess','Texture','Effects','Foliage','Shading')) {
        $fields["sg.${name}Quality"]=@(0,4)
    }
    return $fields
}

function Assert-InstanceConfigLayer {
    param($Layer)
    if (!$Layer -or !(Get-ConfigProperty $Layer 'values')) { throw 'Instance config values are missing.' }
    $fields=Get-InstanceConfigFields
    foreach ($property in $Layer.values.PSObject.Properties) {
        if (!$fields.ContainsKey($property.Name) -or $property.Value -isnot [ValueType] -or
            [double]$property.Value -ne [int]$property.Value -or
            $property.Value -lt $fields[$property.Name][0] -or $property.Value -gt $fields[$property.Name][1]) {
            throw "Invalid instance config parameter: $($property.Name)."
        }
    }
    foreach ($required in @('resX','resY','fps','maxBitrateKbps','forceResolution')) {
        if ($null -eq $Layer.values.PSObject.Properties[$required]) { throw "Missing resolved parameter $required." }
    }
    $arguments=@(Get-ConfigProperty $Layer 'arguments' @())
    if ($arguments.Count -gt 32) { throw 'Too many custom arguments.' }
    $seen=@{}
    foreach ($arg in $arguments) {
        if (!$arg -or $arg.name -cnotmatch '^[A-Za-z][A-Za-z0-9_.]{0,79}$' -or $seen.ContainsKey($arg.name)) {
            throw 'Invalid or duplicate argument name.'
        }
        $seen[$arg.name]=$true
        if ($arg.name -match '^(pixelstreaming|scaleworld|sg\.|ini|exec|log|abslog|userdir|savedir|config|auth|token|password)' -or
            $arg.name -match '^(resx|resy|forceres|renderoffscreen|allowpixelstreamingcommands|auto|unattended|avcodecs\.nvenc\.d3d12usescuda)$') {
            throw "Protected argument $($arg.name)."
        }
        $value=Get-ConfigProperty $arg 'value'
        if ($null -ne $value -and ($value -isnot [string] -or $value.Length -gt 512 -or $value -match '[\p{Cc}"]')) {
            throw 'Invalid argument value.'
        }
    }
}

# Windows argv serialization: JSON data never travels through CMD interpolation.
function ConvertTo-InstanceConfigWindowsArgument {
    param([string]$Value)
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Get-InstanceConfigArguments {
    param($Layer)
    Assert-InstanceConfigLayer $Layer
    $result=New-Object 'System.Collections.Generic.List[string]'
    $commands=@($Layer.values.PSObject.Properties | Where-Object { $_.Name -like 'sg.*' } | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Value)" })
    # LaunchWindows restores value quotes when argv contains a space. Supplying literal
    # quotes too would produce double quotes and an empty FParse value.
    if ($commands.Count) { $result.Add((ConvertTo-InstanceConfigWindowsArgument ('-ExecCmds=' + ($commands -join ',')))) }
    if ($Layer.values.forceResolution -eq 1) { $result.Add('-ForceRes') }
    foreach ($arg in @(Get-ConfigProperty $Layer 'arguments' @())) {
        if (!(Get-ConfigProperty $arg 'enabled' $true)) { continue }
        $token='-'+$arg.name
        if ($null -ne (Get-ConfigProperty $arg 'value')) {
            $token+='='
            if ($arg.value.Contains(' ')) { $token+=$arg.value }
            else { $token+='"'+$arg.value+'"' }
        }
        $result.Add((ConvertTo-InstanceConfigWindowsArgument $token))
    }
    return $result.ToArray()
}

function Write-InstanceConfigAtomic {
    param([string]$Path, $Value)
    $directory=Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30 -Compress), (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Read-InstanceConfigSnapshot {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path)) { throw 'Instance config snapshot is missing.' }
    $snapshot=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($snapshot.schemaVersion -ne 1) { throw 'Unsupported instance config snapshot.' }
    if ($null -ne (Get-ConfigProperty $snapshot 'profile')) { Assert-InstanceConfigLayer $snapshot.profile }
    return $snapshot
}
Export-ModuleMember -Function *-InstanceConfig*, Get-ConfigProperty
