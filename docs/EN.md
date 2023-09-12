# KeePass cloud syncer manual

All commands presented in this guide are executed in PowerShell

## Installation

Create a directory with a random name anywhere on your computer,
with the exception of system folders: Windows, Program Files, etc., for example:

```powershell
New-Item -Path 'D:\KeePassSyncer' -ItemType Directory
```

Create an empty PowerShell script file with any name, for example:

```powershell
New-Item -Path 'D:\KeePassSyncer\syncer.ps1' -ItemType File
```

Due to Windows security policies, which make it understandably difficult to
distributing such programs requires manually copying the file contents
with [source code](/script.ps1) and paste into the file created in the previous step.

During its operation, the script will independently create an additional file
configuration `syncer-storage.json`. This file serves as a storage for settings, and
also contains authorization data for connecting to cloud providers.

## Integration with KeePass

To integrate, you need to create a trigger in the KeePass program and configure it.

> You must specify your own path to the script file

- Properties tab
  - Name: arbitrary
  - Allowed
  - Initially on
- Events tab
  - Add event `Saved database file`
  - Leave event fields at default
- Conditions tab
  - We don’t do anything
- Actions tab
  - Add action `Execute command line /URL`
  - File/URL: `powershell`
  - Arguments: `-File D:\KeePassSyncer\syncer.ps1 {DB_PATH}`
  - Wait for exit: yes
  - Leave the remaining fields as default

We save the trigger and enjoy the automation. Every time you save the KeePass database
A PowerShell window will open with the synchronization program.

## First launch

When you launch it for the first time, the program will prompt you to configure
it in interactive mode per cloud provider you are using or disable it.
Features are described below each provider. Please review them before use.

### Yandex drive

To use this provider, OAuth authorization data is required.

- Client ID
- Client Secret

To receive them, you need to register your application with Yandex using
[this link](https://oauth.yandex.ru/client/new/).

- Platform: `Web-services`
- Data access: `cloud_api:disk.write`

The directory specified in the program settings must first be created on
Yandex disk manually.

The saved files will have a name like:
```
{filename}_{SHA256HASH}.kdbx
```

Adding a unique hash for each file avoids accidental
overwriting files with the same names, but located in different
local directories.

### Google drive

To use this provider, OAuth authorization data is required.

- Client ID
- Client Secret

To receive them, you need to register your application with Google using
[this link](https://console.cloud.google.com/).

- Platform: `TV and Limited Input`
- API Scope: `./auth/drive.file`

To save the file in the root directory of Google Drive, use `"/"`.

To save a file in a directory other than the root, you must first
get the ID of this directory. To do this, go to the web version of Google Drive
to the required directory. The last element in the URL will be the identifier
type:
```
1a8k8TZYeBDcDC_sZdStEPnSoAFa5ZWxP
```

## Subsequent use

All subsequent launches of the program do not require intervention on your part,
everything happens automatically. When the program completes, the PowerShell window will close
itself.

## Problems and solutions

During operation, exceptional situations may arise. Program
will stop its execution and wait for confirmation from the user.
If an unsolvable situation occurs, try deleting the `syncer-storage.json` file
and perform a clean setup.