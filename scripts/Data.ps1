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
    Undefined = 0
    Applied = 1
    Pending = 2
    PendingOutOfOrder = 3
}

# represents info about File System stored Schema Change file
class FSSCInfo
{
    [string] $ChangeId
    [string] $Path
    [datetime] $CreatedAtUtc
    [FSSCStatus] $Status
    [string] $Info
    [string] $Hash
}

# represents DB info about applied Schema Change File
class DBSCInfo
{
    [string] $ChangeId # uniquely identifies change script
    [datetime] $AppliedAt
    [string] $Notes
}