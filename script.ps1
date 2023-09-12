# ------------------------------------------------------------------------------
# KeePass cloud syncer
#
# Simple PowerShell script for uploading copies of the local KeePass
# .kdbx file to the cloud drives.
#
# Repository: https://github.com/barfi/keepass-cloud-syncer
# ------------------------------------------------------------------------------

# - Internal vars --------------------------------------------------------------

param ([Parameter(Position=0)][string] $_sourcePath = '') # source file path
$_selfDir = Split-Path $MyInvocation.MyCommand.Path       # script self dir

# - Utils ----------------------------------------------------------------------

function Format-Json([Parameter(Mandatory, ValueFromPipeline)][String] $json) {
  # Thanks to the author https://stackoverflow.com/a/55384556
  $indent = 0;
  ($json -Split "`n" | ForEach-Object {
    if ($_ -match '[\}\]]\s*,?\s*$') { $indent-- }
    $line = ('  ' * $indent) + $($_.TrimStart() -replace '":  (["{[])', '": $1' -replace ':  ', ': ')
    if ($_ -match '[\{\[]\s*$') { $indent++ }
    $line
  }) -Join "`n"
}

# - Logger ---------------------------------------------------------------------

class Logger {
  # Writes given string with colored prefix and timestamp to the host
  [void]Log([string]$prefix, [string]$color, [string]$str){
    $time = " $(Get-Date -Format 'HH:mm:ss') "
    Write-Host $prefix -f $color -NoNewline
    Write-Host $time -f 'DarkGray' -NoNewline
    Write-Host $str.Replace("`n", "`n$(' ' * ($prefix + $time).Length)")
  }

  # Writes given string with predefined Info template to the host 
  [void]LogInfo([string]$str){ $this.Log('INF', 'Blue', $str) }

  # Writes given string with predefined Success template to the host 
  [void]LogSuccess([string]$str){ $this.Log('SUC', 'Green', $str) }

  # Writes given string with predefined Warning template to the host 
  [void]LogWarning([string]$str){ $this.Log('WRN', 'Yellow', $str) }

  # Writes given string with predefined Error template to the host 
  [void]LogError([string]$str){ $this.Log('ERR', 'Red', $str) }

  # Writes given string with predefined TIP template to the host 
  [void]LogTip([string]$str){ $this.Log('TIP', 'Magenta', $str) }

  # Writes given string to the host 
  [void]Write([string]$str){ Write-Host $str }

  # Writes given string and colorfull suffix to the host
  [void]WriteColor([string]$str, [string]$suffix, [string]$color){
    Write-Host $str -NoNewline; Write-Host $suffix -f $color
  }

  # Writes special welcome template to the host
  [void]WriteWelcome([string]$name, [string]$version){
    Write-Host "$name " -NoNewline; Write-Host "$version`n" -f DarkGray
  }

  # Writes given string to the host and returns user input string
  [string]AskForUserInput([string]$str){ return Read-Host $str }

  # Writes given string to the host, waits for user confirmation before exit
  [void]ConfirmExit([string]$str){ Read-Host $str; exit }
}

# - Storage --------------------------------------------------------------------

class Storage {
  [string]$FilePath                         # storage file path
  [string]$FileName = 'syncer-storage.json' # storage file name
  [hashtable]$Data = @{ updated = '' }      # storage file data struct

  # Storage constructor
  Storage([string]$rootDir){
    $this.FilePath = Join-Path -Path $rootDir -ChildPath $this.FileName
  }

  # Returns `True` if the storage file exists, `False` otherwise
  [bool]IsSavedFileExists(){
    return [System.IO.File]::Exists($this.FilePath)
  }

  # Tries to save Data to a file, returns `True` or `False` as a result
  [bool]SaveToFile(){
    try {
      $this.Data.updated = (Get-Date).ToString('dd-MM-yyyy HH:mm:ss')
      $this.Data | ConvertTo-Json -Depth 4 |
      Format-Json | Set-Content -Path $this.FilePath
      return $true
    } catch { return $false }
  }

  # Converts given object to hashtable
  [hashtable]ConvertObjToHashtable([PSCustomObject]$obj) {
    $hashtable = @{}  
    foreach ($key in $obj.psobject.properties.name) {
      if ($obj.$key.GetType().Name -eq 'PSCustomObject') {
        $hashtable[$key] = $this.ConvertObjToHashtable($obj.$key)
      } else {
        $hashtable[$key] = $obj.$key
      }
    }
    return $hashtable
  }

  # Tries to read Data from a file, returns `True` or `False` as a result 
  [bool]ReadFromFile(){
    try {
      $object = Get-Content -Path $this.FilePath -Raw | ConvertFrom-Json
      $this.Data = $this.ConvertObjToHashtable($object)
      return $true
    } catch { return $false }
  }
}

# - Provider -------------------------------------------------------------------

class Provider {
  [string]$Name           # provider name
  [string]$SourceFilePath # source file path
  [string]$StorageKey     # Storage scope key
  [Storage]$Storage       # Storage ref
  [Logger]$Logger         # Logger ref

  # Provider constructor
  Provider([string]$name, [string]$key, [Logger]$logger, [Storage]$storage){
    if ($this.GetType() -eq [Provider]) { throw("Class must be inherited") }
    $this.Name = $name
    $this.StorageKey = $key
    $this.Logger = $logger
    $this.Storage = $storage
  }

  # Sets given path as source file path
  [void]SetSourceFilePath([string]$path){
    $this.SourceFilePath = $path
  }

  # Returns SHA256 hash for the given string
  [string]HashString([string]$str){
    $stream = [IO.MemoryStream]::new([byte[]][char[]]$str)
    return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
  }

  # Returns source file name as `name.ext` string
  [string]SourceFileName(){
    return [System.IO.Path]::GetFileName($this.SourceFilePath)
  }

  # Returns source file name with hash `name_{SHA256}.ext`
  [string]SourceFileHashedName(){
    return (
      "$([System.IO.Path]::GetFileNameWithoutExtension($this.SourceFilePath))" +
      "_$($this.HashString($this.SourceFilePath)).kdbx"
    )
  }

  # Does `install` logic
  [void]Install(){ throw('Override this method') }

  # Does `bootstrap` logic
  [void]Bootstrap(){ throw('Override this method') }

  # Does `use` logic
  [void]Use(){ throw('Override this method') }
}

# - Yandex provider ------------------------------------------------------------

class YandexProvider: Provider  {
  [int64]$UpdatePeriod = 86400 # auth tokens update period, seconds
  [hashtable]$Data = @{        # local data state
    clientID      = ''
    clientSecret  = ''
    targetDir     = ''
    access_token  = ''
    refresh_token = ''
    expires_in    = ''
    enabled       = $true
  }

  # Yandex provider constructor
  YandexProvider([Logger]$logger, [Storage]$storage): base(
    'Yandex drive', 'yandex', $logger, $storage
  ){}

  # Asks user about `ClientID` and returns user input string
  [string]GetAppClientID([string]$str){
    $res = $this.Logger.AskForUserInput($str)
    if ($res -eq '') { return $this.GetAppClientID($str) } # ask again
    return $res
  }

  # Asks user about `Client Secret` and returns user input string
  [string]GetAppClientSecret([string]$str){
    $res = $this.Logger.AskForUserInput($str)
    if ($res -eq '') { return $this.GetAppClientSecret($str) } # ask again
    return $res
  }

  # Asks user about destination folder path and returns user input string
  [string]GetDriveTargetDir([string]$str){
    $err = "The path must starts and ends with a '/' symbol"
    $res = $this.Logger.AskForUserInput($str)
    if ($res -eq '/' -or $res -match '^\/.*\/$') { return $res }
    return $this.GetDriveTargetDir($err) # ask again
  }

  # Returns auth link
  [string]GetOAuthLink(){
    return (
      'https://oauth.yandex.ru/authorize?' +
      "response_type=code&client_id=$($this.Data.clientID)"
    )
  }

  # Asks user about auth code and returns user input string
  [string]GetOAuthCode([string]$str){
    $res = $this.Logger.AskForUserInput($str)
    if ($res -eq '') { return $this.GetOAuthCode($str) } # ask again
    return $res
  }

  # Authorized provider with given code
  [bool]IsAuthorized([string]$code){
    try {
      $params = @{
        Uri = 'https://oauth.yandex.ru/token'
        Method = 'Post'
        ContentType = 'application/x-www-form-urlencoded'
        Body = @{
          grant_type = 'authorization_code'
          code = $code
          client_id = $this.Data.clientID
          client_secret = $this.Data.clientSecret
        }
      }
      $res = Invoke-RestMethod @params
      $this.Data.access_token = $res.access_token
      $this.Data.refresh_token = $res.refresh_token
      $updateTime = $res.expires_in
      if ($updateTime -gt $this.UpdatePeriod) { $updateTime = $this.UpdatePeriod }
      $expires_in = (Get-Date).AddSeconds($updateTime)
      $this.Data.expires_in = $expires_in.ToString('dd-MM-yyyy HH:mm:ss')
      return $true
    } catch {
      $this.Logger.LogError("[$($this.Name)] Auth failed: $($_.ToString())")
      return $false
    }
  }

  # Returns `True` if all provider data is valid, `False` otherwise
  [bool]IsStorageDataValid(){
    $scoped = $this.Storage.Data[$this.StorageKey]
    foreach ($key in $this.Data.Keys) {
      if (
        $null -eq $scoped[$key] -or
        $scoped[$key].GetType().Name -ne $this.Data[$key].GetType().Name
      ) { return $false }
    }
    return $true
  }

  # Returns `True` if all provider data fields are set, `False` otherwise
  [bool]IsStorageDataFullFilled(){
    $scoped = $this.Storage.Data[$this.StorageKey]
    foreach ($key in $this.Data.Keys) {
      if ($key -eq 'enabled') { continue }
      if ($scoped[$key] -eq '') { return $false }
    }
    return $true
  }

  # Updates auth tokens and returns `True` on success, `False` otherwise
  [bool]IsAuthTokenUpdated(){
    $timeNow = Get-Date
    $timeExpire = [DateTime]::ParseExact(
      $this.Data.expires_in,
      'dd-MM-yyyy HH:mm:ss',
      $null
    )
    if ($timeExpire -gt $timeNow) { return $true } # no need to update
    $this.Logger.LogInfo("[$($this.Name)] Updating auth tokens...")
    try {
      $params = @{
        Uri = 'https://oauth.yandex.ru/token'
        Method = 'Post'
        ContentType = 'application/x-www-form-urlencoded'
        Body = @{
          grant_type = 'refresh_token'
          refresh_token = $this.Data.refresh_token
          client_id = $this.Data.clientID
          client_secret = $this.Data.clientSecret
        }
      }
      $res = Invoke-RestMethod @params
      $this.Data.access_token = $res.access_token
      $this.Data.refresh_token = $res.refresh_token
      $updateTime = $res.expires_in
      if ($updateTime -gt $this.UpdatePeriod) {
        $updateTime = $this.UpdatePeriod
      }
      $expires_in = (Get-Date).AddSeconds($updateTime)
      $this.Data.expires_in = $expires_in.ToString('dd-MM-yyyy HH:mm:ss')
      $this.Storage.Data[$this.StorageKey] = $this.Data
      $this.Storage.SaveToFile()
      return $true
    } catch {
      $this.Logger.LogError(
        "[$($this.Name)] Failed to refresh tokens: $($_.ToString())"
      )
      return $false
    }
  }

  # Returns upload file params or error message
  [hashtable]UploadFileParams(){
    try {
      $params = @{
        Uri = (
          'https://cloud-api.yandex.net/v1/disk/resources/upload?' +
          "path=$($this.Data.targetDir)" +
          $this.SourceFileHashedName() +
          '&overwrite=true'
        )
        Method = 'Get'
        Headers = @{'Authorization' = "OAuth $($this.Data.access_token)"}
      }
      $res = Invoke-RestMethod @params
      return @{ href = $res.href; method = $res.method }
    } catch { return @{ error = $_.ToString() } }
  }

  # Uploads source file to the drive
  [void]Sync(){
    $this.Logger.LogInfo("[$($this.Name)] File uploading...")
    $params = $this.UploadFileParams()
    if ($null -ne $params.error) {
      $this.Logger.LogError("[$($this.Name)] Failed to upload: $($params.error)")
      return
    }
    try {
      Invoke-RestMethod -Uri $params.href -Method $params.method -InFile $this.SourceFilePath
      $this.Logger.LogSuccess("[$($this.Name)] Uploading is complete")
    } catch {
      $this.Logger.LogError("[$($this.Name)] Failed to upload: $($_.ToString())")
    }
  }

  # Provider installation
  [void]Install(){
    $this.Logger.LogInfo("[$($this.Name)] Installation...")
    $this.Data.clientID = $this.GetAppClientID("Step 1. Client ID")
    $this.Data.clientSecret = $this.GetAppClientSecret("Step 2. Client Secret")
    $this.Data.targetDir = $this.GetDriveTargetDir('Step 3. Drive folder path')
    $link = $this.GetOAuthLink()
    $this.Logger.WriteColor('Step 4. Auth with the link: ', $link, 'Blue')
    $code = $this.GetOAuthCode("Step 5. Auth code")
    if (-not $this.IsAuthorized($code)) { return }
    $this.Storage.Data[$this.StorageKey] = $this.Data
    if (-not $this.Storage.SaveToFile()) {
      $this.Logger.LogError("Failed while saving storage data")
    } else {
      $this.Logger.LogSuccess("[$($this.Name)] Installation completed")
      $this.Sync()
    }
  }

  # Provider bootstrapping
  [void]Bootstrap(){
    $msg = "Do you want to use $($this.Name) provider? [Y/n]"
    if ($this.Logger.AskForUserInput($msg) -match '^[nN]') {
      $emptyStorage = @{}
      foreach ($key in $this.Data.Keys) {
        if ($key -eq 'enabled') { $emptyStorage[$key] = $false; continue }
        $emptyStorage[$key] = ''
      }
      $this.Storage.Data[$this.StorageKey] = $emptyStorage
      if (-not $this.Storage.SaveToFile()) {
        $this.Logger.LogError("Failed while saving storage data")
      }
      return
    }
    $this.Install()
  }

  # Provider usage
  [void]Use(){
    if (-not $this.Storage.Data.ContainsKey($this.StorageKey)) {
      $this.Bootstrap(); return # no saved data
    }
    if (-not $this.IsStorageDataValid()) {
      $this.Bootstrap(); return # saved data is invalid
    }
    if (-not $this.Storage.Data[$this.StorageKey].enabled) {
      $this.Logger.LogTip("[$($this.Name)] Disabled, sync is skipped...")
      return # disabled by user
    }
    if (-not $this.IsStorageDataFullFilled()) {
      $this.Bootstrap(); return # partial data
    }
    $scoped = $this.Storage.Data[$this.StorageKey]
    $tmp = @{}
    foreach ($key in $this.Data.Keys) { $tmp[$key] = $scoped[$key] }
    $this.Data = $tmp
    if ($this.IsAuthTokenUpdated()) { $this.Sync(); return }
    $this.Bootstrap() # if some errors try to re-install
  }
}

# - Google provider ------------------------------------------------------------

class GoogleProvider: Provider  {
  [int64]$UpdatePeriod = 1800  # auth tokens update period, seconds
  [hashtable]$Data = @{        # local data state
    clientID      = ''
    clientSecret  = ''
    targetDir     = ''
    access_token  = ''
    refresh_token = ''
    expires_in    = ''
    files         = @{}
    enabled       = $true
  }

  # Google provider constructor
  GoogleProvider([Logger]$logger, [Storage]$storage): base(
    'Google drive', 'google', $logger, $storage
  ){}

  # Asks user about `ClientID` and returns user input string
  [string]GetAppClientID([string]$str){
    $res = $this.Logger.AskForUserInput($str)
    if ($res -eq '') { return $this.GetAppClientID($str) } # ask again
    return $res
  }

  # Asks user about `Client Secret` and returns user input string
  [string]GetAppClientSecret([string]$str){
    $res = $this.Logger.AskForUserInput($str)
    if ($res -eq '') { return $this.GetAppClientSecret($str) } # ask again
    return $res
  }

  # Asks user about destination folder ID and returns user input string
  [string]GetDriveTargetDir([string]$str){
    $res = $this.Logger.AskForUserInput($str)
    if ($res -eq '') { return $this.GetDriveTargetDir($str) }
    return $res
  }

  # Returns OAuth details
  [hashtable]GetOAuthDetails(){
    $this.Logger.LogInfo("[$($this.Name)] Get OAuth details...")
    try {
      $params = @{
        Uri = 'https://oauth2.googleapis.com/device/code'
        Method = 'Post'
        ContentType = 'application/x-www-form-urlencoded'
        Body = @{
          client_id = $this.Data.clientID
          scope = 'https://www.googleapis.com/auth/drive.file'
        }
      }
      $res = Invoke-RestMethod @params
      return @{
        device_code = $res.device_code
        user_code = $res.user_code
        url = $res.verification_url
      }
    } catch {
      return @{ error = $_.ToString() }
    }
  }

  # Returns fileId or empty string
  [string]GetDriveFileIdByPath([string]$filePath){
    if ($this.Data.files.ContainsKey($filePath)) {
      return $this.Data.files[$filePath]
    } else {
      return ''
    }
  }

  # Authorized provider with given code
  [bool]IsAuthorized([string]$code){
    try {
      $params = @{
        Uri = 'https://oauth2.googleapis.com/token'
        Method = 'Post'
        ContentType = 'application/x-www-form-urlencoded'
        Body = @{
          grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
          device_code = $code
          client_id = $this.Data.clientID
          client_secret = $this.Data.clientSecret
        }
      }
      $res = Invoke-RestMethod @params
      $this.Data.access_token = $res.access_token
      $this.Data.refresh_token = $res.refresh_token
      $updateTime = $res.expires_in
      if ($updateTime -gt $this.UpdatePeriod) { $updateTime = $this.UpdatePeriod }
      $expires_in = (Get-Date).AddSeconds($updateTime)
      $this.Data.expires_in = $expires_in.ToString('dd-MM-yyyy HH:mm:ss')
      return $true
    } catch {
      $this.Logger.LogError("[$($this.Name)] Auth failed: $($_.ToString())")
      return $false
    }
  }

  # Returns `True` if all provider data is valid, `False` otherwise
  [bool]IsStorageDataValid(){
    $scoped = $this.Storage.Data[$this.StorageKey]
    foreach ($key in $this.Data.Keys) {
      if (
        $null -eq $scoped[$key] -or
        $scoped[$key].GetType().Name -ne $this.Data[$key].GetType().Name
      ) { return $false }
    }
    return $true
  }

  # Returns `True` if all provider data fields are set, `False` otherwise
  [bool]IsStorageDataFullFilled(){
    $scoped = $this.Storage.Data[$this.StorageKey]
    foreach ($key in $this.Data.Keys) {
      if ($key -eq 'enabled' -or $key -eq 'files') { continue }
      if ($scoped[$key] -eq '') { return $false }
    }
    return $true
  }

  # Updates auth tokens and returns `True` on success, `False` otherwise
  [bool]IsAuthTokenUpdated(){
    $timeNow = Get-Date
    $timeExpire = [DateTime]::ParseExact(
      $this.Data.expires_in,
      'dd-MM-yyyy HH:mm:ss',
      $null
    )
    if ($timeExpire -gt $timeNow) { return $true } # no need to update
    $this.Logger.LogInfo("[$($this.Name)] Updating auth tokens...")
    try {
      $params = @{
        Uri = 'https://oauth2.googleapis.com/token'
        Method = 'Post'
        ContentType = 'application/x-www-form-urlencoded'
        Body = @{
          grant_type = 'refresh_token'
          refresh_token = $this.Data.refresh_token
          client_id = $this.Data.clientID
          client_secret = $this.Data.clientSecret
        }
      }
      $res = Invoke-RestMethod @params
      $this.Data.access_token = $res.access_token
      $updateTime = $res.expires_in
      if ($updateTime -gt $this.UpdatePeriod) {
        $updateTime = $this.UpdatePeriod
      }
      $expires_in = (Get-Date).AddSeconds($updateTime)
      $this.Data.expires_in = $expires_in.ToString('dd-MM-yyyy HH:mm:ss')
      $this.Storage.Data[$this.StorageKey] = $this.Data
      $this.Storage.SaveToFile()
      return $true
    } catch {
      $this.Logger.LogError(
        "[$($this.Name)] Failed to refresh tokens: $($_.ToString())"
      )
      return $false
    }
  }

  # Returns upload file location or error message
  [hashtable]GetFileLocation([string]$path, [string]$method, [hashtable]$body){
    try {
      $params = @{
        Uri = (
          "https://www.googleapis.com/upload/drive/v3/files$($path)?" + 
          'uploadType=resumable'
        )
        Method = $method
        Body = ($body | ConvertTo-Json -Compress)
        ContentType = 'application/json; charset=UTF-8'
        Headers = @{'Authorization' = "Bearer $($this.Data.access_token)"}
      }
      return @{ location = (Invoke-WebRequest @params).Headers.Location }
    } catch { return @{ error = $_.ToString() } }
  }

  [hashtable]UploadFileToLocation([string]$location){
    try {
      $res = Invoke-RestMethod -Uri $location -Method 'Put' -InFile $this.SourceFilePath
      return @{ id = $res.id }
    } catch { return @{ error = $_.ToString() } }
  }

  # Uploads source file to the drive
  [void]Sync(){
    $this.Logger.LogInfo("[$($this.Name)] File uploading...")
    $fileId = $this.GetDriveFileIdByPath($this.SourceFilePath)
    $exists = $fileId -ne ''
    $path   = if ($exists) { "/$fileId" } else { '' }
    $method = if ($exists) { 'Patch' } else { 'Post' }
    $body   = @{ name = $this.SourceFileName() }
    if (($this.Data.targetDir.Length -gt 1) -and -not $exists) {
      $body.parents = @($this.Data.targetDir)
    }
    $res = $this.GetFileLocation($path, $method, $body)
    if ($null -ne $res.error) {
      $this.Logger.LogError("[$($this.Name)] Failed to upload: $($res.error)")
      return
    }
    $res = $this.UploadFileToLocation($res.location)
    if ($null -ne $res.error) {
      $this.Logger.LogError("[$($this.Name)] Failed to upload: $($res.error)")
      return
    }
    $this.Data.files[$this.SourceFilePath] = $res.id
    $this.Storage.Data[$this.StorageKey] = $this.Data
    $this.Storage.SaveToFile()

    $this.Logger.LogSuccess("[$($this.Name)] Uploading is complete")
  }

  # Provider installation
  [void]Install(){
    $this.Logger.LogInfo("[$($this.Name)] Installation...")
    $this.Data.clientID = $this.GetAppClientID("Step 1. Client ID")
    $this.Data.clientSecret = $this.GetAppClientSecret("Step 2. Client Secret")
    $this.Data.targetDir = $this.GetDriveTargetDir('Step 3. Drive folder ID or "/"')
    $details = $this.GetOAuthDetails()
    if ($null -ne $details.error) {
      $this.Logger.LogError("[$($this.Name)] Failed to get OAuth details: $($details.error)")
      return # we can't go further
    }
    $this.Logger.WriteColor('Step 4. Copy the user code: ', $details.user_code, 'Green')
    $this.Logger.WriteColor('Step 5. Auth with the link: ', $details.url, 'Blue')
    $this.Logger.Write('Step 6. Confirm the permissions for the application')
    $this.Logger.AskForUserInput("Step 7. Press Enter to continue")
    if (-not $this.IsAuthorized($details.device_code)) { return }
    $this.Storage.Data[$this.StorageKey] = $this.Data
    if (-not $this.Storage.SaveToFile()) {
      $this.Logger.LogError("Failed while saving storage data")
    } else {
      $this.Logger.LogSuccess("[$($this.Name)] Installation completed")
      $this.Sync()
    }
  }

  # Provider bootstrapping
  [void]Bootstrap(){
    $msg = "Do you want to use $($this.Name) provider? [Y/n]"
    if ($this.Logger.AskForUserInput($msg) -match '^[nN]') {
      $emptyStorage = @{}
      foreach ($key in $this.Data.Keys) {
        if ($key -eq 'enabled') { $emptyStorage[$key] = $false; continue }
        if ($key -eq 'files') { $emptyStorage[$key] = @{}; continue }
        $emptyStorage[$key] = ''
      }
      $this.Storage.Data[$this.StorageKey] = $emptyStorage
      if (-not $this.Storage.SaveToFile()) {
        $this.Logger.LogError("Failed while saving storage data")
      }
      return
    }
    $this.Install()
  }

  # Provider usage
  [void]Use(){
    if (-not $this.Storage.Data.ContainsKey($this.StorageKey)) {
      $this.Bootstrap(); return # no saved data
    }
    if (-not $this.IsStorageDataValid()) {
      $this.Bootstrap(); return # saved data is invalid
    }
    if (-not $this.Storage.Data[$this.StorageKey].enabled) {
      $this.Logger.LogTip("[$($this.Name)] Disabled, sync is skipped...")
      return # disabled by user
    }
    if (-not $this.IsStorageDataFullFilled()) {
      $this.Bootstrap(); return # partial data
    }
    $scoped = $this.Storage.Data[$this.StorageKey]
    $tmp = @{}
    foreach ($key in $this.Data.Keys) { $tmp[$key] = $scoped[$key] }
    $this.Data = $tmp
    if ($this.IsAuthTokenUpdated()) { $this.Sync(); return }
    $this.Bootstrap() # if some errors try to re-install
  }
}

# - Syncer ---------------------------------------------------------------------

class Syncer {
  [string]$Name = 'KeePass cloud syncer'
  [string]$Version = 'v1.0.0'
  [string]$SourceFilePath
  [Provider[]]$Providers
  [Logger]$Logger
  [Storage]$Storage
  
  # Syncer constructor
  Syncer([string]$path, [Logger]$logger, [Storage]$storage){
    $this.SourceFilePath = $path
    $this.Logger = $logger
    $this.Storage = $storage
  }

  # Adds `Provider` instance to the providers list
  [void]RegisterProvider([Provider]$provider){
    $provider.SetSourceFilePath($this.SourceFilePath)
    $this.Providers += $provider
  }

  # Returns `True` if given path is valid, `False` otherwise
  [bool]IsSourceFileValid($path){
    return (
      [System.IO.File]::Exists($path) -and              # must be a real path
      [System.IO.Path]::IsPathRooted($path) -and        # only absolute path
      [System.IO.Path]::GetExtension($path) -eq '.kdbx' # .kdbx files only
    )
  }

  # Starts Syncer
  [void]Start(){
    $this.Logger.WriteWelcome($this.Name, $this.Version)

    # Can we use the given source file path?
    if (-not $this.IsSourceFileValid($this.SourceFilePath)) {
      $this.Logger.LogError((
        "Source path is invalid: " +
        "must be an existing absolute path with .kdbx extension`n"  +
        "Got: $($this.SourceFilePath)" 
      ))
      $this.Logger.ConfirmExit("Press Enter to exit") # => Exit 0
    }

    # If there is no storage save file or it is failed while reading 
    if (
      -not $this.Storage.IsSavedFileExists() -or # no storage file
      -not $this.Storage.ReadFromFile()          # failed to read from file
    ) {
      $this.Logger.LogWarning('No saved configuration, bootstrapping...')
      for($i=0; $i -lt $this.Providers.Length; $i++) {
        $this.Providers[$i].Bootstrap()
      }
      return # all done while bootstrapping
    }

    # Use all registered providers as usual
    for($i=0; $i -lt $this.Providers.Length; $i++) {
      $this.Providers[$i].Use()
    }
  }
}

# - Init & Run -----------------------------------------------------------------

$logger  = [Logger]::new()
$storage = [Storage]::new($_selfDir)
$syncer  = [Syncer]::new($_sourcePath, $logger, $storage)
$syncer.RegisterProvider([YandexProvider]::new($logger, $storage))
$syncer.RegisterProvider([GoogleProvider]::new($logger, $storage))
$syncer.Start()