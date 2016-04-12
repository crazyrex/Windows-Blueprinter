Function Invoke-PuppetGenerator
{
  [CmdletBinding()]
  param(
    [string[]]$ComputerName = 'localhost',
    [AllowNull()]
    [PSCredential]$Credential = $null,
    [string]$ModulePath = (Join-Path $PSScriptRoot "resources"),
    [string]$OutPutPath = (Join-Path $PSScriptRoot "output")
  )

  $jsonFilePath = Join-Path $OutPutPath "json"
  $manifestFilePath = Join-Path $OutPutPath "manifest"

  if(-not(Test-path $OutPutPath)){ mkdir $OutPutPath }
  if (Test-Path($jsonFilePath)) { Remove-Item $jsonFilePath -Force -Recurse -EA SilentlyContinue }
  if(-not(Test-path $jsonFilePath)){ mkdir $jsonFilePath | Out-Null }
  if (Test-Path($manifestFilePath)) { Remove-Item $manifestFilePath -Force -Recurse -EA SilentlyContinue }
  if(-not(Test-path $manifestFilePath)){ mkdir $manifestFilePath | Out-Null }

  Write-Verbose "Creating connections to target nodes"
  $connectionInfo = $PSBoundParameters
  $connectionInfo.Remove('ModulePath') | Out-Null
  $connectionInfo.Remove('OutPutPath') | Out-Null
  $connectionInfo.ErrorAction = 'SilentlyContinue'
  $connectionInfo.ErrorVariable = '+connectionErrors'

  # TODO: Write our computers not connected to
  $sessions = New-PSSession @connectionInfo

  Write-Verbose "Adding modules to discover"
  Get-ChildItem -Path $ModulePath -Directory | % {

    [IO.FileInfo]$moduleFile     = Join-Path $_.FullName "$($_.Name).ps1"
    [IO.FileInfo]$moduleManifest = Join-Path $_.FullName "ConvertTo-Manifest$($_.Name).ps1"

    $sb = New-ScriptCommand -Name $moduleFile.BaseName -Content $content

    $CommandInfo = @{
      Session       = $sessions
      ThrottleLimit = 100
      ScriptBlock   = $sb
      ErrorAction   = 'SilentlyContinue'
      ErrorVariable = '+commandErrors'
    }

    Write-Verbose "Executing $($moduleFile.BaseName) on target nodes"
    $info = Invoke-Command @CommandInfo

    $info | Group-Object PSComputerName | % {
      $computername = $_.Name
      $groupInfo    = $_.Group
      $jsonParams   = @{
        info         = $groupInfo
        computername = $computername
        moduleName   = $moduleFile.BaseName
        OutPutPath   = $jsonFilePath
      }

      Write-Verbose "Exporting $($moduleFile.BaseName) info from $($computername) to json"
      $outputFile = New-JSONOutputFile @jsonParams

      $jsonString = [string]([IO.File]::ReadAllText($outputFile))
      if($jsonString){
        $manifestParams = @{
          ModuleName = $moduleFile.BaseName
          Module     = $moduleManifest
          jsonString = $jsonString
          OutPutPath = $manifestFilePath
        }

        Write-Verbose "Parsing $($moduleFile.BaseName) info from $($computername) to Puppet manifest"
        # TODO: Catch a write exception here
        New-PuppetManifestFile @manifestParams
      }
    }
  }

  $sessions | Remove-PSSession

  Write-Output "Manifests are located at '$manifestFilePath'"
}

function New-PuppetManifestFile
{
  param(
    $ModuleName,
    [IO.FileInfo]$Module,
    $JsonString,
    $OutputPath
  )

  . $Module.FullName

  $manifestText = &"$($Module.BaseName)" -jsonString $JsonString

  if ($manifestText -eq $null -or $manifestText -eq '') {
    Write-Warning "Content for $($Module.BaseName) was empty"
    return
  }

  $outputFile = (Join-Path $OutputPath "$computername.$($moduleName).pp")

  $utf8EncodingWithoutBom = New-Object System.Text.UTF8Encoding($false)
  if (Test-Path($outputFile)) { Remove-Item $outputFile -Force }
  [System.IO.File]::WriteAllLines($outputFile, $manifestText, $utf8EncodingWithoutBom)
}

function New-JSONOutputFile
{
  param(
    $info,
    $computername,
    $moduleName,
    $outputPath
  )

  try{
    $outputFile = (Join-Path $outputPath "$computername.$($moduleName).json")
    if (Test-Path($outputFile)) { Remove-Item $outputFile -Force }

    $info = $info | ConvertTo-JSON -Depth 10

    $info | Out-File -Force -FilePath $outputFile

    $outputFile
  }catch{
    Write-Error "Failed to convert data for $ModuleName to JSON"
  }
}

function New-ScriptCommand
{
  param(
    $Name,
    $content
  )

  [string]$content = [IO.File]::ReadAllText($moduleFile.fullname)
  $code = @"
New-Module -ScriptBlock {$($content)} -Name $($Name) | Import-Module;
Get-$($Name);
"@
  $sb = [ScriptBlock]::Create($code)
  $sb
}

Export-ModuleMember -Function Invoke-PuppetGenerator
