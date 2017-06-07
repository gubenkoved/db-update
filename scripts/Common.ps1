# import custom data structures
. $PSScriptRoot\Data.ps1

function Write-Success
{
    param
    (
        [string]
        $string
    )

    Write-Host $string -ForegroundColor Green
}

function Create-ConnectionInfo()
{
    [OutputType([DBConnectionInfo])]

    Param
    (      
        [parameter(Mandatory=$true)]
        [string] $Server,

        [parameter(Mandatory=$true)]
        [string] $Database,

        [parameter(Mandatory=$true)]
        [string] $DbUser,

        [parameter(Mandatory=$true)]
        [string] $DbPass
    )
    
    [DBConnectionInfo] $connectionInfo = New-Object DBConnectionInfo
    
    $connectionInfo.Server = $Server
    $connectionInfo.Database = $Database
    $connectionInfo.DbUser = $DbUser
    $connectionInfo.DbPass = $DbPass
    
    return $connectionInfo
}

function Invoke-Sqlcmd2
{
    [CmdletBinding(SupportsShouldProcess=$true)]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Query,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $ConnectionInfo,

        [Parameter(Mandatory=$false)]
        [int] $QueryTimeout = 30
    )

  if ($WhatIfPreference -eq $true)
  {
    Write-Host "[WHATIF MODE] Executing following SQL against '$ConnectionInfo' (timeout: $QueryTimeout sec): `n$Query"
  } else
  {
      Invoke-Sqlcmd `
        -Query $Query `
        -QueryTimeout $QueryTimeout `
        -ServerInstance $ConnectionInfo.Server `
        -Database $ConnectionInfo.Database `
        -Username $ConnectionInfo.DbUser `
        -Password $ConnectionInfo.DbPass

      if ($? -eq $false) # last command status is not OK and ErrorAction allows to go this line (Continue, SilentlyContinue)
      {
        [string]$msg = $Error[0].ToString()

        Write-Warning "$msg"
      }
  }
}

function Exec-SQL()
{
    [CmdletBinding(SupportsShouldProcess=$True)]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $query
    )

    $connectionInfo.Validate()

    $tempPathForQuery = [System.IO.Path]::GetTempFileName()
    $tempPathForLog = [System.IO.Path]::GetTempFileName()

    $query | out-file -filepath $tempPathForQuery

    Write-Host " Executing '$tempPathForQuery' script, log to '$tempPathForLog'..."

    $server = $connectionInfo.Server
    $db = $connectionInfo.Database
    $user = $connectionInfo.DbUser
    $pass = $connectionInfo.DbPass

    # there is an ability to pass "-b" flag to sqlcmd and then sql cmd will automatically stop processing if error occured
    # and it will indicate error by return code
    # however we ourselves wraping sql in blocks so that if error occured
    # the rest of the script is not executed and block is rolled back
    # the sqlcmd without -b will return 0 status code and we validating whether script applied or not
    # by the trail - the last block in each script - insert into SchemaChanges table - we can check
    # after script executed whether or not it left record in this table
    # -I enables quoted identifiers

    $sqlcmdOut = SQLCMD.EXE -S "$server" -d "$db" -U "$user" -P "$pass" -i $tempPathForQuery -I `
        | Out-File $tempPathForLog

    $outContent = [IO.File]::ReadAllText($tempPathForLog)

    if ($LASTEXITCODE -ne 0) # sqlcmd reports an error occured
    {
        throw "SQLCMD didn't run succesfully -- exit code=$LASTEXITCODE`nOutput:`n$outContent"
    }

    #Write-Host " SQLCMD OUT:`n $outContent"

    return $outContent
}

function Check-DBVersionControl
{
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo
    )

  $result = Invoke-Sqlcmd `
    -Query "SELECT * 
                 FROM INFORMATION_SCHEMA.TABLES 
                 WHERE TABLE_SCHEMA = 'dbo' 
                 AND  TABLE_NAME = 'SchemaChanges'" `
    -ServerInstance $connectionInfo.Server `
    -Database $connectionInfo.Database `
        -Username $connectionInfo.DbUser `
        -Password $connectionInfo.DbPass `
        -ErrorAction Stop

	
  #true means enabled version control
  return $result -ne $null
}

function Get-DbUpdateConfirmation
{
   param
   (
     [string]
     $expected
   )

    Write-Host 'Please type the name of the environment you are going to update'
    Write-Warning "$expected"

    $answer = Read-Host "To make sure that it's as expected, please type the name of environment"

    if ($answer -ne $expected)
    {
        throw "This was not expected answer, please make sure you are running DB Update Script against the expected environment that is $expected"
    }
}

function Wrap-SQLBatches
{
   param
   (
     [string]
     $sql
   )

    $preTempl = '
    -- start block {0}
    go
  '
    
    $postTempl = "
    go
    if @@error <> 0 and @@trancount > 0 begin print 'rollback on block #{0}'; rollback end
    if @@trancount = 0 begin print 'error in block #{0}'; set nocount on; set noexec on; end
    -- end block {0}
  "

    [string[]]$batches = ($sql -split 'GO\r\n') | Where-Object { [string]::IsNullOrWhiteSpace($_) -eq $false }

    [string]$result = ''

    foreach($x in $batches)
    {
        $i = [array]::IndexOf($batches, $x)
        
        $pre = ($preTempl -f $i)
        $post = ($postTempl -f $i)

        # indent script
        $x = ("`n" + $x) -replace "`n","`n`t"

        $cur = ("{0}`n{1}`n{2}" -f $pre, $x, $post)

        #Write-Host "Cur: $cur"

        $result += $cur
    }

    return $result
}

function Make-SQLAtomic
{
   param
   (
     [string]
     $sql
   )

    #Write-Host "Source: $sql"

    $atomicBody = Wrap-SQLBatches $sql

    #Write-Host "Wrapped: $atomicBody"

    return "set xact_abort on
    go

    begin tran
    $atomicBody
    go
    print 'Success.'
    commit
    set noexec off
  set nocount off"
}

function Get-MD5FileHash
{
    param
    (
        [string] $path
    )

    $hash = Get-FileHash $path -Algorithm MD5

    return $hash.Hash
}

function Get-ScriptNotes
{
    param
    (
        [Parameter(Mandatory=$true, ParameterSetName="sc")]
        [FSSCInfo]
        $schemaChangeInfo,

        [Parameter(Mandatory=$true, ParameterSetName="generic")]
        [string]
        $path
    )

    if ($PsCmdlet.ParameterSetName -eq "sc")
    {
        $path = $schemaChangeInfo.Path
    }

    [string] $hash = Get-MD5FileHash $path

    $notes = 'Machine: {0}; User: {1}; Hash: {2};' -f [System.Net.Dns]::GetHostName(), [Environment]::UserName, $hash

    return $notes
}

function Parse-ChangeFileVersion
{
   param
   (
     [string]
     $filename
   )

    #Write-Host "Filename was $filename"

    $r = $filename -match '^sc\.([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)\.sql$'

    if (-not $r)
    {
        return $null;
    }

    $major = [convert]::ToInt32($matches[1])
    $minor = [convert]::ToInt32($matches[2])
    $build = [convert]::ToInt32($matches[3])
    $point = [convert]::ToInt32($matches[4])

    $verStr = "$major.$minor.$build.$point"

    return [version] $verStr
}

function Get-AllExistingChanges
{
   [OutputType([FSSCInfo[]])]
   param
   (
     [string]
     $dir
   )

    [FSSCInfo[]] $scripts = Get-ChildItem $dir `
        | Where-Object { Parse-ChangeFileVersion $_.Name } `
        | Sort-Object -Property { Parse-ChangeFileVersion $_.Name } `
        | % { New-Object FSSCInfo -Property @{`
            Name = $_.Name
            Path = $_.FullName
            Version = Parse-ChangeFileVersion $_.Name
            CreatedAtUtc = $_.CreationTimeUtc
            Status = [FSSCStatus] 'Undefined' } }

    if ($scripts -eq $null) # no files -> replace null via empty array
    {
        $scripts = @()
    }

    return $scripts
}

function Run-SqlScriptsInFolder
{
    [CmdletBinding(SupportsShouldProcess=$True)]
    Param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [DBConnectionInfo] $connectionInfo,

        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_})] 
        [string] $folder,

        [Parameter(Mandatory=$false)]
        [bool] $continueOnErrors = $false
    )

    $scripts = Get-ChildItem $folder `
        | Where-Object {$_.Extension -ieq '.sql'} `
        | Sort-Object -Property Name

    foreach ($script in $scripts)
    {
        Write-Host -NoNewline ('  Running {0}... ' -f $script.Name)

        $sql = [IO.File]::ReadAllText($script.FullName)

        try
        {
             Invoke-Sqlcmd2 `
                -Query $sql `
                -QueryTimeout 600 `
                -ConnectionInfo $connectionInfo `
                -ErrorAction Stop `
                | Out-Null

            Write-Success 'SUCCESS'
        } catch
        {
            if ($continueOnErrors)
            {
                Write-Warning "$($_.Exception.Message)"
            } else
            {
                Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
                throw
            }
        }
    }
}