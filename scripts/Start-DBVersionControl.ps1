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
    [DBConnectionInfo] $connectionInfo,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [version] $currentVersion
)

. $PSScriptRoot\Common.ps1

if ($PSCmdlet.ParameterSetName -eq "manual")
{
    $connectionInfo = Create-ConnectionInfo -Server $serverInstance -Database $database -DbUser $dbuser -DbPass $dbpass
}

Write-Host -NoNewline "Enabling version control on database $database... "
	
$major = $currentVersion.Major
$minor = $currentVersion.Minor
$build = $currentVersion.Build
$point = $currentVersion.Revision

if ($major -lt 0 -or $minor -lt 0 -or $build -lt 0 -or $point -lt 0)
{
    throw 'Version number is invalid.'
}

$x = Invoke-SqlCmd2 `
	-Query "CREATE TABLE [dbo].[SchemaChanges](
                [ID] [int] IDENTITY(1,1) NOT NULL,
				[MajorReleaseNumber] [int] NOT NULL,
				[MinorReleaseNumber] [int] NOT NULL,
                [BuildReleaseNumber] [int] NOT NULL,
				[PointReleaseNumber] [int] NOT NULL,
                [ScriptName] [nvarchar](256) NOT NULL,
                [DateApplied] [datetime] NOT NULL,
                [Notes] [nvarchar] (max) NULL,

	            CONSTRAINT [PK_SchemaChanges] PRIMARY KEY CLUSTERED ([ID] ASC),
                CONSTRAINT [UQ_SchemaChanges__BuildVersion] UNIQUE (MajorReleaseNumber, MinorReleaseNumber, BuildReleaseNumber, PointReleaseNumber)
            )

            INSERT INTO [SchemaChanges] (MajorReleaseNumber, MinorReleaseNumber, BuildReleaseNumber, PointReleaseNumber, ScriptName, DateApplied, Notes)
            VALUES ($major, $minor, $build, $point, 'initial install', GETDATE(), null)
            " `
    -ConnectionInfo $connectionInfo `
    -ErrorAction Stop

Write-Success 'SUCCESS'