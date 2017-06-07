# data structures are separated, because any change in classes
# will cause type conflic when using strongly typed variables until PS session restart

class DBConnectionInfo
{
    [string] $Server
    [string] $Database
    [string] $DbUser
    [string] $DbPass
    [bool] $UseAzureADAuth

    [void] Validate()
    {
        if ($this.Server -eq $null `
            -or $this.Database -eq $null `
            -or $this.DbUser -eq $null `
            -or $this.DbPass -eq $null)
        {
            throw 'Database connection information was incomplete'
        }
    }
    
    [string] ToString()
    {
        return '[Server:{0};DB:{1};User:{2};UseAD:{3}]' -f $this.Server, $this.Database, $this.DbUser, $this.UseAzureADAuth
    }
}

enum FSSCStatus
{
    Undefined = -1
    Applied = 0
    Pending = 1
    Lost = 2
}

# represents info about File System stored Schema Change file
class FSSCInfo
{
    [string] $Name
    [string] $Path
    [version] $Version
    [datetime] $CreatedAtUtc
    [FSSCStatus] $Status
    [string] $StatusDesc
}

# represents DB info about applied Schema Change File
class DBSCInfo
{
    [version] $Version # uniquely identifies regular change script
    [datetime] $AppliedAtUtc
    [string] $Notes
    [string] $Name
}

# FEATURE CHANGES SUPPORT
class FeatureFSSCInfo
{
    [string] $Name
    [string] $Path
    [datetime] $CreatedAtUtc
    [FSSCStatus] $Status
    [string] $StatusDesc
}

class FeatureDBSCInfo
{
    [string] $Name # uniquely identifies feature change script
    [datetime] $AppliedAtUtc
    [string] $Notes
}

# END OF FEATURE CHANGES SUPPORT