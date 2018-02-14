# import shared code
. $PSScriptRoot\Common.ps1

function Annotated-Invoke
{
   param
   (
     [string] $desc,
     [scriptblock] $script,
     [string] $errorMessage
   )

    try
    {
        Write-Host -NoNewline "$desc... "
        $ret = $script.Invoke()
        Write-Success 'OK'
        return $ret
    } catch
    {
        Write-Host 'FAILED' -ForegroundColor Red
        if ($errorMessage) { Write-Host "$errorMessage`n" -ForegroundColor Red }
        throw $_.Exception.InnerException
    }
}

function New-ChangeScriptFile
{
   param
   (
    [parameter(Mandatory = $true)]
    [ValidateScript({Test-Path $_})]
    [string] $Directory,

    [parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string] $ChangeName,

    [parameter(Mandatory = $false)]
    [bool] $OpenFile = $true
   )

    $timestamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
    $fullName = "$($timestamp)_$($ChangeName).sql"

    $path = Join-Path $Directory $fullName
    $path = [System.IO.Path]::GetFullPath($path)

    $sinkhole = Annotated-Invoke "Creating schema change script '$path'" -script `
    {
        if (Test-Path $path) { throw "File with name '$path' already exists!" }

        "-- this is your change script file stub" | Out-File -FilePath $path

        return $path
    }

    if ($OpenFile) { $sinkhole = Annotated-Invoke 'Opening your script' { Invoke-Item $path } }

    Write-Host "Enjoy!"
}