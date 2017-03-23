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

            if ($answer -match $freeTextValidator)
            {
                return $answer
            }

            $repeated += 1
        }
    }
}

function Get-WeekDayNumber
{
   param
   (
     [datetime]
     $date
   )

    $targetDayOfWeek = $date.DayOfWeek;
    # returns for given day number of the day in month
    [int]$n = 1;
    for ($d = $date.Day - 1; $d -ge  1; $d -= 1)
    {
        if ($date.AddDays(-$d).DayOfWeek -eq $targetDayOfWeek)
        {
            $n += 1;
        }
    }

    Write-Debug ('{0:dd MMMM} will be {1}th {2} in {3:MMMM}' -f $date, $n, $targetDayOfWeek, $date)

    return $n;
}

function Get-NthWeekDay
{
   param
   (
     [int]
     $year,

     [int]
     $month,

     [DayOfWeek]
     $targetWeekDay,

     [int]
     $n
   )

    $current = 0

    for ($dIdx = 1; $dIdx -le [DateTime]::DaysInMonth($year, $month); $dIdx += 1)
    {
        [DateTime] $cur = Get-Date -Year $year -Month $month -Day $dIdx -Hour 0 -Minute 0 -Second 0

        if ($cur.DayOfWeek -eq $targetWeekDay)
        {
            $current += 1;

            if ($current -eq $n)
            {
                return $cur
            }
        }
    }

    throw "Unable to find $n-th $targetWeekDay in $month/$year"
}

function Get-ReleaseDate
{
   param
   (
     [version]
     $ver
   )

    $year = $ver.Major
    $month = $ver.Minor
    $weekZeroBasedIndex = $ver.Build

    return Get-NthWeekDay (2000+$ver.Major) $ver.Minor $releaseDayOfWeek ($weekZeroBasedIndex+1)
}

function Get-ReleaseVersionForDate
{
   param
   (
     [datetime]
     $date
   )

    $year = $date.Year % 2000
    $month = $date.Month
    $releaseDayNum = Get-WeekDayNumber $date

    return [version] ('{0:00}.{1:00}.{2:0}' -f $year, $month, ($releaseDayNum-1))
}

function Get-NextReleaseNumber
{
   param
   (
     [version]
     $releaseVer
   )

    [DateTime] $releaseDate = Get-ReleaseDate $releaseVer
    [DateTime] $nextReleaseDate = $releaseDate.AddDays(+7)

    return Get-ReleaseVersionForDate $nextReleaseDate
}

function Next-WeekDay
{
   param
   (
     [DayOfWeek]
     $dayOfWeek
   )

    $cur = Get-Date
    $cur = $cur.AddDays(1)

    while ($cur.DayOfWeek -ne $dayOfWeek)
    {
        $cur = $cur.AddDays(1)
    }

    return $cur
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

function Create-NewSchemaChangeScript
{
   param
   (
     [string]
     $dir,

     [version]
     $scVersion
   )

    $scName = 'sc.{0}.{1:00}.{2}.{3:0000}.sql' -f $scVersion.Major, $scVersion.Minor, $scVersion.Build, [math]::max(1, $scVersion.Revision)
    $path = Join-Path $dir $scName
    $path = [System.IO.Path]::GetFullPath($path)


    Annotated-Invoke "Creating schema change script '$path'" -script `
    {
        if (Test-Path $path)
        {
            throw "File with name '$path' already exists!"
        }

        $releaseDate = Get-ReleaseDate $scVersion
        $content = (`
"-- this is your change script file stub`
-- this code planned to be released on {0:MMMM dd, yyyy}" -f $releaseDate)

        $content | Out-File -FilePath $path

        return $path
    }
}

function Print-ReleaseInfo
{
   param
   (
     [version]
     $ver
   )

    $date = Get-ReleaseDate $ver
    Write-Host ("Release on {0:MMMM dd, yyyy} - release version is '{1}'" -f $date, $ver)

}

function Check-GitBranchExists
{
   param
   (
     [string]
     $branch
   )

    try
    {
        git rev-parse --verify "$branch" | Out-Null
        return $true
    } catch 
    {
        return $false
    }
}

function Parse-ReleaseBranchReleaseVersion
{
   param
   (
     [string]
     $branch
   )

    $verStr = ([regex]"^.+-(.+)$").Match($branch).Groups[1].Value

    return [version]$verStr
}

function Get-GitLastRemoteReleaseBranchInfo()
{
    $remote = git.exe branch -a -r

    [string[]]$branches = $remote -isplit '`n'

    $lastReleaseVersion = $branches `
        | Where-Object { $_ -match 'origin/release/release-.+' } `
        | Select-Object @{name='Version';expression={ Parse-ReleaseBranchReleaseVersion $_ }}, `
                        @{name='BranchName';expression={ $_ }} `
        | Sort-Object -Property Version `
        | Select-Object -Last 1

    return $lastReleaseVersion
}

function Get-GitCurrentBranch()
{
    return git.exe rev-parse --abbrev-ref HEAD # http://stackoverflow.com/questions/6245570/how-to-get-current-branch-name-in-git
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

function Ensure-GitCLI()
{
    Annotated-Invoke 'Checking Git CLI' -script { git.exe | Out-Null } `
        -errorMessage 'Unable to locate GIT CLI, ensure that GIT is installed and added to Windows PATH environment variable'
}

function Fetch-GitOrigin()
{
    git.exe fetch origin
}

#Get-WeekDayNumber "5/5/2016"
#Ask-User "Test?" @("A", "B")



#Get-NthWeekDay 2016 4 "Thursday" 4
#Get-ReleaseDate "16.04.2"
#Create-NewSchemaChangeScript "D:\Repos\kb-modules\Database\KB\SchemaChanges" "16.5.5.1"
#Create-NextSchemaChangeScript "D:\Repos\kb-modules\Database\KB\SchemaChanges" "16.3.4"

#Get-NextReleaseNumber (Get-NextReleaseNumber (Get-NextReleaseNumber (Get-NextReleaseNumber "16.4.1")))

#[DateTime]$prevReleaseDay = (Next-WeekDay $releaseDayOfWeek).AddDays(-7)
#[version]$prevReleaseVer = Get-ReleaseVersionForDate $prevReleaseDay

#Print-ReleaseInfo $prevReleaseVer
#Print-ReleaseInfo (Get-NextReleaseNumber $prevReleaseVer)
#Print-ReleaseInfo (Get-NextReleaseNumber (Get-NextReleaseNumber $prevReleaseVer))

function Main()
{
    $who = [Environment]::UserName

    Write-Host "Hello, $who! Let me help you to create schema change script file!`n"
    Ensure-GitCLI
    Annotated-Invoke 'Fetch from origin (this will NOT alter your working copy)' { Fetch-GitOrigin }

    Write-Host ''

    #$branch = Ask-User "For which branch you want script to be created?" @("develop", "release")

    $branch = Get-GitCurrentBranch
    $inReleaseBranch = $branch.StartsWith('release')

    Write-Warning "You current branch is '$branch' -- ensure that you're on the right one`n"

    $database = Ask-User 'What the database name you want to create schema change script for?' @('KB', 'Scheduler')
    $dbScPath = [io.path]::combine($PSScriptRoot, '..', $database, 'SchemaChanges')

    Write-Host ''

    if ($inReleaseBranch)
    {
        $releaseNumber = Parse-ReleaseBranchReleaseVersion $branch
        $releaseDate = Get-ReleaseDate $releaseNumber

        Write-Host ('Your current branch is for release {0} ({1:MMMM dd, yyyy})' -f $releaseNumber, $releaseDate)
    
        $sc = Create-NextSchemaChangeScript $dbScPath $releaseNumber
    } else #if ($branch -eq 'develop') # we can additionally consider the case with feature branches, but those are rare, so let's treat all non-release branch in the same fashion
    {
        $lastRemoteReleaseBranchInfo = Get-GitLastRemoteReleaseBranchInfo
        $lastRemoteReleaseBranchName = $lastRemoteReleaseBranchInfo.BranchName
        $lastRemoteReleaseBranchVersion = $lastRemoteReleaseBranchInfo.Version
        $lastRemoteReleaseBranchReleaseDate = Get-ReleaseDate $lastRemoteReleaseBranchVersion

        Write-Host ("Last release branch version on remote: $lastRemoteReleaseBranchName - for release $lastRemoteReleaseBranchVersion ({0:MMMM dd, yyyy})" -f $lastRemoteReleaseBranchReleaseDate)

        $developReleaseVer = Get-NextReleaseNumber $lastRemoteReleaseBranchVersion
        $developReleaseDate = Get-ReleaseDate $developReleaseVer

        Write-Host ("Use next after the last release branch release number: $developReleaseVer (release on {0:MMMM dd, yyyy})" -f $developReleaseDate )

        $sc = Create-NextSchemaChangeScript $dbScPath $developReleaseVer
    }

    

    Annotated-Invoke 'Opening your script' { Invoke-Item $sc }

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