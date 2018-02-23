# import custom data structures
. $PSScriptRoot\Data.ps1

Import-module SqlServer # we will need advanced Invoke-Sqlcmd from there that supports ConnectionString

function Write-Success
{
    param
    (
        [string] $string
    )

    Write-Host $string -ForegroundColor Green
}

function Use-Database
{
    param
    (
        [parameter(Mandatory=$true)]
        [string] $Server,

        [parameter(Mandatory=$true)]
        [string] $Database,

        [parameter(Mandatory=$true)]
        [string] $DbUser,

        [parameter(Mandatory=$true)]
        [string] $DbPass,

        [parameter(Mandatory=$false)]
        [bool] $UseAzureADAuth = $false
    )

    if ($Script:ConnectionInfo -ne $null) { Write-Warning "Already connected to the DB, reconnecting..." }

    [DBConnectionInfo] $connectionInfo = New-Object DBConnectionInfo
    
    $connectionInfo.Server = $Server
    $connectionInfo.Database = $Database
    $connectionInfo.DbUser = $DbUser
    $connectionInfo.DbPass = $DbPass
    $connectionInfo.UseAzureADAuth = $UseAzureADAuth

    # check the connection
    Write-Host "Checking the connection... " -NoNewline
    
    try
    {
        $dbResult = Invoke-Sqlcmd2 -Query "select 1" -ConnectionInfo $connectionInfo -ErrorAction Stop
        Write-Success "OK"
    } catch
    {
        throw "Error checking connection: $($_.Exception.Message)"
    }

    $Script:ConnectionInfo = $connectionInfo
}

function Ensure-DatabaseConnectionInfo
{
    [CmdletBinding()]
    [OutputType([DBConnectionInfo])]
    param
    (
    )

    if ($Script:ConnectionInfo -eq $null) { Write-Error "Invoke Use-Database to work with database updates" }

    return $Script:ConnectionInfo
}

function Invoke-Sqlcmd2
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Query,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [object] $ConnectionInfo,

        [Parameter(Mandatory=$false)]
        [int] $QueryTimeout = 30
    )

     # assembly connection string
    $connectionString = "User ID=$($ConnectionInfo.DbUser);Password=$($ConnectionInfo.DbPass);Initial Catalog=$($ConnectionInfo.Database);Data Source=$($ConnectionInfo.Server);"

    if ($ConnectionInfo.UseAzureADAuth)
    {
        $connectionString += 'Authentication=Active Directory Password;'
    }

    $result = Invoke-Sqlcmd `
        -Query $Query `
        -QueryTimeout $QueryTimeout `
        -ConnectionString $connectionString

    if ($? -eq $false) # last command status is not OK and ErrorAction allows to go this line (Continue, SilentlyContinue)
    {
        [string]$msg = $Error[0].ToString()

        Write-Warning "$msg"
    }

    return $result
}

function Exec-SQL()
{
    [CmdletBinding()]
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

    Write-Verbose " Executing '$tempPathForQuery' script, log to '$tempPathForLog'..."

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

    if ($connectionInfo.UseAzureADAuth)
    {
        $sqlcmdOut = SQLCMD.EXE -S "$server" -d "$db" -U "$user" -P "$pass" -i $tempPathForQuery -I -G `
            | Out-File $tempPathForLog
    }
    else
    {
        $sqlcmdOut = SQLCMD.EXE -S "$server" -d "$db" -U "$user" -P "$pass" -i $tempPathForQuery -I `
            | Out-File $tempPathForLog
    }

    $outContent = [IO.File]::ReadAllText($tempPathForLog)

    if ($LASTEXITCODE -ne 0) # sqlcmd reports an error occured
    {
        throw "SQLCMD didn't run succesfully -- exit code=$LASTEXITCODE`nOutput:`n$outContent"
    }

    #Write-Host " SQLCMD OUT:`n $outContent"

    return $outContent
}

function Check-IsVersionControlEnabled
{
    [CmdletBinding()]
    param
    (
    )

    $connectionInfo = Ensure-DatabaseConnectionInfo -ErrorAction Stop

    $result = Invoke-Sqlcmd2 `
        -Query "select object_id('__SchemaChanges') as oid" `
        -ConnectionInfo $connectionInfo `
        -ErrorAction Stop
	
  # true means enabled version control
  return $result.oid -ne [DBNull]::Value
}

function Enable-DatabaseUpdate
{
    [DBConnectionInfo] $connectionInfo = Ensure-DatabaseConnectionInfo -ErrorAction Stop

    [bool] $versionControlEnabled = Check-IsVersionControlEnabled -ErrorAction Stop

    if ($versionControlEnabled -eq $true)
    {
        Write-Warning "Version control already enabled on database $($connectionInfo.Database)"
    } else
    {
        Write-Host -NoNewline "Enabling version control on database $($connectionInfo.Database)... "
	
        $x = Invoke-SqlCmd2 `
	        -Query "CREATE TABLE [dbo].[__SchemaChanges](
                        ChangeId nvarchar(256) NOT NULL,
                        AppliedAt datetime NOT NULL,
                        Notes nvarchar(max) NULL,

	                    CONSTRAINT [PK_SchemaChanges] PRIMARY KEY CLUSTERED ([ChangeId] ASC)
                    )

                    INSERT INTO [__SchemaChanges] (ChangeId, AppliedAt, Notes)
                    VALUES ('__init.sql', GETDATE(), 'initial install')" `
            -ConnectionInfo $connectionInfo `
            -ErrorAction Stop

        Write-Success 'SUCCESS'
    }
}

function Get-AppliedChanges
{
    [OutputType([DBSCInfo[]])]
    param
    (
    )

    $connectionInfo = Ensure-DatabaseConnectionInfo -ErrorAction Stop
    
    [array] $sqlResult = Invoke-Sqlcmd2 `
      -Query 'SELECT ChangeId, AppliedAt, Notes FROM __SchemaChanges' `
      -ConnectionInfo $connectionInfo `
      -ErrorAction Stop

    [DBSCInfo[]] $result = @()
    
    if ($sqlResult -ne $null)
    {
        $result = $sqlResult `
            | % { New-Object DBSCInfo -Property @{ChangeId = $_.ChangeId; AppliedAt = $_.AppliedAt; Notes = $_.Notes; } } `
            | Sort-Object -Property Version
    }

    return $result
}

function Wrap-SQLBatches
{
   param
   (
     [string] $sql
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
     [string] $sql
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
        [Parameter(Mandatory=$true)]
        [string] $path
    )

    [string] $hash = Get-MD5FileHash $path

    $notes = 'Machine: {0}; User: {1}; MD5: {2};' -f [System.Net.Dns]::GetHostName(), [Environment]::UserName, $hash

    return $notes
}

function Run-SqlScriptsInFolder
{
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory=$true)]
        [DBConnectionInfo] $connectionInfo,

        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_})] 
        [string] $folder
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
            Write-Error "ERROR running $($script.Name): $($_.Exception.Message)"
        }
    }
}

function Get-AllExistingChanges
{
   [OutputType([FSSCInfo[]])]
   param
   (
    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [string] $dir
   )

    [FSSCInfo[]] $scripts = Get-ChildItem $dir `
        | Where-Object { $_.Name.EndsWith('.sql')  } `
        | % { Get-ChangeScriptInfo $_.FullName }`
        | Sort-Object -Property ChangeId

    return $scripts
}

function Get-ChangeScriptInfo
{
    [OutputType([FSSCInfo])]
    param
    (
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string] $path
    )

    if (-not (Test-Path $path))
    {
        throw "Change script '$path' was not found (working dir is $(Resolve-Path .))"
    }

    $fullPath = Resolve-Path $path

    [System.IO.FileInfo] $fileInfo = New-Object System.IO.FileInfo $fullPath

    $result = New-Object FSSCInfo -Property @{
            ChangeId = $fileInfo.Name;
            Path = $fileInfo.FullName;
            CreatedAtUtc = $fileInfo.CreationTimeUtc;
            Status = [FSSCStatus]::Undefined;
            Hash = Get-MD5FileHash -path $fileInfo.FullName;
        }

    return $result
}

function Populate-ExistingChangesStatus
{
   [OutputType([FSSCInfo[]])]
   param
   (
        [Parameter(Mandatory=$True, ValueFromPipeline=$True)]
		[FSSCInfo[]] $all,

        [Parameter(Mandatory=$True)]
        [DBSCInfo[]] $applied
   )

    process
    {
        [DBSCInfo] $lastChange = $applied | Sort-Object -Property ChangeId  | Select-Object -Last 1

        foreach ($fsSc_ in $all)
        {
            [FSSCInfo] $change = $fsSc_
            
            [DBSCInfo] $findResult = $applied | Where-Object { $change.ChangeId -eq $_.ChangeId }

            if ($findResult)
            {
                $change.Status = [FSSCStatus]::Applied
                $change.Info = "Applied at $($findResult.AppliedAt)"
            } elseif ($lastChange -ne $null -and $change.ChangeId -lt $lastChange.ChangeId)
            {
                $change.Status = [FSSCStatus]::PendingOutOfOrder
                $change.Info = 'Pending - Out of order'
            } else
            {
                $change.Status = [FSSCStatus]::Pending
                $change.Info = 'Pending'
            }

            return $change
        }
    }
}

function Apply-ChangeScript
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [FSSCInfo] $ChangeScript,

        [Parameter(Mandatory=$false)]
        [bool] $MarkOnlyMode = $false
    )

    $connectionInfo = Ensure-DatabaseConnectionInfo -ErrorAction Stop

    Write-Host -NoNewline " Apply '$($ChangeScript.ChangeId)' change script... "

    $notes = Get-ScriptNotes -path $ChangeScript.Path
    $notes = $notes.Replace("'", "''") # encode just in case

    $sql = [IO.File]::ReadAllText($ChangeScript.Path)

    # when mark only mode, then overwrite real script
    if ($MarkOnlyMode -eq $true)
    {
        Write-Host -NoNewline "  MARK ONLY"
        $sql = "-- MARK ONLY"
        $notes += " MARK ONLY;"
    }

    $sql += "
    GO
    ;INSERT INTO dbo.__SchemaChanges (ChangeId, AppliedAt, Notes)
                VALUES ('$($ChangeScript.ChangeId)', getutcdate(), '$notes')"

    $sql = Make-SQLAtomic $sql

    Write-Verbose ("`nExecuting SQL block:`n" + $sql);

    try
    {
        $elapsed = Measure-Command { $output = Exec-SQL -query $sql -connectionInfo $connectionInfo }

        # ensure applied
        [DBSCInfo] $dbChangeInfo = Get-AppliedChanges -connectionInfo $connectionInfo -ErrorAction Stop `
          | Where-Object { $_.ChangeId -eq $ChangeScript.ChangeId } `
          | Select-Object -First 1

        if ($dbChangeInfo -eq $null)
        {
            throw "An error occured applying '$($ChangeScript.ChangeId)' change script.`n$output"
        }
        
    } catch
    {
        Write-Host ("  FAILED -- {0}`n" -f $_.Exception.ToString()) `
            -ForegroundColor Red -BackgroundColor Yellow

        throw
    }
        
    Write-Success ('  SUCCESS ({0:F3} s.)' -f $elapsed.TotalSeconds)
}

function Ensure-Directory
{
    [CmdletBinding()]
    param
    (
        [string] $ErrorMessagePrefix,
        [string] $Dir
    )

    if ([string]::IsNullOrEmpty($Dir))
    {
        Write-Error "$ErrorMessagePrefix Directory was not specified"
    }

    $exists = Test-Path -Path $Dir -PathType Container

    if ($exists -eq $false)
    {
        Write-Error "$ErrorMessagePrefix Directory '$Dir' was not found"
    }
}