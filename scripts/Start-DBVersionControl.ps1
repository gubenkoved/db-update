Param
(
    [Parameter(Mandatory=$true, ParameterSetName='manual')]
    [ValidateNotNullOrEmpty()]
    [string] $serverInstance,

    [Parameter(Mandatory=$true, ParameterSetName='manual')]
    [ValidateNotNullOrEmpty()]
    [string] $database,

    [Parameter(Mandatory=$true, ParameterSetName='manual')]
    [ValidateNotNullOrEmpty()]
    [string] $dbuser,

    [Parameter(Mandatory=$true, ParameterSetName='manual')]
    [ValidateNotNullOrEmpty()]
    [string] $dbpass,

    [Parameter(Mandatory=$true, ParameterSetName='script')]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ $_.PSObject.TypeNames[0] -eq 'DBConnectionInfo' })]
    [object] $connectionInfo # can not use DBConnectionInfo type because PS won't be able to recognzie it when executed as script directly
)

. $PSScriptRoot\Common.ps1

if ($PSCmdlet.ParameterSetName -eq "manual")
{
    $connectionInfo = Create-ConnectionInfo -Server $serverInstance -Database $database -DbUser $dbuser -DbPass $dbpass
}

[bool] $versionControlEnabled = Check-IsVersionControlEnabled -connectionInfo $connectionInfo -errorAction Stop

if ($versionControlEnabled -eq $true)
{
    Write-Warning "Version control already enabled on database $database -- SKIP"
} else
{
    Write-Host -NoNewline "Enabling version control on database $database... "
	
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