# import shared code
. $PSScriptRoot\Common.ps1

# stop on not handled errors
$ErrorActionPreference = 'Stop'

# release day
[System.DayOfWeek] $releaseDayOfWeek = 'Thursday'

function Ask-User
{
   param
   (
     [string]
     $question,

     [String[]]
     $choices,

     [string]
     $freeTextValidator
   )

    [int]$repeated = 0

    if ($choices -ne $null -and $choices.Count -gt 0)
    {
        while ($true)
        {
            if ($repeated -gt 0)
            {
                Write-Host "Didn't get it :(
                Please choose from suggeseted alternatives - eigther type whole alternative or simply index"
            }

            Write-Host $question

            for($i = 1; $i -le $choices.Count; $i += 1)
            {
                $choice = $choices[$i-1]

                Write-Host "[$i] $choice"
            }

            Write-Host -NoNewline '>> '

            [string] $answer = Read-Host

            if ($answer -match "^[\d\.]+$") # number?
            {
                $cn = [int]::Parse($answer)
                if ($cn -le $choices.Count -and $cn -gt 0)
                {
                    return $choices[$cn - 1]
                }
            } else # choice text?
            {
                foreach ($x in $choices)
                {
                    if ($answer -eq $x)
                    {
                        return $x
                    }
                }
            }

            $repeated += 1
        } 
    } else # choices are not suggested
    {
        while ($true)
        {
            if ($repeated -gt 0)
            {
                Write-Host "Please enter the string that satisfies regex: '$freeTextValidator'"
            }

            Write-Host $question

            Write-Host -NoNewline '>> '

            $answer = Read-Host

            if ([Regex]::IsMatch($answer, $freeTextValidator))
            {
                return $answer
            }

            $repeated += 1
        }
    }
}

function Create-NextSchemaChangeScript
{
   param
   (
     [string]
     $dir,

     [version]
     $releaseVersion
   )

    $all = Get-AllExistingChanges $dir
    $lastSc = $all | Sort-Object -Property Version | Select-Object -Last 1

    $lastScVer = [version] $lastSc.Version
    $lastScScriptName = $lastSc.Name
    $lastScRelease = [version] ('{0}.{1}.{2}.0' -f $lastScVer.Major, $lastScVer.Minor, $lastScVer.Build)

    Write-Host "The maximal schema change version file I found is '$lastScScriptName' that is for release $lastScRelease"

    $nextSc = [version] ('{0}.{1}.{2}.{3}' -f $lastScVer.Major, $lastScVer.Minor, $lastScVer.Build, ($lastScVer.Revision+1))

    if ($releaseVersion -gt $nextSc)
    {
        $nextSc = $releaseVersion
    }

    return Create-NewSchemaChangeScript $dir $nextSc
}

function Create-SchemaChangeScript
{
   param
   (
     [ValidateScript({Test-Path $_})]
     [string] $dir,

     [ValidateNotNullOrEmpty()]
     [string] $name
   )

    $timestamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
    $fullName = "$($timestamp)_$($name).sql"

    $path = Join-Path $dir $fullName
    $path = [System.IO.Path]::GetFullPath($path)

    Annotated-Invoke "Creating schema change script '$path'" -script `
    {
        if (Test-Path $path)
        {
            throw "File with name '$path' already exists!"
        }

        "-- this is your change script file stub" | Out-File -FilePath $path

        return $path
    }
}

function Annotated-Invoke
{
   param
   (
     [string]
     $desc,

     [scriptblock]
     $script,

     [string]
     $errorMessage
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

function Main()
{
    $who = [Environment]::UserName

    Write-Host "Hello, $who! Let me help you to create schema change script file!`n"

    $database = Ask-User 'What the database name you want to create schema change script for?' @('test-db', 'test-db2')
    $name = Ask-User 'What the name for your change ?' -freeTextValidator "^[a-zA-Z0-9_]+$"

    $dbScDir = [io.path]::combine($PSScriptRoot, '..', $database, 'schema-changes')

    $fullPath = Create-SchemaChangeScript $dbScDir $name

    Annotated-Invoke 'Opening your script' { Invoke-Item $fullPath }

    Write-Host "Enjoy!"
}

try
{
    Push-Location $PSScriptRoot
    Main
} finally
{
    Pop-Location
}