Function Test-JSONContent
{
  [CmdLetBinding()]
  Param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = 'ProduceOutputFile', HelpMessage = 'Specify the file paths for the policy definition files.')]
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = 'NoOutputFile', HelpMessage = 'Specify the file paths for the policy definition files.')]
    [String]$path,

    [Parameter(ParameterSetName = 'ProduceOutputFile', Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OutputFile,
		[Parameter(ParameterSetName = 'ProduceOutputFile', Mandatory=$false)][ValidateSet('NUnitXml', 'LegacyNUnitXML')][string]$OutputFormat='NUnitXml'
  )
  #Test files
  $FileContentTestFilePath = Join-Path $PSScriptRoot 'fileContent.tests.ps1'

  #File Content tests
  If ($PSCmdlet.ParameterSetName -eq 'ProduceOutputFile')
  {
    #Common - File content tests
    $FileContentTestResult = Invoke-Pester -path $FileContentTestFilePath -OutputFile $OutputFile -OutputFormat $OutputFormat -PassThru
  } else {
    $FileContentTestResult = Invoke-Pester -path $FileContentTestFilePath -PassThru
  }
  if ($FileContentTestResult.TestResult.Result -ieq 'failed')
  {
    Write-Error "File content test failed."
  }
}
